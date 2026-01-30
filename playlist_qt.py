import sys, socket, json, os, subprocess, re, threading, glob
from pathlib import Path
from PySide6.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QLineEdit, QListView, QPushButton, QFileDialog, QAbstractItemView, QFrame, QMenu, QSlider, QToolTip)
from PySide6.QtCore import Qt, QTimer, Signal, QObject, QPoint, QItemSelectionModel
from PySide6.QtGui import QStandardItemModel, QStandardItem, QColor, QFont, QIcon
os.environ["QT_ACCESSIBILITY"] = "0"
class UpdateSignals(QObject):
    finished = Signal(object, list, str, bool)
    heartbeat = Signal(str, str, bool)
class MPVQtManager(QMainWindow):
    USER_ROLE = Qt.UserRole
    def __init__(self):
        super().__init__()
        self.lock = threading.Lock()
        self.setWindowFlags(Qt.Window | Qt.CustomizeWindowHint | Qt.WindowCloseButtonHint)
        self.setAcceptDrops(True)
        self.setWindowTitle("MPV")
        self.socket_path, self.fav_file = "/dev/shm/mpvsocket", os.path.expanduser("~/.mpv_favorites.json")
        self.last_m3u_file, self.config_file = os.path.expanduser("~/.mpv_last_playlist.json"), os.path.expanduser("~/.mpv_qt_config.json")
        with self.lock: self.favorites = self.load_favs()
        self.sort_mode, self.current_playing_filename, self.current_group, self.is_paused = 0, "", "All", False
        self.m3u_groups, self.full_list, self.group_counts = {}, [], {}
        self.is_updating, self.resume_done, self.last_file = False, False, ""
        self.signals = UpdateSignals()
        self.signals.finished.connect(self._finalize_update)
        self.signals.heartbeat.connect(self._sync_heartbeat)
        self.apply_styles()
        self.ensure_mpv_running()
        self.load_window_state()
        central = QWidget()
        self.setCentralWidget(central)
        self.vbox = QVBoxLayout(central)
        self.vbox.setSpacing(4)
        self.vbox.setContentsMargins(5, 5, 5, 5)
        self.header = QHBoxLayout()
        self.header.setSpacing(4)
        self.search_entry = QLineEdit()
        self.search_entry.setPlaceholderText("Search...")
        self.search_entry.setFixedHeight(28)
        self.search_entry.textChanged.connect(self.filter_playlist)
        self.group_btn, self.burger_btn = QPushButton("▾"), QPushButton("≡")
        for b in [self.group_btn, self.burger_btn]: b.setFixedSize(28, 28)
        self.header.addWidget(self.search_entry)
        self.header.addWidget(self.group_btn)
        self.header.addWidget(self.burger_btn)
        self.vbox.addLayout(self.header)
        self.tree_view = QListView()
        self.tree_view.setFrameShape(QFrame.NoFrame)
        self.tree_view.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.list_model = QStandardItemModel()
        self.tree_view.setModel(self.list_model)
        self.tree_view.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.vbox.addWidget(self.tree_view)
        self.fab_container = QWidget(self)
        self.fab_layout = QVBoxLayout(self.fab_container)
        self.fab_layout.setContentsMargins(0, 0, 0, 0)
        self.fab_layout.setSpacing(6)
        self.sub_buttons = QWidget()
        self.sub_layout = QVBoxLayout(self.sub_buttons)
        self.sub_layout.setContentsMargins(0, 0, 0, 0)
        self.sub_layout.setSpacing(6)
        self.vol_slider = QSlider(Qt.Vertical)
        self.vol_slider.setRange(0, 130)
        self.vol_slider.setFixedSize(32, 120)
        self.vol_slider.setObjectName("fab-vol")
        self.vol_slider.valueChanged.connect(self.on_vol_changed)
        self.sub_layout.addWidget(self.vol_slider)
        for icon, cmd in [("media-skip-forward-symbolic", ["playlist-next"]), ("media-playback-start-symbolic", ["cycle", "pause"]), ("media-skip-backward-symbolic", ["playlist-prev"])]:
            btn = QPushButton()
            btn.setIcon(QIcon.fromTheme(icon))
            btn.setObjectName("fab-small")
            btn.setFixedSize(32, 32)
            btn.clicked.connect(lambda checked=False, c=cmd: self.send_command({"command": c}))
            self.sub_layout.addWidget(btn)
        self.sub_buttons.setVisible(False)
        self.main_fab = QPushButton()
        self.main_fab.setIcon(QIcon.fromTheme("view-more-horizontal-symbolic"))
        self.main_fab.setObjectName("fab-trigger")
        self.main_fab.setFixedSize(32, 32)
        self.main_fab.clicked.connect(self.toggle_fab)
        self.fab_layout.addWidget(self.sub_buttons)
        self.fab_layout.addWidget(self.main_fab)
        self.group_btn.clicked.connect(self.show_group_menu)
        self.burger_btn.clicked.connect(self.show_burger_menu)
        self.tree_view.clicked.connect(self.on_row_activated)
        self.tree_view.setContextMenuPolicy(Qt.CustomContextMenu)
        self.tree_view.customContextMenuRequested.connect(self.on_right_click)
        QTimer.singleShot(0, self.auto_load_last_m3u)
        threading.Thread(target=self._heartbeat_thread, daemon=True).start()
        self.socket_timer = QTimer()
        self.socket_timer.timeout.connect(self.refresh_sockets)
        self.socket_timer.start(5000)
        self.available_sockets = []
    def apply_styles(self):
        self.setStyleSheet("""QMainWindow { background-color: #ffffff; } * { outline: none; } QPushButton { border: none; background-color: #f2f2f2; border-radius: 4px; color: #333; } QPushButton:hover { background-color: #e5e5e5; } QLineEdit { padding: 4px 10px; border: 1px solid #eee; border-radius: 5px; background: #f9f9f9; } QPushButton#fab-trigger { border-radius: 16px; background-color: rgba(53, 132, 228, 180); qproperty-iconSize: 20px; } QPushButton#fab-trigger:hover { background-color: rgba(53, 132, 228, 255); } QPushButton#fab-small { border-radius: 16px; background-color: rgba(60, 60, 60, 160); qproperty-iconSize: 16px; } QPushButton#fab-small:hover { background-color: rgba(80, 80, 80, 220); } QSlider#fab-vol { background: rgba(60, 60, 60, 160); border-radius: 16px; padding: 10px 0px; } QSlider::groove:vertical#fab-vol { background: rgba(255, 255, 255, 40); width: 4px; border-radius: 2px; } QSlider::handle:vertical#fab-vol { background: #3584e4; height: 12px; width: 12px; margin: 0 -4px; border-radius: 6px; } QListView { background-color: white; border: none; } QListView::item { padding: 6px 10px; border-radius: 8px; margin-bottom: 2px; } QListView::item:selected { background-color: #3584e4; color: white; } QScrollBar:vertical { border: none; background: transparent; width: 8px; } QScrollBar::handle:vertical { background: #ccc; border-radius: 4px; min-height: 20px; } QScrollBar::handle:vertical:hover { background: #3584e4; } QScrollBar::add-line, QScrollBar::sub-line, QScrollBar::add-page, QScrollBar::sub-page { background: none; height: 0px; } QToolTip { background-color: #333; color: white; border: 1px solid #555; padding: 3px; border-radius: 4px; }""")
    def toggle_fab(self):
        self.sub_buttons.setVisible(not self.sub_buttons.isVisible())
        if self.sub_buttons.isVisible():
            res = self.send_command({"command": ["get_property", "volume"]})
            if res and "data" in res:
                self.vol_slider.blockSignals(True); self.vol_slider.setValue(int(res["data"])); self.vol_slider.blockSignals(False)
        self.update_fab_pos()
    def on_vol_changed(self, val):
        self.send_command({"command": ["set_property", "volume", val]})
        QToolTip.showText(self.vol_slider.mapToGlobal(QPoint(-55, self.vol_slider.height() // 2)), f"{val}%", self.vol_slider)
    def resizeEvent(self, event): super().resizeEvent(event); self.update_fab_pos(); self.save_config()
    def moveEvent(self, event): super().moveEvent(event); self.save_config()
    def update_fab_pos(self):
        w = 32
        h = 32 if not self.sub_buttons.isVisible() else (32 + 6 + 120 + 6 + (3 * 32) + (3 * 6))
        self.fab_container.setFixedSize(w, h)
        self.fab_container.move(self.width() - w - 20, self.height() - h - 20)
    def ensure_mpv_running(self):
        active = False
        if os.path.exists(self.socket_path):
            chk = self.send_command({"command": ["get_property", "idle"]}, timeout=0.1)
            if chk and chk.get("error") == "success": active = True
            else:
                try: os.remove(self.socket_path)
                except: pass
        if not active: subprocess.Popen(["mpv", "--idle", f"--input-ipc-server={self.socket_path}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    def refresh_sockets(self):
        found, new_list = sorted(list(set(glob.glob("/dev/shm/mpvsocket*") + glob.glob("/tmp/mpvsocket*")))), []
        for s in found:
            old = self.socket_path; self.socket_path = s; res = self.send_command({"command": ["get_property", "media-title"]}, timeout=0.1); self.socket_path = old
            if res and res.get("error") == "success":
                label = res.get("data") if res.get("data") else os.path.basename(s)
                new_list.append((s, label))
        self.available_sockets = new_list
    def switch_socket(self, path): self.socket_path = path; self.update_playlist()
    def load_favs(self):
        try:
            if os.path.exists(self.fav_file):
                with open(self.fav_file, "r", encoding="utf-8") as f: return set(json.load(f))
        except: pass
        return set()
    def save_favs(self):
        with self.lock:
            try:
                Path(os.path.dirname(self.fav_file) or ".").mkdir(parents=True, exist_ok=True)
                with open(self.fav_file, "w", encoding="utf-8") as f: json.dump(list(self.favorites), f)
            except: pass
    def load_window_state(self):
        with self.lock:
            try:
                if os.path.exists(self.config_file):
                    with open(self.config_file, "r", encoding="utf-8") as f:
                        c = json.load(f); self.move(c.get("x", 100), c.get("y", 100)); self.resize(c.get("w", 280), c.get("h", 750)); self.last_file, self.current_group = c.get("last_file", ""), c.get("current_group", "All")
                else: self.resize(280, 750)
            except: self.resize(280, 750)
    def save_config(self):
        pr = self.send_command({"command": ["get_property", "path"]}); cp = pr.get("data", "") if pr else self.last_file
        with self.lock:
            try:
                Path(os.path.dirname(self.config_file) or ".").mkdir(parents=True, exist_ok=True)
                with open(self.config_file, "w", encoding="utf-8") as f: json.dump({"x": self.x(), "y": self.y(), "w": self.width(), "h": self.height(), "last_file": cp, "current_group": self.current_group}, f)
            except: pass
    def closeEvent(self, event): self.save_config(); super().closeEvent(event)
    def send_command(self, cmd, timeout=0.5):
        for _ in range(2):
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
                    c.settimeout(timeout); c.connect(self.socket_path); c.sendall(json.dumps(cmd).encode() + b"\n")
                    res, buffer = b"", b""
                    while True:
                        chunk = c.recv(16384)
                        if not chunk: break
                        buffer += chunk
                        if b"\n" in buffer:
                            lines = buffer.split(b"\n")
                            for line in lines[:-1]:
                                if not line: continue
                                try:
                                    data = json.loads(line.decode(errors="ignore"))
                                    if any(k in data for k in ["request_id", "error", "data"]): return data
                                except: continue
                            buffer = lines[-1]
            except (socket.error, socket.timeout):
                if _ == 0: self.ensure_mpv_running()
                else: return None
        return None
    def _heartbeat_thread(self):
        import time
        while True:
            res_p = self.send_command({"command": ["get_property", "path"]}, timeout=0.2)
            res_t = self.send_command({"command": ["get_property", "media-title"]}, timeout=0.2)
            res_s = self.send_command({"command": ["get_property", "pause"]}, timeout=0.2)
            cp = res_p.get("data", "") if res_p else ""
            mt = str(res_t.get('data')) if (res_t and "data" in res_t) else "MPV"
            ps = res_s.get("data", False) if res_s else False
            self.signals.heartbeat.emit(cp, mt, ps)
            time.sleep(2)
    def _sync_heartbeat(self, cp, mt, ps):
        if cp != self.current_playing_filename or ps != self.is_paused:
            self.current_playing_filename, self.is_paused = cp, ps
            self.filter_playlist()
        if self.windowTitle() != mt: self.setWindowTitle(mt)
    def update_playlist(self):
        if self.is_updating: return
        self.is_updating = True; threading.Thread(target=self._update_thread, daemon=True).start()
    def _update_thread(self):
        res, curr = self.send_command({"command": ["get_property", "playlist"]}), self.send_command({"command": ["get_property", "path"]})
        pause_res = self.send_command({"command": ["get_property", "pause"]})
        cp = curr.get("data", "") if curr else ""
        ps = pause_res.get("data", False) if pause_res else False
        if not res or "data" not in res: self.is_updating = False; return
        gc, items = {}, []
        with self.lock: fc = set(self.favorites)
        for idx, i in enumerate(res["data"]):
            fn = i.get("filename", ""); nm = i.get("title") or os.path.basename(fn); grp = self.m3u_groups.get(nm, "Uncategorized"); gc[grp] = gc.get(grp, 0) + 1; items.append({"name": nm, "filename": fn, "orig_idx": idx, "group": grp, "search_idx": nm.lower()})
        def sp(x):
            isf = x["name"] in fc; ing = (self.current_group == "All") or (self.current_group == "★ Favorites" and isf) or (x["group"] == self.current_group); return (not ing, not isf, x["name"].lower())
        fs = sorted(items, key=sp, reverse=(self.sort_mode == 1))
        for t_idx, item in enumerate(fs):
            if item["orig_idx"] != t_idx:
                self.send_command({"command": ["playlist-move", item["orig_idx"], t_idx]})
                for o in items:
                    if o["orig_idx"] < item["orig_idx"] and o["orig_idx"] >= t_idx: o["orig_idx"] += 1
                item["orig_idx"] = t_idx
        self.signals.finished.emit(gc, fs, cp, ps)
    def _finalize_update(self, group_counts, full_sorted, curr_path, is_paused):
        self.full_list, self.group_counts, self.current_playing_filename, self.is_paused = full_sorted, group_counts, curr_path or "", is_paused
        self.filter_playlist()
        if not self.resume_done and self.last_file:
            for item in self.full_list:
                if item["filename"] == self.last_file: self.send_command({"command": ["set_property", "playlist-pos", item["orig_idx"]]}); self.send_command({"command": ["set_property", "pause", True]}); self.resume_done = True; break
        self.is_updating = False
    def show_group_menu(self):
        menu = QMenu(self); self.update_fab_pos()
        with self.lock: fc = set(self.favorites)
        f_count = sum(1 for x in self.full_list if x["name"] in fc)
        for gn, c in [("All", len(self.full_list)), ("★ Favorites", f_count)]:
            lbl = f"{gn} ({c})"
            if self.current_group == gn: lbl = f"• {lbl}"
            menu.addAction(lbl).triggered.connect(lambda chk=False, n=gn: self.set_active_group(n))
        menu.addSeparator()
        for g in sorted(self.group_counts.keys()):
            lbl = f"{g} ({self.group_counts[g]})"
            if self.current_group == g: lbl = f"• {lbl}"
            menu.addAction(lbl).triggered.connect(lambda chk=False, n=g: self.set_active_group(n))
        menu.exec(self.group_btn.mapToGlobal(QPoint(0, self.group_btn.height())))
    def set_active_group(self, name): self.current_group = name; self.save_config(); self.update_playlist()
    def show_burger_menu(self):
        menu = QMenu(self)
        menu.addAction("Open Playlist").triggered.connect(self.on_load_clicked)
        menu.addAction("Toggle Sort").triggered.connect(self.toggle_sort)
        menu.addAction("Refresh").triggered.connect(self.update_playlist)
        menu.addSeparator()
        sock_menu = menu.addMenu("Select Player")
        for s_path, s_label in self.available_sockets:
            lbl = f"✔ {s_label}" if s_path == self.socket_path else s_label
            sock_menu.addAction(lbl).triggered.connect(lambda chk=False, p=s_path: self.switch_socket(p))
        menu.addSeparator(); menu.addAction("Clear Playlist").triggered.connect(self.on_clear_clicked)
        menu.exec(self.burger_btn.mapToGlobal(QPoint(0, self.burger_btn.height())))
    def filter_playlist(self):
        self.list_model.clear(); q = self.search_entry.text().lower().strip(); si = None
        with self.lock: fc = set(self.favorites)
        for i in self.full_list:
            nm, grp, idx, fn, s_idx = i["name"], i["group"], i["orig_idx"], i["filename"], i["search_idx"]; isf = nm in fc
            if "Favorites" in self.current_group:
                if not isf: continue
            elif "All" not in self.current_group and grp != self.current_group: continue
            if q and q not in s_idx: continue
            isp = (fn == self.current_playing_filename)
            status_icon = "⏸ " if (isp and self.is_paused) else ("▶ " if isp else "")
            dnm = f"{status_icon}{'★ ' if isf else ''}{nm}"
            qi = QStandardItem(dnm); qi.setData(idx, self.USER_ROLE)
            if isp: f = QFont(); f.setBold(True); qi.setFont(f); qi.setBackground(QColor("#3584e4")); qi.setForeground(QColor("#ffffff"))
            self.list_model.appendRow(qi)
            if isp: si = qi.index()
        if si: self.tree_view.selectionModel().setCurrentIndex(si, QItemSelectionModel.ClearAndSelect); self.tree_view.scrollTo(si, QAbstractItemView.PositionAtCenter)
    def toggle_sort(self): self.sort_mode = 1 - self.sort_mode; self.update_playlist()
    def load_playlist_file(self, path):
        if not path or not os.path.exists(path): return
        self.m3u_groups = {}
        try:
            with open(path, 'r', encoding='utf-8', errors='ignore') as f:
                for line in f:
                    if line.strip().startswith("#EXTINF"):
                        m, nm = re.search(r'group-title\s*=\s*"([^"]+)"', line, re.I), re.search(r',([^,]+)$', line)
                        if nm: self.m3u_groups[nm.group(1).strip()] = m.group(1) if m else "Uncategorized"
        except: pass
        self.send_command({"command": ["loadlist", path, "replace"]})
        try:
            with open(self.last_m3u_file, "w", encoding="utf-8") as f: json.dump({"path": path, "sort_mode": self.sort_mode}, f)
        except: pass
        QTimer.singleShot(400, self.update_playlist)
    def auto_load_last_m3u(self):
        if os.path.exists(self.last_m3u_file):
            try:
                with open(self.last_m3u_file, "r", encoding="utf-8") as f:
                    d = json.load(f); self.sort_mode = d.get("sort_mode", 0); p = d.get("path")
                    if p: self.load_playlist_file(p); return
            except: pass
        self.update_playlist()
    def dragEnterEvent(self, e):
        if e.mimeData().hasUrls(): e.accept()
        else: e.ignore()
    def dropEvent(self, e):
        urls = e.mimeData().urls()
        if urls: self.load_playlist_file(urls[0].toLocalFile())
    def on_load_clicked(self):
        p, _ = QFileDialog.getOpenFileName(self, "Playlist", "", "M3U (*.m3u *.m3u8);;All (*)")
        if p: self.load_playlist_file(p)
    def on_clear_clicked(self): self.send_command({"command": ["playlist-clear"]}); self.m3u_groups = {}; self.update_playlist()
    def on_right_click(self, pos):
        idx = self.tree_view.indexAt(pos)
        if idx.isValid():
            item = self.list_model.itemFromIndex(idx)
            if item:
                name = item.text().replace("★ ", "").replace("▶ ", "").replace("⏸ ", "").strip()
                with self.lock:
                    if name in self.favorites: self.favorites.remove(name)
                    else: self.favorites.add(name)
                self.save_favs(); self.update_playlist()
    def on_row_activated(self, idx):
        oi = idx.data(self.USER_ROLE)
        if oi is not None: self.send_command({"command": ["set_property", "playlist-pos", oi]}); self.send_command({"command": ["set_property", "pause", False]})
if __name__ == "__main__":
    app = QApplication(sys.argv); win = MPVQtManager(); win.show(); sys.exit(app.exec())
