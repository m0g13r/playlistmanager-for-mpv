import sys, socket, json, os, subprocess, re, threading
from PySide6.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QLineEdit, QComboBox, QListView, QPushButton, QFileDialog, QAbstractItemView)
from PySide6.QtCore import (Qt, QTimer, Signal, QObject, QItemSelectionModel)
from PySide6.QtGui import (QStandardItemModel, QStandardItem, QIcon, QColor, QFont)
os.environ["QT_ACCESSIBILITY"] = "0"
class UpdateSignals(QObject):
    finished = Signal(set, list, str)
class MPVQtManager(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Playlist Manager")
        self.socket_path, self.fav_file = "/tmp/mpvsocket", os.path.expanduser("~/.mpv_favorites.json")
        self.last_m3u_file = os.path.expanduser("~/.mpv_last_playlist.json")
        self.config_file = os.path.expanduser("~/.mpv_qt_config.json")
        self.favorites, self.sort_mode = self.load_favs(), 0
        self.current_playing_filename = ""
        self.current_group, self.m3u_groups = "Alle", {}
        self.full_list, self.is_updating = [], False
        self.resume_done = False
        self.signals = UpdateSignals()
        self.signals.finished.connect(self._finalize_update)
        self.apply_styles()
        self.ensure_mpv_running()
        self.load_window_state()
        self.setAcceptDrops(True)
        central = QWidget()
        self.setCentralWidget(central)
        self.vbox = QVBoxLayout(central)
        self.vbox.setSpacing(5)
        self.vbox.setContentsMargins(5, 5, 5, 5)
        self.search_entry = QLineEdit()
        self.search_entry.setPlaceholderText("Suchen...")
        self.search_entry.textChanged.connect(self.filter_playlist)
        self.vbox.addWidget(self.search_entry)
        self.group_combo = QComboBox()
        self.group_combo.currentTextChanged.connect(self.on_group_changed)
        self.vbox.addWidget(self.group_combo)
        self.list_model = QStandardItemModel()
        self.tree_view = QListView()
        self.tree_view.setModel(self.list_model)
        self.tree_view.setSelectionMode(QAbstractItemView.SingleSelection)
        self.tree_view.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.tree_view.doubleClicked.connect(self.on_row_activated)
        self.tree_view.setContextMenuPolicy(Qt.CustomContextMenu)
        self.tree_view.customContextMenuRequested.connect(self.on_right_click)
        self.vbox.addWidget(self.tree_view)
        self.bbox = QHBoxLayout()
        self.bbox.setSpacing(2)
        for label, cb in [("M3U", self.on_load_clicked), ("Leeren", self.on_clear_clicked), ("A-Z", self.toggle_sort), ("Refresh", self.update_playlist)]:
            btn = QPushButton(label)
            btn.clicked.connect(cb)
            self.bbox.addWidget(btn)
        self.vbox.addLayout(self.bbox)
        QTimer.singleShot(0, self.auto_load_last_m3u)
        self.timer = QTimer()
        self.timer.timeout.connect(self.update_now_playing)
        self.timer.start(2000)
    def apply_styles(self):
        self.setStyleSheet("""
            QListView { background-color: #ffffff; color: #333333; }
            QListView::item:selected { background-color: #3584e4 !important; color: #ffffff !important; }
            QListView::item:hover { background-color: #f0f0f0; }
        """)
    def ensure_mpv_running(self):
        if not os.path.exists(self.socket_path):
            subprocess.Popen(["mpv", "--idle", f"--input-ipc-server={self.socket_path}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    def load_favs(self):
        try:
            with open(self.fav_file, "r") as f: return set(json.load(f))
        except: return set()
    def save_favs(self):
        with open(self.fav_file, "w") as f: json.dump(list(self.favorites), f)
    def load_window_state(self):
        try:
            with open(self.config_file, "r") as f:
                c = json.load(f)
                self.move(c.get("x", 100), c.get("y", 100))
                self.resize(c.get("w", 500), c.get("h", 750))
                self.last_file = c.get("last_file", "")
        except: 
            self.resize(500, 750)
            self.last_file = ""
    def closeEvent(self, event):
        g = self.geometry()
        path_res = self.send_command({"command": ["get_property", "path"]})
        curr_path = path_res.get("data", "") if path_res else ""
        with open(self.config_file, "w") as f:
            json.dump({"x": g.x(), "y": g.y(), "w": g.width(), "h": g.height(), "last_file": curr_path}, f)
        super().closeEvent(event)
    def send_command(self, cmd):
        client = None
        try:
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(0.3)
            client.connect(self.socket_path)
            client.send(json.dumps(cmd).encode() + b"\n")
            res = b""
            while not res.endswith(b"\n"):
                chunk = client.recv(4096)
                if not chunk: break
                res += chunk
            return json.loads(res.decode())
        except: return None
        finally:
            if client: client.close()
    def update_playlist(self):
        if self.is_updating: return
        self.is_updating = True
        threading.Thread(target=self._update_thread, daemon=True).start()
    def _update_thread(self):
        res = self.send_command({"command": ["get_property", "playlist"]})
        curr = self.send_command({"command": ["get_property", "path"]})
        curr_path = curr.get("data", "") if curr else ""
        if not res or "data" not in res:
            self.is_updating = False
            return
        groups, items = set(), []
        for idx, i in enumerate(res["data"]):
            fname = i.get("filename", "")
            name = i.get("title") or os.path.basename(fname)
            grp = self.m3u_groups.get(name, "Unkategorisiert")
            groups.add(grp)
            items.append({"name": name, "filename": fname, "orig_idx": idx, "group": grp})
        def sort_priority(x):
            is_fav = x["name"] in self.favorites
            in_sel_group = (self.current_group == "Alle") or (self.current_group == "★ Favoriten" and is_fav) or (x["group"] == self.current_group)
            return (not in_sel_group, not is_fav, x["name"].lower())
        full_sorted = sorted(items, key=sort_priority, reverse=(self.sort_mode == 1))
        for target_idx, item in enumerate(full_sorted):
            if item["orig_idx"] != target_idx:
                self.send_command({"command": ["playlist-move", item["orig_idx"], target_idx]})
                for other in items:
                    if other["orig_idx"] < item["orig_idx"] and other["orig_idx"] >= target_idx: other["orig_idx"] += 1
                item["orig_idx"] = target_idx
        self.signals.finished.emit(groups, full_sorted, curr_path)
    def _finalize_update(self, groups, full_sorted, curr_path):
        self.full_list = full_sorted
        self.current_playing_filename = curr_path
        self.update_combo(groups)
        self.filter_playlist()
        if not self.resume_done and self.last_file:
            for item in self.full_list:
                if item["filename"] == self.last_file:
                    self.send_command({"command": ["set_property", "playlist-pos", item["orig_idx"]]})
                    self.send_command({"command": ["set_property", "pause", True]})
                    self.resume_done = True
                    break
        self.is_updating = False
    def update_combo(self, groups):
        active = self.group_combo.currentText() or self.current_group
        self.group_combo.blockSignals(True)
        self.group_combo.clear()
        opts = ["Alle", "★ Favoriten"] + sorted(list(groups))
        self.group_combo.addItems(opts)
        idx = self.group_combo.findText(active)
        self.group_combo.setCurrentIndex(idx if idx != -1 else 0)
        self.group_combo.blockSignals(False)
    def filter_playlist(self):
        self.list_model.clear()
        q = self.search_entry.text().lower()
        icon = QIcon.fromTheme("media-playback-start")
        scroll_to_idx = None
        for item in self.full_list:
            name, grp, idx, fname = item["name"], item["group"], item["orig_idx"], item["filename"]
            is_f = name in self.favorites
            if self.current_group == "★ Favoriten":
                if not is_f: continue
            elif self.current_group != "Alle":
                if grp != self.current_group: continue
            if q and q not in name.lower(): continue
            q_item = QStandardItem(f"★ {name}" if is_f else name)
            q_item.setEditable(False)
            q_item.setData(idx, Qt.UserRole)
            is_playing = fname == self.current_playing_filename
            if is_playing:
                q_item.setIcon(icon)
                font = QFont(); font.setBold(True); q_item.setFont(font)
            else:
                q_item.setForeground(QColor("#666666"))
            self.list_model.appendRow(q_item)
            if is_playing:
                scroll_to_idx = q_item.index()
        if scroll_to_idx:
            self.tree_view.selectionModel().select(scroll_to_idx, QItemSelectionModel.ClearAndSelect)
            self.tree_view.scrollTo(scroll_to_idx, QAbstractItemView.PositionAtCenter)
    def update_now_playing(self):
        res = self.send_command({"command": ["get_property", "media-title"]})
        path_res = self.send_command({"command": ["get_property", "path"]})
        if path_res and "data" in path_res:
            new_path = path_res["data"]
            if new_path != self.current_playing_filename:
                self.current_playing_filename = new_path
                self.filter_playlist()
        title = res['data'] if res and "data" in res else "Playlist Manager"
        self.setWindowTitle(title)
    def on_group_changed(self, text):
        self.current_group = text or "Alle"
        self.update_playlist()
    def toggle_sort(self):
        self.sort_mode = 1 - self.sort_mode
        self.update_playlist()
    def load_playlist_file(self, path):
        if os.path.exists(path):
            self.m3u_groups = {}
            try:
                with open(path, 'r', encoding='utf-8', errors='ignore') as f:
                    for line in f:
                        if line.startswith("#EXTINF"):
                            m = re.search(r'group-title="([^"]+)"', line)
                            grp = m.group(1) if m else "Unkategorisiert"
                            nm = re.search(r',(.+)$', line)
                            if nm: self.m3u_groups[nm.group(1).strip()] = grp
            except: pass
            self.send_command({"command": ["loadlist", path, "replace"]})
            with open(self.last_m3u_file, "w") as f: json.dump({"path": path, "sort_mode": self.sort_mode}, f)
            QTimer.singleShot(500, self.update_playlist)
    def auto_load_last_m3u(self):
        if os.path.exists(self.last_m3u_file):
            try:
                with open(self.last_m3u_file, "r") as f:
                    d = json.load(f)
                    self.sort_mode = d.get("sort_mode", 0)
                    self.load_playlist_file(d.get("path"))
            except: pass
        else: self.update_playlist()
    def on_load_clicked(self):
        p, _ = QFileDialog.getOpenFileName(self, "M3U", "", "M3U (*.m3u *.m3u8);;All (*)")
        if p: self.load_playlist_file(p)
    def on_clear_clicked(self):
        self.send_command({"command": ["playlist-clear"]})
        self.m3u_groups = {}
        self.update_playlist()
    def dragEnterEvent(self, e):
        if e.mimeData().hasUrls(): e.accept()
        else: e.ignore()
    def dropEvent(self, e):
        urls = e.mimeData().urls()
        if urls: self.load_playlist_file(urls[0].toLocalFile())
    def on_right_click(self, pos):
        idx = self.tree_view.indexAt(pos)
        if idx.isValid():
            name = self.list_model.itemFromIndex(idx).text().replace("★ ", "")
            if name in self.favorites: self.favorites.remove(name)
            else: self.favorites.add(name)
            self.save_favs(); self.update_playlist()
    def on_row_activated(self, idx):
        self.send_command({"command": ["set_property", "playlist-pos", idx.data(Qt.UserRole)]})
        self.send_command({"command": ["set_property", "pause", False]})
if __name__ == "__main__":
    app = QApplication(sys.argv)
    win = MPVQtManager()
    win.show(); sys.exit(app.exec())
