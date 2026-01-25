import sys
import socket
import json
import os
import subprocess
import re
import threading
from pathlib import Path
from PySide6.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QLineEdit, QListView, QPushButton, QFileDialog, QAbstractItemView, QFrame, QMenu)
from PySide6.QtCore import Qt, QTimer, Signal, QObject, QPoint
from PySide6.QtGui import QStandardItemModel, QStandardItem, QColor, QFont, QCursor
os.environ["QT_ACCESSIBILITY"] = "0"
class UpdateSignals(QObject):
    finished = Signal(object, list, str)
class MPVQtManager(QMainWindow):
    USER_ROLE = Qt.UserRole
    def __init__(self):
        super().__init__()
        self.setWindowFlags(Qt.Window | Qt.CustomizeWindowHint | Qt.WindowCloseButtonHint)
        self.setAcceptDrops(True)
        self.setWindowTitle("MPV")
        self.socket_path = "/tmp/mpvsocket"
        self.fav_file = os.path.expanduser("~/.mpv_favorites.json")
        self.last_m3u_file = os.path.expanduser("~/.mpv_last_playlist.json")
        self.config_file = os.path.expanduser("~/.mpv_qt_config.json")
        self.favorites = self.load_favs()
        self.sort_mode = 0
        self.current_playing_filename = ""
        self.current_group = "All Tracks"
        self.m3u_groups = {}
        self.full_list = []
        self.group_counts = {}
        self.is_updating = False
        self.resume_done = False
        self.last_file = ""
        self.signals = UpdateSignals()
        self.signals.finished.connect(self._finalize_update)
        self.apply_styles()
        self.ensure_mpv_running()
        self.load_window_state()
        central = QWidget()
        self.setCentralWidget(central)
        self.vbox = QVBoxLayout(central)
        self.vbox.setSpacing(10)
        self.vbox.setContentsMargins(10, 10, 10, 10)
        self.header = QHBoxLayout()
        self.header.setSpacing(5)
        self.search_entry = QLineEdit()
        self.search_entry.setPlaceholderText("Search...")
        self.search_entry.textChanged.connect(self.filter_playlist)
        self.group_btn = QPushButton("▾")
        self.group_btn.setFixedSize(35, 35)
        self.group_btn.setCursor(QCursor(Qt.PointingHandCursor))
        self.group_btn.clicked.connect(self.show_group_menu)
        self.burger_btn = QPushButton("≡")
        self.burger_btn.setFixedSize(35, 35)
        self.burger_btn.setCursor(QCursor(Qt.PointingHandCursor))
        self.burger_btn.clicked.connect(self.show_burger_menu)
        self.header.addWidget(self.search_entry)
        self.header.addWidget(self.group_btn)
        self.header.addWidget(self.burger_btn)
        self.vbox.addLayout(self.header)
        self.tree_view = QListView()
        self.tree_view.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.tree_view.setWordWrap(False)
        self.list_model = QStandardItemModel()
        self.tree_view.setModel(self.list_model)
        self.tree_view.setSelectionMode(QAbstractItemView.SingleSelection)
        self.tree_view.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.tree_view.doubleClicked.connect(self.on_row_activated)
        self.tree_view.setContextMenuPolicy(Qt.CustomContextMenu)
        self.tree_view.customContextMenuRequested.connect(self.on_right_click)
        self.tree_view.setFrameShape(QFrame.NoFrame)
        self.vbox.addWidget(self.tree_view)
        QTimer.singleShot(0, self.auto_load_last_m3u)
        self.timer = QTimer()
        self.timer.timeout.connect(self.update_now_playing)
        self.timer.start(2000)
        self.resize(320, 750)
    def apply_styles(self):
        self.setStyleSheet("""
            QMainWindow { background-color: #ffffff; }
            QLineEdit { padding: 8px 12px; border: 1px solid #eee; border-radius: 6px; background: #f9f9f9; font-size: 13px; }
            QLineEdit:focus { border: 1px solid #3584e4; background: white; }
            QPushButton { border-radius: 6px; background-color: #f5f5f5; color: #444; border: none; font-weight: bold; }
            QPushButton:hover { background-color: #ececec; }
            QListView { background-color: white; border-radius: 6px; font-size: 13px; outline: none; padding: 2px; }
            QListView::item { padding: 10px; border-radius: 4px; color: #555; margin-bottom: 1px; }
            QListView::item:hover { background-color: #f8f9fa; }
            QListView::item:selected { background-color: #3584e4; color: white; }
            QScrollBar:vertical { border: none; background: #fafafa; width: 10px; margin: 0; border-radius: 5px; }
            QScrollBar::handle:vertical { background: #ddd; min-height: 30px; border-radius: 5px; }
            QScrollBar::handle:vertical:hover { background: #3584e4; }
            QScrollBar::handle:vertical:pressed { background: #1a5fb4; }
            QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0px; }
            QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical { background: transparent; }
            QMenu { background-color: white; border: 1px solid #eee; border-radius: 6px; padding: 4px; }
            QMenu::item { padding: 6px 20px; border-radius: 3px; }
            QMenu::item:selected { background-color: #3584e4; color: white; }
        """)
    def ensure_mpv_running(self):
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(0.25)
            s.connect(self.socket_path)
            s.close()
        except Exception:
            try: subprocess.Popen(["mpv", "--idle", f"--input-ipc-server={self.socket_path}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            except Exception: pass
    def load_favs(self):
        try:
            if os.path.exists(self.fav_file):
                with open(self.fav_file, "r", encoding="utf-8") as f: return set(json.load(f))
        except Exception: pass
        return set()
    def save_favs(self):
        try:
            Path(os.path.dirname(self.fav_file) or ".").mkdir(parents=True, exist_ok=True)
            with open(self.fav_file, "w", encoding="utf-8") as f: json.dump(list(self.favorites), f)
        except Exception: pass
    def load_window_state(self):
        try:
            if os.path.exists(self.config_file):
                with open(self.config_file, "r", encoding="utf-8") as f:
                    c = json.load(f)
                    self.move(c.get("x", 100), c.get("y", 100))
                    self.resize(c.get("w", 320), c.get("h", 750))
                    self.last_file = c.get("last_file", "")
        except Exception: pass
    def closeEvent(self, event):
        try:
            g = self.geometry()
            path_res = self.send_command({"command": ["get_property", "path"]})
            curr_path = path_res.get("data", "") if path_res else ""
            Path(os.path.dirname(self.config_file) or ".").mkdir(parents=True, exist_ok=True)
            with open(self.config_file, "w", encoding="utf-8") as f:
                json.dump({"x": g.x(), "y": g.y(), "w": g.width(), "h": g.height(), "last_file": curr_path}, f)
        except Exception: pass
        super().closeEvent(event)
    def send_command(self, cmd, timeout=0.5):
        client = None
        try:
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(timeout)
            client.connect(self.socket_path)
            client.sendall(json.dumps(cmd).encode() + b"\n")
            res = b""
            while True:
                chunk = client.recv(4096)
                if not chunk: break
                res += chunk
                if res.endswith(b"\n"): break
            return json.loads(res.decode(errors="ignore"))
        except Exception: return None
        finally:
            if client:
                try: client.close()
                except Exception: pass
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
        g_counts, items = {}, []
        for idx, i in enumerate(res["data"]):
            fname = i.get("filename", "")
            name = i.get("title") or os.path.basename(fname)
            grp = self.m3u_groups.get(name, "Uncategorized")
            g_counts[grp] = g_counts.get(grp, 0) + 1
            items.append({"name": name, "filename": fname, "orig_idx": idx, "group": grp})
        def sort_priority(x):
            is_fav = x["name"] in self.favorites
            in_group = (self.current_group == "All Tracks") or (self.current_group == "★ Favorites" and is_fav) or (x["group"] == self.current_group)
            return (not in_group, not is_fav, x["name"].lower())
        full_sorted = sorted(items, key=sort_priority, reverse=(self.sort_mode == 1))
        for target_idx, item in enumerate(full_sorted):
            if item["orig_idx"] != target_idx:
                self.send_command({"command": ["playlist-move", item["orig_idx"], target_idx]})
                for other in items:
                    if other["orig_idx"] < item["orig_idx"] and other["orig_idx"] >= target_idx: other["orig_idx"] += 1
                item["orig_idx"] = target_idx
        self.signals.finished.emit(g_counts, full_sorted, curr_path)
    def _finalize_update(self, group_counts, full_sorted, curr_path):
        self.full_list = full_sorted
        self.group_counts = group_counts
        self.current_playing_filename = curr_path or ""
        self.filter_playlist()
        if not self.resume_done and self.last_file:
            for item in self.full_list:
                if item["filename"] == self.last_file:
                    self.send_command({"command": ["set_property", "playlist-pos", item["orig_idx"]]})
                    self.send_command({"command": ["set_property", "pause", True]})
                    self.resume_done = True
                    break
        self.is_updating = False
    def show_group_menu(self):
        menu = QMenu(self)
        fav_count = sum(1 for x in self.full_list if x["name"] in self.favorites)
        for g_name, count in [("All Tracks", len(self.full_list)), ("★ Favorites", fav_count)]:
            label = f"{g_name} ({count})"
            if self.current_group == g_name: label = f"• {label}"
            action = menu.addAction(label)
            action.triggered.connect(lambda checked=False, n=g_name: self.set_active_group(n))
        menu.addSeparator()
        for g in sorted(self.group_counts.keys()):
            label = f"{g} ({self.group_counts[g]})"
            if self.current_group == g: label = f"• {label}"
            action = menu.addAction(label)
            action.triggered.connect(lambda checked=False, n=g: self.set_active_group(n))
        menu.exec(self.group_btn.mapToGlobal(QPoint(0, self.group_btn.height())))
    def set_active_group(self, name):
        self.current_group = name
        self.update_playlist()
    def show_burger_menu(self):
        menu = QMenu(self)
        menu.addAction("Open Playlist").triggered.connect(self.on_load_clicked)
        menu.addAction("Toggle Sort").triggered.connect(self.toggle_sort)
        menu.addAction("Refresh").triggered.connect(self.update_playlist)
        menu.addSeparator()
        menu.addAction("Clear Playlist").triggered.connect(self.on_clear_clicked)
        menu.exec(self.burger_btn.mapToGlobal(QPoint(0, self.burger_btn.height())))
    def filter_playlist(self):
        self.list_model.clear()
        q = self.search_entry.text().lower().strip()
        scroll_to_index = None
        for item in self.full_list:
            name, grp, idx, fname = item["name"], item["group"], item["orig_idx"], item["filename"]
            is_f = name in self.favorites
            if "Favorites" in self.current_group:
                if not is_f: continue
            elif "All Tracks" not in self.current_group:
                if grp != self.current_group: continue
            if q and q not in name.lower(): continue
            is_playing = (fname == self.current_playing_filename)
            display_name = f"★ {name}" if is_f else name
            if is_playing: display_name = f"▶  {display_name}"
            q_item = QStandardItem(display_name)
            q_item.setData(idx, self.USER_ROLE)
            if is_playing:
                font = QFont(); font.setBold(True); q_item.setFont(font)
                q_item.setBackground(QColor("#3584e4")); q_item.setForeground(QColor("#ffffff"))
                scroll_to_index = q_item.index()
            self.list_model.appendRow(q_item)
        if scroll_to_index: self.tree_view.scrollTo(scroll_to_index, QAbstractItemView.PositionAtCenter)
    def update_now_playing(self):
        path_res = self.send_command({"command": ["get_property", "path"]})
        if path_res and "data" in path_res:
            if path_res["data"] != self.current_playing_filename:
                self.current_playing_filename = path_res["data"]
                self.filter_playlist()
        res = self.send_command({"command": ["get_property", "media-title"]})
        self.setWindowTitle(str(res.get('data')) if (res and "data" in res) else "MPV")
    def toggle_sort(self):
        self.sort_mode = 1 - self.sort_mode
        self.update_playlist()
    def load_playlist_file(self, path):
        if not path or not os.path.exists(path): return
        self.m3u_groups = {}
        try:
            with open(path, 'r', encoding='utf-8', errors='ignore') as f:
                for line in f:
                    if line.startswith("#EXTINF"):
                        m = re.search(r'group-title="([^"]+)"', line)
                        grp = m.group(1) if m else "Uncategorized"
                        nm = re.search(r',(.+)$', line)
                        if nm: self.m3u_groups[nm.group(1).strip()] = grp
        except Exception: pass
        self.send_command({"command": ["loadlist", path, "replace"]})
        try:
            Path(os.path.dirname(self.last_m3u_file) or ".").mkdir(parents=True, exist_ok=True)
            with open(self.last_m3u_file, "w", encoding="utf-8") as f: json.dump({"path": path, "sort_mode": self.sort_mode}, f)
        except Exception: pass
        QTimer.singleShot(500, self.update_playlist)
    def auto_load_last_m3u(self):
        if os.path.exists(self.last_m3u_file):
            try:
                with open(self.last_m3u_file, "r", encoding="utf-8") as f:
                    d = json.load(f); self.sort_mode = d.get("sort_mode", 0); p = d.get("path")
                    if p: self.load_playlist_file(p); return
            except Exception: pass
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
    def on_clear_clicked(self):
        self.send_command({"command": ["playlist-clear"]}); self.m3u_groups = {}; self.update_playlist()
    def on_right_click(self, pos):
        idx = self.tree_view.indexAt(pos)
        if idx.isValid():
            item = self.list_model.itemFromIndex(idx)
            if item:
                name = item.text().replace("★ ", "").replace("▶  ", "").replace("• ", "")
                if name in self.favorites: self.favorites.remove(name)
                else: self.favorites.add(name)
                self.save_favs(); self.update_playlist()
    def on_row_activated(self, idx):
        orig_idx = idx.data(self.USER_ROLE)
        if orig_idx is not None:
            self.send_command({"command": ["set_property", "playlist-pos", orig_idx]})
            self.send_command({"command": ["set_property", "pause", False]})
if __name__ == "__main__":
    app = QApplication(sys.argv)
    win = MPVQtManager(); win.show()
    sys.exit(app.exec())
