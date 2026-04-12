import sys, socket, json, os, subprocess, re, gi, threading, glob, urllib.request, tempfile, select
from libc.stdlib cimport malloc, free
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GLib, Gdk, GdkPixbuf, Pango, PangoCairo
import cairo, math
os.environ["QT_ACCESSIBILITY"] = "0"

cdef class PlaylistItem:
    cdef public str name
    cdef public str filename
    cdef public int orig_idx
    cdef public str group
    cdef public list nkey
    cdef public list nkey_rev
    def __init__(self, str name, str filename, int orig_idx, str group, list nkey):
        self.name = name
        self.filename = filename
        self.orig_idx = orig_idx
        self.group = group
        self.nkey = nkey
        self.nkey_rev = [-v if isinstance(v, int) else ''.join(chr(0x10FFFF - ord(c)) for c in v) for v in nkey]

class MPVGTKManager(Gtk.Window):
    def __init__(self):
        super().__init__()
        self.socket_path = "/dev/shm/mpvsocket"
        self.config_file = os.path.expanduser("~/.mpv_gtk_config.json")
        self.favorites, self.m3u_groups, self.url_to_group, self.full_list_data, self.m3u_logos = set(), {}, {}, [], {}
        self.logo_cache = {}
        self.file_lock, self.update_lock, self.favorites_lock, self.logo_lock = threading.Lock(), threading.Lock(), threading.Lock(), threading.Lock()
        self.sort_mode, self.current_playing_path, self.current_group, self.is_updating, self.resume_done, self.last_file_path, self.is_paused = 0, "", "All", False, False, "", False
        self.last_playlist_path = ""
        self.show_fab_enabled = True
        self.show_logos_enabled = True
        self.is_probing_sockets = False
        self.available_sockets = []
        self._save_pending = False

        self._re_nonword = re.compile(r'\W+')
        self._re_digit = re.compile(r'(\d+)')
        self._re_m3u_group = re.compile(r'group-title="([^"]+)"')
        self._re_m3u_logo = re.compile(r'tvg-logo="([^"]+)"')
        self._re_m3u_name = re.compile(r',(.+)$')

        # --- Logo popup window ---
        # FIX: set_decorated(False) prevents a titlebar appearing on some WMs.
        # set_skip_taskbar/pager_hint keeps it out of alt-tab and the pager.
        self.logo_popup = Gtk.Window(type=Gtk.WindowType.POPUP)
        self.logo_popup.set_decorated(False)
        self.logo_popup.set_skip_taskbar_hint(True)
        self.logo_popup.set_skip_pager_hint(True)
        rgba_visual = self.get_screen().get_rgba_visual()
        if rgba_visual is not None:
            self.logo_popup.set_visual(rgba_visual)
        self.logo_popup.set_app_paintable(True)
        # FIX: connect the draw signal so the compositor clears the window to
        # fully transparent before the child Image widget paints the pixbuf.
        # Without this the background is an opaque compositor default on many setups.
        self.logo_popup.connect("draw", self._on_logo_popup_draw)
        self.logo_image = Gtk.Image()
        self.logo_popup.add(self.logo_image)

        self.apply_css()
        self.ensure_mpv_running()
        self.set_default_size(200, 750)
        self.set_size_request(50, -1)
        self.load_all_data()

        hb = Gtk.HeaderBar(show_close_button=True, decoration_layout="menu:close")
        hb.get_style_context().add_class("compact-header")
        self.set_titlebar(hb)

        self.search_entry = Gtk.SearchEntry(placeholder_text="Search...", hexpand=True, width_chars=1)
        self.current_search_query = ""
        def on_search_changed(w):
            self.current_search_query = self.search_entry.get_text().lower()
            self.filter.refilter()
        self.search_entry.connect("changed", on_search_changed)
        hb.set_custom_title(self.search_entry)

        self.menu_button, self.group_button = Gtk.MenuButton(label="≡"), Gtk.MenuButton(label="▾")
        self.main_menu, self.group_menu = Gtk.Menu(), Gtk.Menu()
        self.socket_submenu = Gtk.Menu()
        self.socket_root_item = Gtk.MenuItem(label="Select Player")
        self.socket_root_item.set_submenu(self.socket_submenu)

        self.rebuild_main_menu()
        self.menu_button.set_popup(self.main_menu)
        self.group_button.set_popup(self.group_menu)
        hb.pack_end(self.menu_button)
        hb.pack_end(self.group_button)

        self.overlay = Gtk.Overlay()
        self.add(self.overlay)
        self.scrolled = Gtk.ScrolledWindow()
        self.overlay.add(self.scrolled)

        # Columns: 0=display_name, 1=orig_idx, 2=weight, 3=group, 4=fg, 5=bg, 6=filename, 7=raw_name, 8=raw_name_lower
        self.list_store = Gtk.ListStore(str, int, int, str, str, str, str, str, str)
        self.filter_cached_favs = set()  # Opt #6: lock-free cache for filter_func
        self.filter = self.list_store.filter_new()
        self.filter.set_visible_func(self.filter_func)
        self.tree_view = Gtk.TreeView(model=self.filter, headers_visible=False)
        self.tree_view.set_enable_search(False)
        self.tree_view.set_events(Gdk.EventMask.POINTER_MOTION_MASK | Gdk.EventMask.LEAVE_NOTIFY_MASK)
        self.tree_view.connect("button-release-event", self.on_click)
        self.tree_view.connect("key-press-event", self.on_key_press)
        self.tree_view.connect("motion-notify-event", self.on_mouse_motion)
        self.tree_view.connect("leave-notify-event", lambda w, e: self.logo_popup.hide())
        self.connect("leave-notify-event", lambda w, e: self.logo_popup.hide())

        r_txt = Gtk.CellRendererText(xpad=8, ypad=6, ellipsize=3)
        self.tree_view.append_column(Gtk.TreeViewColumn("Name", r_txt, text=0, weight=2, foreground=4, background=5))  # col 7 (raw_name) is invisible
        self.scrolled.add(self.tree_view)

        self.fab_container = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, halign=Gtk.Align.END, valign=Gtk.Align.END, margin_bottom=25, margin_right=25)
        self.revealer = Gtk.Revealer(transition_type=Gtk.RevealerTransitionType.SLIDE_UP)
        sub_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        adj = Gtk.Adjustment(value=100, lower=0, upper=130, step_increment=1, page_increment=5, page_size=0)
        self.vol_scale = Gtk.Scale(orientation=Gtk.Orientation.VERTICAL, adjustment=adj, inverted=True, draw_value=False)
        self.vol_scale.set_size_request(28, 120)
        self.vol_scale.get_style_context().add_class("fab-vol-slider")
        self.vol_scale.connect("value-changed", self.on_vol_changed)
        sub_box.pack_start(self.vol_scale, False, False, 0)

        for icon, cmd in [("media-playlist-shuffle-symbolic", ["playlist-shuffle"]), ("media-skip-forward-symbolic", ["playlist-next"]), ("media-playback-start-symbolic", ["cycle", "pause"]), ("media-skip-backward-symbolic", ["playlist-prev"])]:
            btn = Gtk.Button.new_from_icon_name(icon, Gtk.IconSize.MENU)
            btn.get_style_context().add_class("fab-button")
            if icon == "media-playlist-shuffle-symbolic":
                btn.get_style_context().add_class("fab-shuffle")
                def on_shuf(w):
                    self.sort_mode = 2
                    self.send_command({"command": ["playlist-shuffle"]})
                    self.revealer.set_reveal_child(False)
                    self.save_all_data()
                    self.update_playlist()
                btn.connect("clicked", on_shuf)
            else:
                btn.get_style_context().add_class("fab-small")
                btn.connect("clicked", lambda w, c=cmd: (self.send_command({"command": c}), self.revealer.set_reveal_child(False)))
            sub_box.pack_start(btn, False, False, 0)

        self.revealer.add(sub_box)
        self.fab_container.pack_start(self.revealer, False, False, 0)
        self.main_fab = Gtk.Button.new_from_icon_name("view-more-horizontal-symbolic", Gtk.IconSize.MENU)
        for c in ["fab-button", "fab-trigger"]: self.main_fab.get_style_context().add_class(c)
        self.main_fab.connect("clicked", self.on_fab_clicked)
        self.fab_container.pack_start(self.main_fab, False, False, 0)
        self.overlay.add_overlay(self.fab_container)
        self.fab_container.set_visible(self.show_fab_enabled)

        self.drag_dest_set(Gtk.DestDefaults.ALL, [], Gdk.DragAction.COPY)
        self.drag_dest_add_uri_targets()
        self.connect("drag-data-received", self.on_drag_data_received)
        self.connect("delete-event", self.on_delete_event)
        self.connect("configure-event", self.on_configure_event)

        self.show_all()
        GLib.idle_add(self.auto_load_last_m3u)
        GLib.timeout_add(1000, self.update_now_playing)
        GLib.timeout_add(5000, self.refresh_sockets)

    def _normalize(self, s): return self._re_nonword.sub('', s).lower() if s else ""

    def _get_nkey(self, s): return [int(t) if t.isdigit() else t.lower() for t in self._re_digit.split(s)]

    def _on_logo_popup_draw(self, widget, ctx):
        # FIX: clear the window to fully transparent before child widgets paint.
        # Required for RGBA composited windows; without this the background is
        # whatever the compositor defaults to (typically opaque grey/white).
        ctx.set_operator(cairo.OPERATOR_SOURCE)
        ctx.set_source_rgba(0, 0, 0, 0)
        ctx.paint()
        return False  # let child widgets draw on top

    def apply_css(self):
        css = b".compact-header { min-height: 24px; padding: 0; } .compact-header button { padding: 1px 2px; min-height: 20px; min-width: 20px; } .compact-header entry { min-height: 20px; margin: 2px 0; } .fab-button { border-radius: 50%; border: none; padding: 0; transition: all 150ms ease; box-shadow: none; } .fab-trigger { min-width: 32px; min-height: 32px; background: rgba(53, 132, 228, 0.7); color: white; } .fab-trigger:hover { background: rgba(53, 132, 228, 0.9); } .fab-small { min-width: 28px; min-height: 28px; background: rgba(60, 60, 60, 0.6); color: white; } .fab-small:hover { background: rgba(80, 80, 80, 0.8); } .fab-shuffle { min-width: 28px; min-height: 28px; background: rgba(60, 60, 60, 0.6); color: #444444; } .fab-shuffle:hover { background: rgba(80, 80, 80, 0.8); } .fab-vol-slider { background: rgba(60, 60, 60, 0.6); border-radius: 14px; padding: 12px 0; } scale.fab-vol-slider contents trough { background: rgba(255, 255, 255, 0.2); min-width: 4px; border-radius: 2px; margin: 0 12px; } scale.fab-vol-slider contents trough highlight { background: #3584e4; border-radius: 2px; } scale.fab-vol-slider contents trough slider { background: #3584e4; min-width: 12px; min-height: 12px; border-radius: 50%; margin: -4px; border: none; box-shadow: none; } treeview { background-color: transparent; } treeview selection { border-radius: 8px; } treeview:selected { border-radius: 8px; background-color: #3584e4; color: white; }"
        p = Gtk.CssProvider()
        p.load_from_data(css)
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), p, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    def ensure_mpv_running(self):
        if not os.path.exists(self.socket_path): subprocess.Popen(["mpv", "--idle", f"--input-ipc-server={self.socket_path}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)

    def rebuild_main_menu(self):
        for c in self.main_menu.get_children(): self.main_menu.remove(c)
        sort_labels = {0: "Sort: A-Z", 1: "Sort: Z-A"}
        current_sort_label = sort_labels.get(self.sort_mode, "Sort: A-Z")
        for l, cb in [("Open Playlist", self.on_load_clicked), (current_sort_label, self.toggle_sort), ("Refresh", lambda x: self.update_playlist()), ("Clear Playlist", self.on_clear_clicked)]:
            mi = Gtk.MenuItem(label=l)
            mi.connect("activate", cb)
            self.main_menu.append(mi)
        self.main_menu.append(Gtk.SeparatorMenuItem())
        mi_fab = Gtk.CheckMenuItem(label="Show FAB")
        mi_fab.set_active(self.show_fab_enabled)
        mi_fab.connect("toggled", self.toggle_fab_visibility)
        self.main_menu.append(mi_fab)
        mi_logos = Gtk.CheckMenuItem(label="Show Logos on Hover")
        mi_logos.set_active(self.show_logos_enabled)
        mi_logos.connect("toggled", self.toggle_logos_visibility)
        self.main_menu.append(mi_logos)
        self.main_menu.append(Gtk.SeparatorMenuItem())
        self.main_menu.append(self.socket_root_item)
        self.main_menu.show_all()

    def toggle_fab_visibility(self, mi):
        self.show_fab_enabled = mi.get_active()
        self.fab_container.set_visible(self.show_fab_enabled)
        self.save_all_data()

    def toggle_logos_visibility(self, mi):
        self.show_logos_enabled = mi.get_active()
        if not self.show_logos_enabled: self.logo_popup.hide()
        self.save_all_data()

    def refresh_sockets(self):
        if self.is_probing_sockets: return True
        self.is_probing_sockets = True
        def _bg_probe():
            try:
                sockets = sorted(glob.glob("/dev/shm/mpvsocket*") + glob.glob("/tmp/mpvsocket*"))
                new_available = []
                for s in sockets:
                    # Pass path directly — never mutate self.socket_path on a background thread.
                    title_res = self.send_command({"command": ["get_property", "media-title"]}, path=s)
                    label = title_res.get("data") if (title_res and title_res.get("data")) else os.path.basename(s)
                    new_available.append((s, label))
                GLib.idle_add(self._apply_socket_refresh, new_available)
            finally:
                self.is_probing_sockets = False
        threading.Thread(target=_bg_probe, daemon=True).start()
        return True

    def _apply_socket_refresh(self, new_list):
        self.available_sockets = new_list
        self.rebuild_socket_menu()

    def rebuild_socket_menu(self):
        for c in self.socket_submenu.get_children(): self.socket_submenu.remove(c)
        for s, label in self.available_sockets:
            mi = Gtk.MenuItem(label=f"✔ {label}" if s == self.socket_path else label)
            mi.connect("activate", self.switch_socket, s)
            self.socket_submenu.append(mi)
        self.socket_submenu.show_all()

    def switch_socket(self, mi, path):
        self.socket_path = path
        self.update_playlist()

    def send_command(self, cmd, path=None):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
                c.settimeout(0.5)
                c.connect(path or self.socket_path)
                payload = dict(cmd)
                payload["request_id"] = 999
                c.sendall(json.dumps(payload).encode() + b"\n")
                c.setblocking(False)
                res = b""
                while True:
                    r, _, _ = select.select([c], [], [], 0.5)
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
                                    if data.get("request_id") == 999: return data
                                except: continue
                            res = lines[-1]
                    else:
                        break
        except: pass
        return None

    def send_commands_batch(self, cmds):
        """Send multiple commands; flush read buffer to prevent MPV stalling."""
        if not cmds: return None
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
                c.settimeout(1.0)
                c.connect(self.socket_path)
                for cmd in cmds:
                    c.sendall(json.dumps(cmd).encode() + b"\n")
                c.setblocking(False)
                while True:
                    r, _, _ = select.select([c], [], [], 0.2)
                    if r:
                        if not c.recv(16384): break
                    else: break
        except: pass
        return None

    def send_commands_batch_read(self, cmds):
        """Opt #2: Send multiple commands over ONE socket connection and collect responses."""
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
        with self.update_lock:
            if self.is_updating: return
            self.is_updating = True
        threading.Thread(target=self._update_thread, daemon=True).start()

    def _update_thread(self):
        # All cdef declarations must appear before any executable statements in Cython.
        cdef int i, j, n, idx
        cdef bint paused
        cdef int sm
        cdef str cur_grp, curr_p, fn, name, grp
        cdef dict group_counts = {}
        cdef list items = []
        cdef list move_cmds = []
        cdef PlaylistItem it
        cdef int* c_orig_idx = NULL

        try:
            results = self.send_commands_batch_read([
                {"command": ["get_property", "playlist"]},
                {"command": ["get_property", "path"]},
                {"command": ["get_property", "pause"]}
            ])
            res = results[0] if results and len(results) > 0 else None
            path_res = results[1] if results and len(results) > 1 else None
            pause_res = results[2] if results and len(results) > 2 else None
            curr_p = path_res.get("data", "") if path_res else ""
            paused = pause_res.get("data", False) if pause_res else False
            if not res or "data" not in res:
                GLib.idle_add(self._set_updating_false)
                return

            with self.favorites_lock: fav_copy = set(self.favorites)

            for idx, entry in enumerate(res["data"]):
                fn = entry.get("filename", "")
                name = (entry.get("title") or os.path.basename(fn)).strip()
                grp = self.url_to_group.get(fn) or self.m3u_groups.get(self._normalize(name)) or "Uncategorized"
                group_counts[grp] = group_counts.get(grp, 0) + 1
                items.append(PlaylistItem(name, fn, idx, grp, self._get_nkey(name)))

            sm = self.sort_mode
            cur_grp = self.current_group

            if sm != 2:
                def sort_key(x):
                    tier = -((2 if x.name in fav_copy else 0) +
                             (1 if (cur_grp == "All" or
                                   (cur_grp == "★ Favorites" and x.name in fav_copy) or
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

            GLib.idle_add(self._finalize_update, group_counts, items, curr_p, paused)
        except Exception:
            GLib.idle_add(self._set_updating_false)

    def _set_updating_false(self):
        with self.update_lock: self.is_updating = False
        return False

    def _finalize_update(self, group_counts, list full_sorted, str curr_p, bint paused):
        cdef PlaylistItem item_obj  # declared first — required by Cython
        self.tree_view.set_model(None)
        self.list_store.clear()
        self.full_list_data, self.current_playing_path, self.is_paused = full_sorted, curr_p, paused
        with self.favorites_lock: fav_copy = set(self.favorites)
        self.filter_cached_favs = fav_copy
        active_store_path = None
        for item_obj in full_sorted:
            is_p = (item_obj.filename == curr_p)
            is_f = (item_obj.name in fav_copy)
            status_icon = "⏸ " if (is_p and paused) else ("▶ " if is_p else "")
            dn = status_icon + ("★ " if is_f else "") + item_obj.name
            # FIX: use None for fg/bg on non-playing items instead of hardcoded "#555555".
            # None tells GTK to use the theme's default text/background colour, which
            # works correctly on both light and dark themes.
            bg, fg, w = ("#3584e4", "#ffffff", 800) if is_p else (None, None, 400)
            self.list_store.append([dn, item_obj.orig_idx, w, item_obj.group, fg, bg, item_obj.filename, item_obj.name, item_obj.name.lower()])
            if is_p:
                active_store_path = len(self.list_store) - 1  # store row index

        self.rebuild_group_menu(group_counts)
        self.tree_view.set_model(self.filter)
        self.filter.refilter()

        if active_store_path is not None:
            store_iter = self.list_store.iter_nth_child(None, active_store_path)
            if store_iter:
                filter_path = self.filter.convert_child_path_to_path(
                    self.list_store.get_path(store_iter))
                if filter_path:
                    self.tree_view.get_selection().select_path(filter_path)
                    self.tree_view.scroll_to_cell(filter_path, None, True, 0.5, 0.5)

        if not self.resume_done and self.last_file_path:
            for item_obj in full_sorted:
                if item_obj.filename == self.last_file_path:
                    self.send_command({"command": ["set_property", "playlist-pos", item_obj.orig_idx]})
                    self.send_command({"command": ["set_property", "pause", True]})
                    self.resume_done = True
                    break

        with self.update_lock: self.is_updating = False
        return False

    def rebuild_group_menu(self, group_counts):
        for c in self.group_menu.get_children(): self.group_menu.remove(c)
        with self.favorites_lock: fav_copy = set(self.favorites)

        f_count = sum(1 for x in self.full_list_data if x.name in fav_copy)
        for gn, c in [("All", len(self.full_list_data)), ("★ Favorites", f_count)]:
            lbl = f"{gn} ({c})"
            item = Gtk.MenuItem(label=f"• {lbl}" if gn == self.current_group else lbl)
            item.connect("activate", self.on_group_selected, gn)
            self.group_menu.append(item)
        self.group_menu.append(Gtk.SeparatorMenuItem())

        for g in sorted(group_counts.keys()):
            lbl = f"{g} ({group_counts[g]})"
            item = Gtk.MenuItem(label=f"• {lbl}" if g == self.current_group else lbl)
            item.connect("activate", self.on_group_selected, g)
            self.group_menu.append(item)
        self.group_menu.show_all()

    def on_group_selected(self, mi, name):
        self.current_group = name
        self.save_all_data()
        self.update_playlist()

    def update_now_playing(self):
        results = self.send_commands_batch_read([
            {"command": ["get_property", "path"]},
            {"command": ["get_property", "pause"]},
            {"command": ["get_property", "media-title"]},
            {"command": ["get_property", "playlist-count"]}
        ])
        if not results: return True
        path_res = results[0]
        pause_res = results[1]
        title_res = results[2]
        count_res = results[3]
        
        new_path = path_res.get("data", "") if path_res else ""
        new_pause = pause_res.get("data", False) if pause_res else False
        new_count = count_res.get("data", -1) if count_res else -1
        
        path_changed = (new_path != self.current_playing_path)
        pause_changed = (new_pause != self.is_paused)
        count_changed = (new_count >= 0 and new_count != len(self.full_list_data))

        if count_changed or path_changed:
            self.current_playing_path = new_path
            self.is_paused = new_pause
            self.update_playlist()
        elif pause_changed:
            self.is_paused = new_pause
            self._update_playing_state_ui()

        if title_res and "data" in title_res:
            self.set_title(str(title_res.get('data')) or "MPV")
        return True

    def _update_playing_state_ui(self):
        with self.favorites_lock: fav_copy = set(self.favorites)
        curr_p = self.current_playing_path
        paused = self.is_paused
        
        for row in self.list_store:
            fn = row[6]
            nm = row[7]
            is_p = (fn == curr_p)
            is_f = (nm in fav_copy)
            status_icon = "⏸ " if (is_p and paused) else ("▶ " if is_p else "")
            dn = status_icon + ("★ " if is_f else "") + nm
            bg, fg, w = ("#3584e4", "#ffffff", 800) if is_p else (None, None, 400)
            
            if row[0] != dn: row[0] = dn
            if row[2] != w: row[2] = w
            if row[4] != fg: row[4] = fg
            if row[5] != bg: row[5] = bg

    def filter_func(self, model, tree_iter, data):
        # Opt #3: col 7 is the raw name (no prefix symbols)
        # Opt #6: use pre-snapshot favorites, no lock required here
        cg = self.current_group
        sq = self.current_search_query
        # OPT: fast path for the most common case — show-all with no search query.
        if cg == "All" and not sq: return True
        fc = self.filter_cached_favs
        name = model.get_value(tree_iter, 7)
        grp = model.get_value(tree_iter, 3)
        is_fav = name in fc
        if not is_fav and not (cg == "All" or grp == cg): return False
        if cg == "★ Favorites" and not is_fav: return False
        if not sq: return True
        name_lower = model.get_value(tree_iter, 8)
        return sq in name_lower

    def toggle_sort(self, mi):
        self.sort_mode = 1 if self.sort_mode == 0 else 0
        self.rebuild_main_menu()
        self.save_all_data()
        self.update_playlist()

    def on_load_clicked(self, mi):
        diag = Gtk.FileChooserDialog(title="Select Playlist", parent=self, action=Gtk.FileChooserAction.OPEN)
        diag.add_buttons("_Cancel", Gtk.ResponseType.CANCEL, "_Open", Gtk.ResponseType.OK)
        if diag.run() == Gtk.ResponseType.OK: self.load_playlist_file(diag.get_filename())
        diag.destroy()

    def on_clear_clicked(self, mi):
        self.send_command({"command": ["playlist-clear"]})
        self.m3u_groups, self.url_to_group, self.m3u_logos, self.logo_cache = {}, {}, {}, {}
        self.update_playlist()

    def on_click(self, tree, event):
        pi = tree.get_path_at_pos(int(event.x), int(event.y))
        if not pi: return
        if event.button == 1: self.activate_row(pi[0])
        elif event.button == 3:
            f_iter = self.filter.get_iter(pi[0])
            if f_iter:
                # Opt #3: use col 7 (raw_name) directly
                n = self.filter.get_value(f_iter, 7)
                with self.favorites_lock:
                    if n in self.favorites: self.favorites.remove(n)
                    else: self.favorites.add(n)
                self.save_all_data()
                self.update_playlist()

    def on_key_press(self, tree, event):
        if event.keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter, Gdk.KEY_space):
            model, it = tree.get_selection().get_selected()
            if it: self.activate_row(model.get_path(it)); return True
        return False

    def activate_row(self, path):
        f_iter = self.filter.get_iter(path)
        if f_iter:
            target_idx = self.filter.get_value(f_iter, 1)
            res = self.send_command({"command": ["get_property", "playlist-pos"]})
            if res and res.get("data") == target_idx:
                self.send_command({"command": ["playlist-play-index", target_idx]})
            else:
                self.send_command({"command": ["set_property", "playlist-pos", target_idx]})
            self.send_command({"command": ["set_property", "pause", False]})

    def on_mouse_motion(self, tree, event):
        if not self.show_logos_enabled: return False
        res = tree.get_path_at_pos(int(event.x), int(event.y))
        if res:
            f_iter = self.filter.get_iter(res[0])
            # Opt #3: use col 7 (raw_name) directly — no string replace needed
            name = self.filter.get_value(f_iter, 7)
            url = self.m3u_logos.get(name)
            if url:
                with self.logo_lock: cached = self.logo_cache.get(url)
                if cached: self._show_logo(cached, event.x_root, event.y_root)
                else: threading.Thread(target=self._load_logo_async, args=(url, event.x_root, event.y_root, name), daemon=True).start()
            else:
                self._show_logo(self._get_text_placeholder(name), event.x_root, event.y_root)
            return False
        self.logo_popup.hide()
        return False

    def _get_text_placeholder(self, name):
        cache_key = f"txt_{name}"
        if cache_key in self.logo_cache: return self.logo_cache[cache_key]
        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, 60, 60)
        ctx = cairo.Context(surface)
        ctx.arc(30, 30, 30, 0, 2 * math.pi)
        ctx.set_source_rgba(0, 0, 0, 0.5)
        ctx.fill()
        layout = PangoCairo.create_layout(ctx)
        layout.set_text(name, -1)
        layout.set_width(44 * Pango.SCALE)
        layout.set_wrap(Pango.WrapMode.WORD_CHAR)
        layout.set_alignment(Pango.Alignment.CENTER)
        current_size = 14
        while current_size > 5:
            desc = Pango.FontDescription(f"Sans Bold {current_size}")
            layout.set_font_description(desc)
            w, h = layout.get_pixel_size()
            if h <= 44: break
            current_size -= 1
        ctx.set_source_rgb(0.9, 0.9, 0.9)
        w, h = layout.get_pixel_size()
        ctx.move_to(8, (60 - h) / 2)
        PangoCairo.show_layout(ctx, layout)
        pb = Gdk.pixbuf_get_from_surface(surface, 0, 0, 60, 60)
        self.logo_cache[cache_key] = pb
        return pb

    def _load_logo_async(self, url, x, y, name):
        try:
            if url.startswith("http"):
                req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
                data = urllib.request.urlopen(req, timeout=1).read()
                # FIX: always close the loader, even if write() raises, to avoid
                # leaking the internal GdkPixbuf pipeline state.
                loader = GdkPixbuf.PixbufLoader()
                try:
                    loader.write(data)
                    loader.close()
                    pb = loader.get_pixbuf()
                except:
                    try: loader.close()
                    except: pass
                    pb = None
            else:
                pb = GdkPixbuf.Pixbuf.new_from_file(url)
            if pb:
                orig_w, orig_h = pb.get_width(), pb.get_height()
                scale = min(50 / orig_w, 50 / orig_h)
                nw, nh = int(orig_w * scale), int(orig_h * scale)
                pb = pb.scale_simple(nw, nh, GdkPixbuf.InterpType.BILINEAR)
                surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, 60, 60)
                ctx = cairo.Context(surface)
                ctx.arc(30, 30, 30, 0, 2 * math.pi)
                ctx.set_source_rgba(0, 0, 0, 0.5)
                ctx.fill()
                Gdk.cairo_set_source_pixbuf(ctx, pb, (60 - nw) / 2, (60 - nh) / 2)
                ctx.paint()
                round_pb = Gdk.pixbuf_get_from_surface(surface, 0, 0, 60, 60)
                with self.logo_lock:
                    if len(self.logo_cache) > 200:
                        self.logo_cache.clear()
                    self.logo_cache[url] = round_pb
                GLib.idle_add(self._show_logo, round_pb, x, y)
            else:
                GLib.idle_add(lambda: self._show_logo(self._get_text_placeholder(name), x, y))
        except:
            GLib.idle_add(lambda: self._show_logo(self._get_text_placeholder(name), x, y))

    def _show_logo(self, pb, x, y):
        if not self.show_logos_enabled: return
        self.logo_image.set_from_pixbuf(pb)
        self.logo_popup.move(x + 20, y + 10)
        self.logo_popup.show_all()

    def load_playlist_file(self, path, append=False):
        cdef bint is_remote
        cdef str lg, line, cn, cmd, cmd_type, temp_m3u, root, f_name
        cdef list files
        cdef tuple exts, pl_exts
        
        if not path: return
        is_remote = path.startswith(('http://', 'https://', 'ftp://'))
        if not append: self.m3u_groups, self.url_to_group, self.m3u_logos, self.logo_cache = {}, {}, {}, {}

        if not is_remote and os.path.isdir(path):
            files = []
            exts = ('.mkv', '.mp4', '.webm', '.avi', '.mov', '.flv', '.wmv', '.ts', '.m2ts', '.mts', '.vob', '.ogv', '.qt', '.rmvb', '.asf', '.amv', '.m4v', '.mpg', '.mpeg', '.m2v', '.divx', '.3gp', '.3g2',
                    '.mp3', '.flac', '.wav', '.opus', '.ogg', '.m4a', '.aac', '.alac', '.wma', '.aiff', '.dsf', '.dff', '.ape', '.wv', '.tta', '.mpc', '.mka', '.m4b',
                    '.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.tiff', '.svg')
            for root, dirs, fnames in os.walk(path):
                for f_name in sorted(fnames):
                    if f_name.lower().endswith(exts): files.append(os.path.join(root, f_name))
            if files:
                temp_m3u = ""
                try:
                    with tempfile.NamedTemporaryFile(mode='w', suffix='.m3u', delete=False, encoding='utf-8') as tf:
                        tf.write('#EXTM3U\n')
                        for f_name in files: tf.write(f_name + '\n')
                        temp_m3u = tf.name
                    cmd_type = "append" if append else "replace"
                    self.send_command({"command": ["loadlist", temp_m3u, cmd_type]})
                    # FIX: use a proper closure instead of the tuple-index lambda hack
                    # `(os.remove(...), False)[1]`. A named default arg captures temp_m3u
                    # correctly even if the outer scope changes before the timeout fires.
                    def _cleanup(p=temp_m3u):
                        if os.path.exists(p): os.remove(p)
                        return False
                    GLib.timeout_add(8000, _cleanup)
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
        GLib.timeout_add(500, self.update_playlist)

    def load_all_data(self):
        try:
            if os.path.exists(self.config_file):
                with open(self.config_file, "r", encoding="utf-8") as f:
                    c = json.load(f)
                    self.move(c.get("x", 100), c.get("y", 100))
                    self.resize(c.get("w", 200), c.get("h", 750))
                    self.current_group, self.last_file_path = c.get("current_group", "All"), c.get("last_playing", "")
                    self.favorites = set(c.get("favorites", []))
                    self.last_playlist_path = c.get("last_playlist_path", "")
                    self.sort_mode = c.get("sort_mode", 0)
                    self.show_fab_enabled = c.get("show_fab", True)
                    self.show_logos_enabled = c.get("show_logos", True)
        except: pass

    def save_all_data(self):
        try:
            path_res = self.send_command({"command": ["get_property", "path"]})
            curr = path_res.get("data", "") if path_res else self.last_file_path
            pos, size = self.get_position(), self.get_size()
            with self.file_lock:
                with open(self.config_file, "w", encoding="utf-8") as f:
                    json.dump({"x": pos[0], "y": pos[1], "w": size[0], "h": size[1], "current_group": self.current_group, "last_playing": curr, "favorites": list(self.favorites), "last_playlist_path": self.last_playlist_path, "sort_mode": self.sort_mode, "show_fab": self.show_fab_enabled, "show_logos": self.show_logos_enabled}, f)
        except: pass

    def on_configure_event(self, w, e):
        if not self._save_pending:
            self._save_pending = True
            GLib.timeout_add(500, self._do_save)
        return False

    def _do_save(self):
        self._save_pending = False
        self.save_all_data()
        return False

    def on_delete_event(self, w, e):
        self.save_all_data()
        Gtk.main_quit()

    def on_drag_data_received(self, w, c, x, y, s, i, t):
        uris = s.get_uris()
        if uris:
            for idx, uri in enumerate(uris):
                p = GLib.filename_from_uri(uri)[0] if uri.startswith("file://") else uri
                self.load_playlist_file(p, append=(idx > 0))
        c.finish(True, False, t)

    def auto_load_last_m3u(self):
        if self.last_playlist_path:
            is_remote = self.last_playlist_path.startswith(('http://', 'https://', 'ftp://'))
            if is_remote or os.path.exists(self.last_playlist_path):
                self.load_playlist_file(self.last_playlist_path)
                return False
        self.update_playlist()
        return False

    def on_vol_changed(self, scale):
        v = int(scale.get_value())
        self.send_command({"command": ["set_property", "volume", v]})

    def on_fab_clicked(self, btn):
        if not self.revealer.get_reveal_child():
            res = self.send_command({"command": ["get_property", "volume"]})
            if res and "data" in res: self.vol_scale.set_value(res["data"])
        self.revealer.set_reveal_child(not self.revealer.get_reveal_child())

if __name__ == "__main__":
    win = MPVGTKManager()
    Gtk.main()
