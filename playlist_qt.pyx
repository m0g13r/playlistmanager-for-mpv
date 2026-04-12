import sys, socket, json, os, subprocess, re, threading, glob, urllib.request, tempfile, select
from libc.stdlib cimport malloc, free
from PySide6.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QLineEdit, QListView, QPushButton, QFileDialog, QAbstractItemView, QFrame, QMenu, QSlider, QLabel, QToolTip)
from PySide6.QtCore import Qt, QTimer, Signal, QObject, QPoint, QItemSelectionModel, QEvent, QRect
from PySide6.QtGui import QStandardItemModel, QStandardItem, QColor, QFont, QIcon, QPixmap, QImage, QPainter, QFontMetrics, QBrush

os.environ["QT_ACCESSIBILITY"] = "0"

cdef class PlaylistItem:
    cdef public str name
    cdef public str name_lower
    cdef public str filename
    cdef public int orig_idx
    cdef public str group
    cdef public list nkey
    cdef public list nkey_rev
    def __init__(self, str name, str filename, int orig_idx, str group, list nkey):
        self.name = name
        self.name_lower = name.lower()
        self.filename = filename
        self.orig_idx = orig_idx
        self.group = group
        self.nkey = nkey
        self.nkey_rev = [-v if isinstance(v, int) else ''.join(chr(0x10FFFF - ord(c)) for c in v) for v in nkey]

class UpdateSignals(QObject):
    finished = Signal(dict, list, str, bool)
    logo_loaded = Signal(object, QPoint)  # QPixmap for logos, str name for placeholder fallback
    sockets_refreshed = Signal(list)

class LogoPopup(QLabel):
    def __init__(self):
        super().__init__(None)
        self.setWindowFlags(Qt.ToolTip | Qt.FramelessWindowHint | Qt.WindowTransparentForInput | Qt.WindowStaysOnTopHint)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setFixedSize(64, 64)
        self.setAlignment(Qt.AlignCenter)
        self.padding = 6
    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)
        painter.setBrush(QBrush(QColor(13, 13, 13, 127)))
        painter.setPen(Qt.NoPen)
        painter.drawRoundedRect(self.rect(), 32, 32)
        if self.pixmap():
            pm = self.pixmap()
            if pm.height() == 0 or pm.width() == 0: return  # guard against degenerate pixmap
            target_rect = self.rect().adjusted(self.padding, self.padding, -self.padding, -self.padding)
            aspect_ratio = pm.width() / pm.height()
            w = target_rect.width()
            h = target_rect.height()
            if w / aspect_ratio <= h: h = w / aspect_ratio
            else: w = h * aspect_ratio
            x = target_rect.x() + (target_rect.width() - w) / 2
            y = target_rect.y() + (target_rect.height() - h) / 2
            painter.drawPixmap(QRect(int(x), int(y), int(w), int(h)), pm)

class MPVQtManager(QMainWindow):
    USER_ROLE = Qt.UserRole
    RAW_NAME_ROLE = Qt.UserRole + 1  # Opt #3: stores the plain name without prefix symbols
    def __init__(self):
        super().__init__()
        self.lock = threading.Lock()
        self.setWindowFlags(Qt.Window | Qt.CustomizeWindowHint | Qt.WindowCloseButtonHint)
        self.setAcceptDrops(True)
        self.setWindowTitle("MPV")
        self.socket_path = "/dev/shm/mpvsocket"
        self.config_file = os.path.expanduser("~/.mpv_qt_config.json")
        self._re_nonword = re.compile(r'\W+')
        self._re_digit = re.compile(r'(\d+)')
        self._re_m3u_group = re.compile(r'group-title="([^"]+)"')
        self._re_m3u_logo = re.compile(r'tvg-logo="([^"]+)"')
        self._re_m3u_name = re.compile(r',(.+)$')
        self.favorites, self.m3u_groups, self.url_to_group, self.m3u_logos, self.logo_cache = set(), {}, {}, {}, {}
        self.sort_mode, self.current_playing_filename, self.is_paused, self.current_group = 0, "", False, "All"
        self.full_list, self.group_counts, self.is_updating, self.resume_done, self.last_file, self.last_playlist_path = [], {}, False, False, "", ""
        self.show_fab_enabled, self.show_logos_enabled = True, True
        self.update_lock = threading.Lock()  # Opt #6: guard is_updating
        self.logo_lock = threading.Lock()  # guard logo_cache cross-thread access
        self.is_probing_sockets = False
        self._save_timer = None
        self.load_all_data()

        self.signals = UpdateSignals()
        self.signals.finished.connect(self._finalize_update)
        self.signals.sockets_refreshed.connect(self._apply_socket_refresh)
        self.signals.logo_loaded.connect(self._show_logo_popup)

        self.apply_styles()
        self.ensure_mpv_running()

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
        self.group_btn.setFixedSize(28, 28)
        self.burger_btn.setFixedSize(28, 28)
        self.header.addWidget(self.search_entry)
        self.header.addWidget(self.group_btn)
        self.header.addWidget(self.burger_btn)
        self.vbox.addLayout(self.header)

        self.tree_view = QListView()
        self.tree_view.setFrameShape(QFrame.NoFrame)
        self.tree_view.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.tree_view.setVerticalScrollBarPolicy(Qt.ScrollBarAsNeeded)
        self.list_model = QStandardItemModel()
        self.tree_view.setModel(self.list_model)
        self.tree_view.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.tree_view.setMouseTracking(True)
        self.tree_view.viewport().installEventFilter(self)
        self.vbox.addWidget(self.tree_view)

        self.logo_label = LogoPopup()

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

        for icon_name, cmd in [("media-playlist-shuffle-symbolic", ["playlist-shuffle"]), ("media-skip-forward-symbolic", ["playlist-next"]), ("media-playback-start-symbolic", ["cycle", "pause"]), ("media-skip-backward-symbolic", ["playlist-prev"])]:
            btn = QPushButton()
            btn.setIcon(QIcon.fromTheme(icon_name))
            if icon_name == "media-playlist-shuffle-symbolic":
                btn.setObjectName("fab-shuffle")
                btn.clicked.connect(self.on_shuffle_clicked)
            else:
                btn.setObjectName("fab-small")
                btn.clicked.connect(lambda checked=False, c=cmd: self.send_command({"command": c}))
            btn.setFixedSize(32, 32)
            self.sub_layout.addWidget(btn)

        self.sub_buttons.setVisible(False)
        self.main_fab = QPushButton()
        self.main_fab.setIcon(QIcon.fromTheme("view-more-horizontal-symbolic"))
        self.main_fab.setObjectName("fab-trigger")
        self.main_fab.setFixedSize(32, 32)
        self.main_fab.clicked.connect(self.toggle_fab)

        self.fab_layout.addWidget(self.sub_buttons)
        self.fab_layout.addWidget(self.main_fab)
        self.fab_container.setVisible(self.show_fab_enabled)

        self.group_btn.clicked.connect(self.show_group_menu)
        self.burger_btn.clicked.connect(self.show_burger_menu)
        self.tree_view.clicked.connect(self.on_row_activated)
        self.tree_view.setContextMenuPolicy(Qt.CustomContextMenu)
        self.tree_view.customContextMenuRequested.connect(self.on_right_click)

        QTimer.singleShot(0, self.auto_load_last_m3u)
        self.timer = QTimer()
        self.timer.timeout.connect(self.update_now_playing)
        self.timer.start(1000)
        self.socket_timer = QTimer()
        self.socket_timer.timeout.connect(self.refresh_sockets)
        self.socket_timer.start(5000)
        self.available_sockets = []

    def _normalize(self, s): return self._re_nonword.sub('', s).lower() if s else ""

    def _get_nkey(self, s): return [int(t) if t.isdigit() else t.lower() for t in self._re_digit.split(s)]

    def on_shuffle_clicked(self, checked=False):
        self.sort_mode = 2
        self.send_command({"command": ["playlist-shuffle"]})
        self.sub_buttons.setVisible(False)
        self.update_fab_pos()
        self.save_all_data()
        self.update_playlist()

    def apply_styles(self):
        self.setStyleSheet("""
            QMainWindow { background-color: #ffffff; }
            * { outline: none; }
            QPushButton { border: none; background-color: #f2f2f2; border-radius: 4px; color: #333; padding: 0; margin: 0; }
            QPushButton:hover { background-color: #e5e5e5; }
            QLineEdit { padding: 4px 10px; border: 1px solid #eee; border-radius: 5px; background: #f9f9f9; }
            QPushButton#fab-trigger { border-radius: 16px; background-color: rgba(53, 132, 228, 180); qproperty-iconSize: 20px; }
            QPushButton#fab-trigger:hover { background-color: rgba(53, 132, 228, 255); }
            QPushButton#fab-small { border-radius: 16px; background-color: rgba(60, 60, 60, 160); qproperty-iconSize: 16px; }
            QPushButton#fab-small:hover { background-color: rgba(80, 80, 80, 220); }
            QPushButton#fab-shuffle { border-radius: 16px; background-color: rgba(60, 60, 60, 160); qproperty-iconSize: 16px; color: #444444; }
            QPushButton#fab-shuffle:hover { background-color: rgba(80, 80, 80, 220); }

            QSlider#fab-vol { background: rgba(60, 60, 60, 160); border-radius: 16px; padding: 10px 0px; }
            QSlider::groove:vertical#fab-vol { background: rgba(255, 255, 255, 40); width: 4px; border-radius: 2px; }
            QSlider::handle:vertical#fab-vol { background: #3584e4; height: 12px; width: 12px; margin: 0 -4px; border-radius: 6px; }
            QSlider::sub-page:vertical#fab-vol { background: rgba(255, 255, 255, 40); border-radius: 2px; }
            QSlider::add-page:vertical#fab-vol { background: #3584e4; border-radius: 2px; }

            QListView { background-color: white; border: none; }
            QListView::item { padding: 6px 10px; border-radius: 8px; margin-bottom: 2px; }
            QListView::item:selected { background-color: #3584e4; color: white; }
            QScrollBar:vertical { border: none; background: transparent; width: 8px; margin: 0; }
            QScrollBar::handle:vertical { background: #ccc; border-radius: 4px; min-height: 20px; }
            QScrollBar::handle:vertical:hover { background: #3584e4; }
            QScrollBar::add-line, QScrollBar::sub-line, QScrollBar::add-page, QScrollBar::sub-page { background: none; height: 0px; }
            QToolTip { background-color: #333; color: white; border: 1px solid #555; padding: 3px; border-radius: 4px; font-weight: bold; }
        """)

    def eventFilter(self, source, event):
        if source is self.tree_view.viewport():
            if event.type() == QEvent.MouseMove and self.show_logos_enabled:
                idx = self.tree_view.indexAt(event.position().toPoint())
                if idx.isValid():
                    # Opt #3: read raw name from RAW_NAME_ROLE — no str.replace() needed
                    name = self.list_model.itemFromIndex(idx).data(self.RAW_NAME_ROLE)
                    url = self.m3u_logos.get(name)
                    pos = event.globalPosition().toPoint()
                    if url:
                        with self.logo_lock: cached = self.logo_cache.get(url)
                        if cached: self._show_logo_popup(cached, pos)
                        else: threading.Thread(target=self._load_logo_async, args=(url, pos, name), daemon=True).start()
                    else: self._show_logo_popup(self._get_text_placeholder(name), pos)
                    return False
                else: self.logo_label.hide()
            elif event.type() in [QEvent.Leave, QEvent.Wheel]: self.logo_label.hide()
        return super().eventFilter(source, event)

    def _get_text_placeholder(self, name):
        cache_key = f"txt_{name}"
        if cache_key in self.logo_cache: return self.logo_cache[cache_key]
        pix = QPixmap(64, 64)
        pix.fill(Qt.transparent)
        pnt = QPainter(pix)
        pnt.setRenderHint(QPainter.Antialiasing)
        pnt.setRenderHint(QPainter.TextAntialiasing)
        pnt.setPen(QColor("#e6e6e6"))
        fs, p, rect, flags = 11, 8, QRect(8, 8, 48, 48), Qt.AlignCenter | Qt.TextWordWrap
        font = QFont("Sans Serif", fs, QFont.Bold)
        while fs > 5:
            font.setPointSize(fs)
            pnt.setFont(font)
            fm = QFontMetrics(font)
            br = fm.boundingRect(rect, flags, name)
            if br.height() <= 48 and not any(fm.horizontalAdvance(w) > 48 for w in name.split()): break
            fs -= 1
        pnt.drawText(rect, flags, name)
        pnt.end()
        self.logo_cache[cache_key] = pix
        return pix

    def _load_logo_async(self, url, pos, name):
        # OPT: convert to QPixmap here (in the background thread) and cache it
        # directly, so _show_logo_popup never has to do a QImage→QPixmap conversion
        # on the main thread for a URL that has already been seen.
        try:
            if url.startswith("http"):
                data = urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'}), timeout=1).read()
                img = QImage.fromData(data)
            else:
                img = QImage(url)
            if not img.isNull():
                pix = QPixmap.fromImage(img).scaled(64, 64, Qt.KeepAspectRatio, Qt.SmoothTransformation)
                with self.logo_lock:
                    if len(self.logo_cache) > 200:
                        self.logo_cache = {k: v for k, v in self.logo_cache.items() if k.startswith("txt_")}
                    self.logo_cache[url] = pix
                self.signals.logo_loaded.emit(pix, pos)
            else:
                self.signals.logo_loaded.emit(name, pos)
        except:
            self.signals.logo_loaded.emit(name, pos)

    def _show_logo_popup(self, img_or_name, pos):
        if not self.tree_view.underMouse() or not self.show_logos_enabled: return
        if isinstance(img_or_name, str):
            # Fallback: no image loaded or URL failed — show text placeholder.
            pix = self._get_text_placeholder(img_or_name)
        else:
            # QPixmap: either from the cache, from _load_logo_async (now always
            # converted to QPixmap before caching), or from _get_text_placeholder.
            pix = img_or_name
        self.logo_label.setPixmap(pix)
        self.logo_label.move(pos.x() + 15, pos.y() + 15)
        if self.logo_label.isHidden(): self.logo_label.show()

    def toggle_fab(self):
        self.sub_buttons.setVisible(not self.sub_buttons.isVisible())
        if self.sub_buttons.isVisible():
            res = self.send_command({"command": ["get_property", "volume"]})
            if res and "data" in res:
                self.vol_slider.blockSignals(True)
                self.vol_slider.setValue(int(res["data"]))
                self.vol_slider.blockSignals(False)
        self.update_fab_pos()

    def on_vol_changed(self, val):
        self.send_command({"command": ["set_property", "volume", val]})
        QToolTip.showText(self.vol_slider.mapToGlobal(QPoint(-55, 50)), f"{val}%", self.vol_slider)

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self.update_fab_pos()
        self._schedule_save()

    def _schedule_save(self):
        if self._save_timer is None:
            self._save_timer = QTimer()
            self._save_timer.setSingleShot(True)
            self._save_timer.timeout.connect(self._do_save)
        self._save_timer.start(500)

    def _do_save(self):
        self.save_all_data()

    def moveEvent(self, event): super().moveEvent(event); self._schedule_save()

    def update_fab_pos(self):
        h = 32
        if self.sub_buttons.isVisible():
            h = 32 + 6 + 120 + 6 + (4 * 32) + (3 * 6) + 10
        self.fab_container.setFixedSize(32, h)
        self.fab_container.move(self.width() - 52, self.height() - h - 20)

    def ensure_mpv_running(self):
        if not os.path.exists(self.socket_path): subprocess.Popen(["mpv", "--idle", f"--input-ipc-server={self.socket_path}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)

    def refresh_sockets(self):
        if self.is_probing_sockets: return True
        self.is_probing_sockets = True
        def _bg_probe():
            try:
                new_sockets = []
                for s in sorted(glob.glob("/dev/shm/mpvsocket*") + glob.glob("/tmp/mpvsocket*")):
                    # Pass path directly — never mutate self.socket_path on a background thread.
                    title_res = self.send_command({"command": ["get_property", "media-title"]}, path=s)
                    new_sockets.append((s, title_res.get("data") if (title_res and title_res.get("data")) else os.path.basename(s)))
                self.signals.sockets_refreshed.emit(new_sockets)
            finally:
                self.is_probing_sockets = False
        threading.Thread(target=_bg_probe, daemon=True).start()
        return True

    def _apply_socket_refresh(self, new_list):
        self.available_sockets = new_list

    def send_command(self, cmd, timeout=0.5, path=None):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
                c.settimeout(timeout); c.connect(path or self.socket_path); c.sendall(json.dumps(cmd).encode() + b"\n")
                c.setblocking(False)
                res = b""
                while True:
                    r, _, _ = select.select([c], [], [], timeout)
                    if r:
                        chunk = c.recv(16384)
                        if not chunk: break
                        res += chunk
                        lines = res.split(b"\n")
                        if len(lines) > 1:
                            for line in lines[:-1]:
                                if not line.strip(): continue
                                try:
                                    data = json.loads(line.decode(errors="ignore"))
                                    if any(k in data for k in ["request_id", "error", "data"]): return data
                                except: continue
                            res = lines[-1]
                    else:
                        break
        except: pass
        return None

    def send_commands_batch(self, cmds):
        """Fire-and-forget batch send (no response needed, e.g. playlist-move)."""
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
                c.settimeout(1.0)
                c.connect(self.socket_path)
                for cmd in cmds:
                    c.sendall(json.dumps(cmd).encode() + b"\n")
        except: pass
        return None

    def send_commands_batch_read(self, cmds):
        """Opt #2: Send multiple commands over ONE socket connection and collect all responses."""
        results = [None] * len(cmds)
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
                c.settimeout(1.0)
                c.connect(self.socket_path)
                for i, cmd in enumerate(cmds):
                    payload = dict(cmd)
                    payload["request_id"] = i
                    c.sendall(json.dumps(payload).encode() + b"\n")
                c.setblocking(False)
                buf = b""
                received = 0
                while received < len(cmds):
                    r, _, _ = select.select([c], [], [], 1.0)
                    if r:
                        chunk = c.recv(16384)
                        if not chunk: break
                        buf += chunk
                        lines = buf.split(b"\n")
                        for line in lines[:-1]:
                            if not line.strip(): continue
                            try:
                                data = json.loads(line.decode(errors="ignore"))
                                rid = data.get("request_id")
                                if rid is not None and 0 <= rid < len(cmds):
                                    results[rid] = data
                                    received += 1
                            except: continue
                        buf = lines[-1]
                    else:
                        break
        except: pass
        return results

    def update_playlist(self):
        # Opt #6: guard is_updating with lock to avoid race condition
        with self.update_lock:
            if self.is_updating: return
            self.is_updating = True
        threading.Thread(target=self._update_thread, daemon=True).start()

    def _update_thread(self):
        # All cdef declarations must appear before any executable statements in Cython.
        cdef int i, j, n
        cdef int sm
        cdef str cur_grp
        cdef list items = []
        cdef list move_cmds = []
        cdef dict gc = {}
        cdef PlaylistItem it
        cdef int* c_orig_idx = NULL

        try:
            results = self.send_commands_batch_read([
                {"command": ["get_property", "playlist"]},
                {"command": ["get_property", "path"]},
                {"command": ["get_property", "pause"]}
            ])
            res = results[0] if results and len(results) > 0 else None
            curr = results[1] if results and len(results) > 1 else None
            pause_res = results[2] if results and len(results) > 2 else None
            cp, ps = (curr.get("data", "") if curr else ""), (pause_res.get("data", False) if pause_res else False)
            if not res or "data" not in res:
                with self.update_lock: self.is_updating = False
                return

            with self.lock: fc = set(self.favorites)

            for idx, entry in enumerate(res["data"]):
                fn = entry.get("filename", "")
                nm = (entry.get("title") or os.path.basename(fn)).strip()
                grp = self.url_to_group.get(fn) or self.m3u_groups.get(self._normalize(nm)) or "Uncategorized"
                gc[grp] = gc.get(grp, 0) + 1
                items.append(PlaylistItem(nm, fn, idx, grp, self._get_nkey(nm)))

            cur_grp = self.current_group
            sm = self.sort_mode

            if sm != 2:
                def sort_key(x):
                    tier = -((2 if x.name in fc else 0) +
                             (1 if (cur_grp == "All" or
                                   (cur_grp == "★ Favorites" and x.name in fc) or
                                   x.group == cur_grp) else 0))
                    return (tier, x.nkey_rev if sm == 1 else x.nkey, x.filename)
                items.sort(key=sort_key)

            n = len(items)

            if n > 0:
                c_orig_idx = <int*>malloc(n * sizeof(int))
                if c_orig_idx != NULL:
                    try:
                        for i in range(n):
                            it = <PlaylistItem>items[i]
                            c_orig_idx[i] = it.orig_idx

                        for i in range(n):
                            if c_orig_idx[i] != i:
                                move_cmds.append({"command": ["playlist-move", c_orig_idx[i], i]})
                                for j in range(n):
                                    if c_orig_idx[j] < c_orig_idx[i] and c_orig_idx[j] >= i:
                                        c_orig_idx[j] += 1
                                    elif c_orig_idx[j] > c_orig_idx[i] and c_orig_idx[j] <= i:
                                        c_orig_idx[j] -= 1
                                c_orig_idx[i] = i

                        for i in range(n):
                            it = <PlaylistItem>items[i]
                            it.orig_idx = c_orig_idx[i]
                    finally:
                        free(c_orig_idx)

            if move_cmds:
                self.send_commands_batch(move_cmds)

            self.signals.finished.emit(gc, items, cp, ps)
        except Exception:
            with self.update_lock: self.is_updating = False

    def _finalize_update(self, group_counts, full_sorted, curr_path, is_paused):
        self.full_list, self.group_counts, self.current_playing_filename, self.is_paused = full_sorted, group_counts, curr_path or "", is_paused
        self.filter_playlist()
        if not self.resume_done and self.last_file:
            for item in self.full_list:
                if item.filename == self.last_file:
                    self.send_command({"command": ["set_property", "playlist-pos", item.orig_idx]})
                    self.send_command({"command": ["set_property", "pause", True]})
                    self.resume_done = True
                    break
        with self.update_lock: self.is_updating = False  # Opt #6

    def show_group_menu(self):
        menu = QMenu(self)
        with self.lock: fc = set(self.favorites)
        f_count = sum(1 for x in self.full_list if x.name in fc)
        for gn, c in [("All", len(self.full_list)), ("★ Favorites", f_count)]:
            lbl = f"{gn} ({c})"
            if self.current_group == gn: lbl = f"• {lbl}"
            menu.addAction(lbl).triggered.connect(lambda chk=False, n=gn: self.set_active_group(n))
        menu.addSeparator()
        for g in sorted(self.group_counts.keys()):
            lbl = f"{g} ({self.group_counts[g]})"
            if self.current_group == g: lbl = f"• {lbl}"
            menu.addAction(lbl).triggered.connect(lambda chk=False, n=g: self.set_active_group(n))
        menu.exec(self.group_btn.mapToGlobal(QPoint(0, 28)))

    def set_active_group(self, name):
        self.current_group = name
        self.save_all_data()
        self.update_playlist()

    def show_burger_menu(self):
        menu = QMenu(self)
        sort_labels = {0: "Sort: A-Z", 1: "Sort: Z-A"}
        current_sort_label = sort_labels.get(self.sort_mode, "Sort: A-Z")
        for l, cb in [("Open Playlist", self.on_load_clicked), (current_sort_label, self.toggle_sort), ("Refresh", self.update_playlist)]:
            menu.addAction(l).triggered.connect(lambda chk=False, f=cb: f())
        menu.addSeparator()
        for l, state, cb in [("Show FAB", self.show_fab_enabled, self.toggle_fab_v), ("Show Logos on Hover", self.show_logos_enabled, self.toggle_logos_v)]:
            mi = menu.addAction(l)
            mi.setCheckable(True); mi.setChecked(state); mi.triggered.connect(cb)
        menu.addSeparator()
        sm = menu.addMenu("Select Player")
        for p, l in self.available_sockets:
            sm.addAction(f"✔ {l}" if p == self.socket_path else l).triggered.connect(lambda chk=False, path=p: self.switch_socket(path))
        menu.addSeparator()
        menu.addAction("Clear Playlist").triggered.connect(lambda chk=False: self.on_clear_clicked())
        menu.exec(self.burger_btn.mapToGlobal(QPoint(0, 28)))

    def toggle_fab_v(self, chk):
        self.show_fab_enabled = chk
        self.fab_container.setVisible(chk)
        # FIX: reposition the FAB container when it becomes visible — without this
        # the container sits at (0, 0) if the window was resized while it was hidden.
        if chk: self.update_fab_pos()
        self.save_all_data()

    def toggle_logos_v(self, chk):
        self.show_logos_enabled = chk
        if not chk: self.logo_label.hide()
        self.save_all_data()

    def switch_socket(self, p): self.socket_path = p; self.update_playlist()

    def filter_playlist(self):
        # Opt #5: filter_playlist runs on main thread — a snapshot copy is sufficient,
        # no lock needed during iteration itself.
        self.tree_view.setModel(None)
        self.list_model.clear(); q = self.search_entry.text().lower().strip(); si = None
        with self.lock: fc = set(self.favorites)
        show_all = (self.current_group == "All")
        show_favs = (self.current_group == "★ Favorites")
        for i in self.full_list:
            nm, grp, idx, fn = i.name, i.group, i.orig_idx, i.filename
            isf = nm in fc
            if not show_all:
                if show_favs and not isf: continue
                if not show_favs and not isf and grp != self.current_group: continue
            if q and q not in i.name_lower: continue
            isp = (fn == self.current_playing_filename)
            dnm = (f"{'⏸ ' if self.is_paused else '▶ '}" if isp else "") + (f"★ {nm}" if isf else nm)
            qi = QStandardItem(dnm)
            qi.setData(idx, self.USER_ROLE)
            qi.setData(nm, self.RAW_NAME_ROLE)  # Opt #3: store raw name for O(1) lookup
            if isp:
                f = QFont(); f.setBold(True); qi.setFont(f); qi.setBackground(QColor("#3584e4")); qi.setForeground(QColor("#ffffff")); si = qi
            self.list_model.appendRow(qi)
        self.tree_view.setModel(self.list_model)
        if si:
            idx = self.list_model.indexFromItem(si)
            self.tree_view.selectionModel().setCurrentIndex(idx, QItemSelectionModel.ClearAndSelect)
            self.tree_view.scrollTo(idx, QAbstractItemView.PositionAtCenter)

    def update_now_playing(self):
        # Opt #2: fetch path, pause, media-title in ONE socket connection
        results = self.send_commands_batch_read([
            {"command": ["get_property", "path"]},
            {"command": ["get_property", "pause"]},
            {"command": ["get_property", "media-title"]},
        ])
        path_res, pause_res, title_res = results
        new_path = path_res.get("data", "") if path_res else ""
        new_pause = pause_res.get("data", False) if pause_res else False
        if new_path != self.current_playing_filename or new_pause != self.is_paused:
            self.current_playing_filename = new_path
            self.is_paused = new_pause
            self.update_playlist()
        if title_res and "data" in title_res:
            self.setWindowTitle(str(title_res['data']))

    def toggle_sort(self): self.sort_mode = 1 if self.sort_mode == 0 else 0; self.save_all_data(); self.update_playlist()

    def load_playlist_file(self, path, append=False):
        if not path: return
        is_remote = path.startswith(('http://', 'https://', 'ftp://'))
        if not append: self.m3u_groups, self.url_to_group, self.m3u_logos, self.logo_cache = {}, {}, {}, {}

        if not is_remote and os.path.isdir(path):
            files = []
            exts = ('.mkv', '.mp4', '.webm', '.avi', '.mov', '.flv', '.wmv', '.ts', '.m2ts', '.mts', '.vob', '.ogv', '.qt', '.rmvb', '.asf', '.amv', '.m4v', '.mpg', '.mpeg', '.m2v', '.divx', '.3gp', '.3g2',
                    '.mp3', '.flac', '.wav', '.opus', '.ogg', '.m4a', '.aac', '.alac', '.wma', '.aiff', '.dsf', '.dff', '.ape', '.wv', '.tta', '.mpc', '.mka', '.m4b',
                    '.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.tiff', '.svg')
            for root, dirs, fnames in os.walk(path):
                for f in sorted(fnames):
                    if f.lower().endswith(exts): files.append(os.path.join(root, f))
            if files:
                temp_m3u = ""
                try:
                    with tempfile.NamedTemporaryFile(mode='w', suffix='.m3u', delete=False, encoding='utf-8') as tf:
                        tf.write('#EXTM3U\n')
                        for f in files: tf.write(f + '\n')
                        temp_m3u = tf.name
                    cmd_type = "append" if append else "replace"
                    self.send_command({"command": ["loadlist", temp_m3u, cmd_type]})
                    QTimer.singleShot(8000, lambda: os.remove(temp_m3u) if os.path.exists(temp_m3u) else None)
                except:
                    if temp_m3u and os.path.exists(temp_m3u): os.remove(temp_m3u)
        else:
            pl_exts = ('.m3u', '.m3u8', '.pls', '.xspf', '.cue', '.asx', '.txt')
            cmd_type = "append" if append else "replace"
            if not is_remote and os.path.exists(path) and path.lower().split('?')[0].endswith(pl_exts):
                try:
                    re_group = self._re_m3u_group
                    re_logo = self._re_m3u_logo
                    re_name = self._re_m3u_name
                    with open(path, 'r', encoding='utf-8', errors='ignore') as f:
                        lg = "Uncategorized"
                        for line in f:
                            line = line.strip()
                            if line.startswith("#EXTINF"):
                                m = re_group.search(line)
                                logo = re_logo.search(line)
                                nm = re_name.search(line)
                                lg = m.group(1) if m else "Uncategorized"
                                if nm:
                                    cn = nm.group(1).strip()
                                    self.m3u_groups[self._normalize(cn)] = lg
                                    if logo: self.m3u_logos[cn] = logo.group(1)
                            elif line and not line.startswith("#"): self.url_to_group[line] = lg
                except: pass

            cmd = "loadlist" if path.lower().split('?')[0].endswith(pl_exts) else "loadfile"
            self.send_command({"command": [cmd, path, cmd_type]})

        if not append: self.last_playlist_path = path
        self.save_all_data()
        self.send_command({"command": ["set_property", "pause", False]})
        QTimer.singleShot(500, self.update_playlist)

    def auto_load_last_m3u(self):
        if self.last_playlist_path:
            is_remote = self.last_playlist_path.startswith(('http://', 'https://', 'ftp://'))
            if is_remote or os.path.exists(self.last_playlist_path):
                self.load_playlist_file(self.last_playlist_path)
                return
        self.update_playlist()

    def dragEnterEvent(self, e): e.acceptProposedAction() if e.mimeData().hasUrls() else e.ignore()
    def dragMoveEvent(self, e): e.acceptProposedAction() if e.mimeData().hasUrls() else e.ignore()
    def dropEvent(self, e):
        urls = e.mimeData().urls()
        if urls:
            for idx, u in enumerate(urls):
                p = u.toLocalFile() if u.isLocalFile() else u.toString()
                self.load_playlist_file(p, append=(idx > 0))
            e.acceptProposedAction()

    def on_load_clicked(self):
        p, _ = QFileDialog.getOpenFileName(self, "Playlist", "", "All (*)")
        if p: self.load_playlist_file(p)

    def on_clear_clicked(self):
        self.send_command({"command": ["playlist-clear"]})
        self.m3u_groups, self.url_to_group, self.m3u_logos, self.logo_cache = {}, {}, {}, {}
        self.update_playlist()

    def on_right_click(self, pos):
        idx = self.tree_view.indexAt(pos)
        if idx.isValid():
            # Opt #3: read raw name from RAW_NAME_ROLE — no str.replace() needed
            name = self.list_model.itemFromIndex(idx).data(self.RAW_NAME_ROLE)
            with self.lock:
                if name in self.favorites: self.favorites.remove(name)
                else: self.favorites.add(name)
            self.save_all_data(); self.update_playlist()

    def on_row_activated(self, idx):
        oi = idx.data(self.USER_ROLE)
        if oi is not None:
            res = self.send_command({"command": ["get_property", "playlist-pos"]})
            if res and res.get("data") == oi:
                self.send_command({"command": ["playlist-play-index", oi]})
            else:
                self.send_command({"command": ["set_property", "playlist-pos", oi]})
            self.send_command({"command": ["set_property", "pause", False]})

    def load_all_data(self):
        try:
            if os.path.exists(self.config_file):
                with open(self.config_file, "r", encoding="utf-8") as f:
                    c = json.load(f)
                    self.move(c.get("x", 100), c.get("y", 100)); self.resize(c.get("w", 200), c.get("h", 750))
                    self.current_group, self.last_file = c.get("current_group", "All"), c.get("last_playing", "")
                    self.favorites = set(c.get("favorites", []))
                    self.last_playlist_path = c.get("last_playlist_path", "")
                    self.sort_mode = c.get("sort_mode", 0)
                    self.show_fab_enabled = c.get("show_fab", True)
                    self.show_logos_enabled = c.get("show_logos", True)
        except: pass

    def save_all_data(self):
        try:
            pr = self.send_command({"command": ["get_property", "path"]})
            cp = pr.get("data", "") if pr else self.last_file
            with self.lock:
                with open(self.config_file, "w", encoding="utf-8") as f:
                    json.dump({"x": self.x(), "y": self.y(), "w": self.width(), "h": self.height(), "current_group": self.current_group, "last_playing": cp, "favorites": list(self.favorites), "last_playlist_path": self.last_playlist_path, "sort_mode": self.sort_mode, "show_fab": self.show_fab_enabled, "show_logos": self.show_logos_enabled}, f)
        except: pass

    def closeEvent(self, event): self.save_all_data(); super().closeEvent(event)

if __name__ == "__main__":
    app = QApplication(sys.argv); win = MPVQtManager(); win.show(); sys.exit(app.exec())
