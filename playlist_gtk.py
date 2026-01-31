import sys, socket, json, os, subprocess, re, gi, threading, glob
from pathlib import Path
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GObject, GLib, Gdk
os.environ["QT_ACCESSIBILITY"] = "0"
class MPVGTKManager(Gtk.Window):
    def __init__(self):
        super().__init__()
        self.socket_path, self.fav_file = "/dev/shm/mpvsocket", os.path.expanduser("~/.mpv_favorites.json")
        self.last_m3u_file, self.config_file = os.path.expanduser("~/.mpv_last_playlist.json"), os.path.expanduser("~/.mpv_gtk_config.json")
        self.favorites, self.m3u_groups, self.full_list_data = self.load_favs(), {}, []
        self.file_lock, self.update_lock, self.favorites_lock = threading.Lock(), threading.Lock(), threading.Lock()
        self.sort_mode, self.current_playing_path, self.current_group, self.is_updating, self.resume_done, self.last_file_path, self.is_paused = 0, "", "All", False, False, "", False
        self.apply_css()
        self.ensure_mpv_running()
        self.set_default_size(200, 750)
        self.set_size_request(50, -1)
        self.load_window_state()
        hb = Gtk.HeaderBar(show_close_button=True, decoration_layout="menu:close")
        hb.get_style_context().add_class("compact-header")
        self.set_titlebar(hb)
        self.search_entry = Gtk.SearchEntry(placeholder_text="Search...", hexpand=True, width_chars=1)
        self.search_entry.connect("changed", lambda w: self.filter.refilter())
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
        self.list_store = Gtk.ListStore(str, int, int, str, str, str, str)
        self.filter = self.list_store.filter_new()
        self.filter.set_visible_func(self.filter_func)
        self.tree_view = Gtk.TreeView(model=self.filter, headers_visible=False)
        self.tree_view.connect("button-release-event", self.on_click)
        self.tree_view.connect("key-release-event", self.on_key_release)
        r_txt = Gtk.CellRendererText(xpad=8, ypad=6, ellipsize=3)
        self.tree_view.append_column(Gtk.TreeViewColumn("Name", r_txt, text=0, weight=2, foreground=4, background=5))
        self.scrolled.add(self.tree_view)
        self.fab_container = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, halign=Gtk.Align.END, valign=Gtk.Align.END, margin_bottom=25, margin_right=25)
        self.revealer = Gtk.Revealer(transition_type=Gtk.RevealerTransitionType.SLIDE_UP)
        sub_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.vol_scale = Gtk.Scale(orientation=Gtk.Orientation.VERTICAL, adjustment=Gtk.Adjustment(100, 0, 130, 1, 5, 0), inverted=True, draw_value=False)
        self.vol_scale.set_size_request(28, 120)
        self.vol_scale.get_style_context().add_class("fab-vol-slider")
        self.vol_scale.connect("value-changed", self.on_vol_changed)
        sub_box.pack_start(self.vol_scale, False, False, 0)
        for icon, cmd in [("media-skip-forward-symbolic", ["playlist-next"]), ("media-playback-start-symbolic", ["cycle", "pause"]), ("media-skip-backward-symbolic", ["playlist-prev"])]:
            btn = Gtk.Button.new_from_icon_name(icon, Gtk.IconSize.MENU)
            for cls in ["fab-button", "fab-small"]: btn.get_style_context().add_class(cls)
            btn.connect("clicked", lambda w, c=cmd: (self.send_command({"command": c}), self.revealer.set_reveal_child(False)))
            sub_box.pack_start(btn, False, False, 0)
        self.revealer.add(sub_box)
        self.fab_container.pack_start(self.revealer, False, False, 0)
        self.main_fab = Gtk.Button.new_from_icon_name("view-more-horizontal-symbolic", Gtk.IconSize.MENU)
        for c in ["fab-button", "fab-trigger"]: self.main_fab.get_style_context().add_class(c)
        self.main_fab.connect("clicked", self.on_fab_clicked)
        self.fab_container.pack_start(self.main_fab, False, False, 0)
        self.overlay.add_overlay(self.fab_container)
        self.drag_dest_set(Gtk.DestDefaults.ALL, [], Gdk.DragAction.COPY)
        self.drag_dest_add_uri_targets()
        self.connect("drag-data-received", self.on_drag_data_received)
        self.connect("delete-event", self.on_delete_event)
        self.connect("configure-event", self.on_configure_event)
        self.show_all()
        GLib.idle_add(self.auto_load_last_m3u)
        GLib.timeout_add(1000, self.update_now_playing)
        GLib.timeout_add(5000, self.refresh_sockets)
    def apply_css(self):
        css = b".compact-header { min-height: 24px; padding: 0; } .compact-header button { padding: 1px 2px; min-height: 20px; min-width: 20px; } .compact-header entry { min-height: 20px; margin: 2px 0; } .fab-button { border-radius: 50%; border: none; padding: 0; transition: all 150ms ease; box-shadow: none; } .fab-trigger { min-width: 32px; min-height: 32px; background: rgba(53, 132, 228, 0.7); color: white; } .fab-trigger:hover { background: rgba(53, 132, 228, 0.9); } .fab-small { min-width: 28px; min-height: 28px; background: rgba(60, 60, 60, 0.6); color: white; } .fab-small:hover { background: rgba(80, 80, 80, 0.8); } .fab-vol-slider { background: rgba(60, 60, 60, 0.6); border-radius: 14px; padding: 12px 0; } scale.fab-vol-slider contents trough { background: rgba(255, 255, 255, 0.2); min-width: 4px; border-radius: 2px; margin: 0 12px; } scale.fab-vol-slider contents trough highlight { background: #3584e4; border-radius: 2px; } scale.fab-vol-slider contents trough slider { background: #3584e4; min-width: 12px; min-height: 12px; border-radius: 50%; margin: -4px; border: none; box-shadow: none; } treeview { background-color: transparent; } treeview selection { border-radius: 8px; } treeview:selected { border-radius: 8px; background-color: #3584e4; color: white; }"
        p = Gtk.CssProvider()
        p.load_from_data(css)
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), p, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
    def ensure_mpv_running(self):
        if not os.path.exists(self.socket_path): subprocess.Popen(["mpv", "--idle", f"--input-ipc-server={self.socket_path}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    def rebuild_main_menu(self):
        for c in self.main_menu.get_children(): self.main_menu.remove(c)
        for l, cb in [("Open Playlist", self.on_load_clicked), ("Toggle Sorting", self.toggle_sort), ("Refresh", lambda x: self.update_playlist()), ("Clear Playlist", self.on_clear_clicked)]:
            mi = Gtk.MenuItem(label=l)
            mi.connect("activate", cb)
            self.main_menu.append(mi)
        self.main_menu.append(Gtk.SeparatorMenuItem())
        self.main_menu.append(self.socket_root_item)
        self.main_menu.show_all()
    def refresh_sockets(self):
        for c in self.socket_submenu.get_children(): self.socket_submenu.remove(c)
        sockets = glob.glob("/dev/shm/mpvsocket*") + glob.glob("/tmp/mpvsocket*")
        for s in sockets:
            old_path = self.socket_path
            self.socket_path = s
            title_res = self.send_command({"command": ["get_property", "media-title"]})
            self.socket_path = old_path
            label = title_res.get("data") if (title_res and title_res.get("data")) else os.path.basename(s)
            mi = Gtk.MenuItem(label=f"✔ {label}" if s == self.socket_path else label)
            mi.connect("activate", self.switch_socket, s)
            self.socket_submenu.append(mi)
        self.socket_submenu.show_all()
        return True
    def switch_socket(self, mi, path):
        self.socket_path = path; self.update_playlist()
    def load_favs(self):
        try:
            if os.path.exists(self.fav_file):
                with open(self.fav_file, "r", encoding="utf-8") as f: return set(json.load(f))
        except: pass
        return set()
    def save_favs(self):
        with self.file_lock:
            Path(os.path.dirname(self.fav_file) or ".").mkdir(parents=True, exist_ok=True)
            with open(self.fav_file, "w", encoding="utf-8") as f: json.dump(list(self.favorites), f)
    def send_command(self, cmd):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
                c.settimeout(0.5); c.connect(self.socket_path); c.sendall(json.dumps(cmd).encode() + b"\n")
                res = b""
                while True:
                    chunk = c.recv(8192)
                    if not chunk: break
                    res += chunk
                    if b"\n" in res: break
                if res:
                    for line in res.decode(errors="ignore").splitlines():
                        try:
                            data = json.loads(line)
                            if "request_id" in data or "error" in data: return data
                        except: continue
        except: return None
    def update_playlist(self):
        with self.update_lock:
            if self.is_updating: return
            self.is_updating = True
        threading.Thread(target=self._update_thread, daemon=True).start()
    def _update_thread(self):
        res, path_res, pause_res = self.send_command({"command": ["get_property", "playlist"]}), self.send_command({"command": ["get_property", "path"]}), self.send_command({"command": ["get_property", "pause"]})
        curr_p = path_res.get("data", "") if path_res else ""
        self.is_paused = pause_res.get("data", False) if pause_res else False
        if not res or "data" not in res:
            with self.update_lock: self.is_updating = False
            return
        groups, items = set(), []
        with self.favorites_lock: fav_copy = set(self.favorites)
        for idx, i in enumerate(res["data"]):
            fn = i.get("filename", ""); name = i.get("title") or os.path.basename(fn); grp = self.m3u_groups.get(name, "Uncategorized"); groups.add(grp); items.append({"name": name, "filename": fn, "orig_idx": idx, "group": grp})
        def sort_p(x):
            is_fav = x["name"] in fav_copy; in_group = (self.current_group == "All") or (self.current_group == "★ Favorites" and is_fav) or (x["group"] == self.current_group); return (not in_group, not is_fav, x["name"].lower())
        full_sorted = sorted(items, key=sort_p, reverse=(self.sort_mode == 1))
        for target_idx, item in enumerate(full_sorted):
            if item["orig_idx"] != target_idx:
                self.send_command({"command": ["playlist-move", item["orig_idx"], target_idx]})
                for other in items:
                    if other["orig_idx"] < item["orig_idx"] and other["orig_idx"] >= target_idx: other["orig_idx"] += 1
                item["orig_idx"] = target_idx
        GLib.idle_add(self._finalize_update, groups, full_sorted, curr_p)
    def _finalize_update(self, groups, full_sorted, curr_p):
        self.list_store.clear(); self.full_list_data, active_iter, self.current_playing_path = full_sorted, None, curr_p
        with self.favorites_lock: fav_copy = set(self.favorites)
        for i in full_sorted:
            is_p, is_f = i["filename"] == curr_p, i["name"] in fav_copy
            status_icon = "⏸ " if (is_p and self.is_paused) else ("▶ " if is_p else "")
            dn = status_icon + (f"★ " if is_f else "") + i['name']
            bg, fg, w = ("#3584e4", "#ffffff", 800) if is_p else (None, "#555555", 400)
            it = self.list_store.append([dn, i["orig_idx"], w, i["group"], fg, bg, i["filename"]])
            if is_p: active_iter = it
        self.rebuild_group_menu(groups); self.filter.refilter()
        if active_iter:
            try:
                f_path = self.filter.convert_child_path_to_path(self.list_store.get_path(active_iter))
                if f_path: self.tree_view.get_selection().select_path(f_path); self.tree_view.scroll_to_cell(f_path, None, True, 0.5, 0.0)
            except: pass
        if not self.resume_done and self.last_file_path:
            for i in full_sorted:
                if i["filename"] == self.last_file_path: self.send_command({"command": ["set_property", "playlist-pos", i["orig_idx"]]}); self.send_command({"command": ["set_property", "pause", True]}); self.resume_done = True; break
        with self.update_lock: self.is_updating = False
    def rebuild_group_menu(self, groups):
        for c in self.group_menu.get_children(): self.group_menu.remove(c)
        with self.favorites_lock: fav_copy = set(self.favorites)
        counts = {"All": len(self.full_list_data), "★ Favorites": sum(1 for x in self.full_list_data if x["name"] in fav_copy)}
        for g in groups: counts[g] = sum(1 for x in self.full_list_data if x["group"] == g)
        for o in ["All", "★ Favorites"] + sorted(list(groups)):
            lbl = f"{o} ({counts.get(o, 0)})"; item = Gtk.MenuItem(label=f"• {lbl}" if o == self.current_group else lbl)
            item.connect("activate", self.on_group_selected, o); self.group_menu.append(item)
        self.group_menu.show_all()
    def on_group_selected(self, mi, name): self.current_group = name; self.save_window_state_now(); self.update_playlist()
    def update_now_playing(self):
        path_res = self.send_command({"command": ["get_property", "path"]})
        pause_res = self.send_command({"command": ["get_property", "pause"]})
        new_path = path_res.get("data", "") if path_res else ""
        new_pause = pause_res.get("data", False) if pause_res else False
        if new_path != self.current_playing_path or new_pause != self.is_paused:
            self.current_playing_path, self.is_paused = new_path, new_pause
            self.update_playlist()
        res = self.send_command({"command": ["get_property", "media-title"]}); self.set_title(str(res.get('data')) if (res and "data" in res) else "MPV")
        return True
    def filter_func(self, model, iter, data):
        dn = model.get_value(iter, 0); name, grp, q = dn.replace("★ ", "").replace("▶ ", "").replace("⏸ ", ""), model.get_value(iter, 3), self.search_entry.get_text().lower()
        if self.current_group == "★ Favorites":
            with self.favorites_lock: return name.strip() in self.favorites and q in name.lower()
        return q in name.lower() if self.current_group == "All" else (grp == self.current_group and q in name.lower())
    def toggle_sort(self, mi): self.sort_mode = 1 - self.sort_mode; self.update_playlist()
    def on_load_clicked(self, mi):
        diag = Gtk.FileChooserDialog(title="Select Playlist", parent=self, action=Gtk.FileChooserAction.OPEN)
        diag.add_buttons("_Cancel", Gtk.ResponseType.CANCEL, "_Open", Gtk.ResponseType.OK)
        if diag.run() == Gtk.ResponseType.OK: self.load_playlist_file(diag.get_filename())
        diag.destroy()
    def on_clear_clicked(self, mi): self.send_command({"command": ["playlist-clear"]}); self.m3u_groups = {}; self.update_playlist()
    def on_click(self, tree, event):
        pi = tree.get_path_at_pos(int(event.x), int(event.y))
        if not pi: return
        if event.button == 1: self.activate_row(pi[0])
        elif event.button == 3:
            f_iter = self.filter.get_iter(pi[0])
            if f_iter:
                n = self.filter.get_value(f_iter, 0).replace("★ ", "").replace("▶ ", "").replace("⏸ ", "").strip()
                with self.favorites_lock:
                    if n in self.favorites: self.favorites.remove(n)
                    else: self.favorites.add(n)
                self.save_favs(); self.update_playlist()
    def on_key_release(self, tree, event):
        if event.keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter, Gdk.KEY_space):
            model, it = tree.get_selection().get_selected()
            if it: self.activate_row(model.get_path(it))
    def activate_row(self, path):
        f_iter = self.filter.get_iter(path)
        if f_iter: self.send_command({"command": ["set_property", "playlist-pos", self.filter.get_value(f_iter, 1)]}); self.send_command({"command": ["set_property", "pause", False]})
    def load_playlist_file(self, path):
        if not path or not os.path.exists(path): return
        self.m3u_groups = {}
        try:
            with open(path, 'r', encoding='utf-8', errors='ignore') as f:
                for line in f:
                    if line.strip().startswith("#EXTINF"):
                        m, nm = re.search(r'group-title="([^"]+)"', line), re.search(r',(.+)$', line)
                        if nm: self.m3u_groups[nm.group(1).strip()] = m.group(1) if m else "Uncategorized"
        except: pass
        self.send_command({"command": ["loadlist", path, "replace"]})
        with self.file_lock:
            with open(self.last_m3u_file, "w", encoding="utf-8") as f: json.dump({"path": path}, f)
        GLib.timeout_add(500, self.update_playlist)
    def load_window_state(self):
        try:
            if os.path.exists(self.config_file):
                with open(self.config_file, "r", encoding="utf-8") as f:
                    c = json.load(f); self.move(c.get("x", 100), c.get("y", 100)); self.resize(c.get("w", 200), c.get("h", 750))
                    self.current_group, self.last_file_path = c.get("current_group", "All"), c.get("last_playing", "")
        except: pass
    def save_window_state_now(self):
        try:
            path_res = self.send_command({"command": ["get_property", "path"]})
            curr = path_res.get("data", "") if path_res else ""
            pos, size = self.get_position(), self.get_size()
            with self.file_lock:
                with open(self.config_file, "w", encoding="utf-8") as f:
                    json.dump({"x": pos[0], "y": pos[1], "w": size[0], "h": size[1], "current_group": self.current_group, "last_playing": curr}, f)
        except: pass
    def on_configure_event(self, w, e): self.save_window_state_now(); return False
    def on_delete_event(self, w, e): self.save_window_state_now(); Gtk.main_quit()
    def on_drag_data_received(self, w, c, x, y, s, i, t):
        uris = s.get_uris()
        if uris: self.load_playlist_file(GLib.filename_from_uri(uris[0])[0] if uris[0].startswith("file://") else uris[0])
        c.finish(True, False, t)
    def auto_load_last_m3u(self):
        if os.path.exists(self.last_m3u_file):
            try:
                with open(self.last_m3u_file, "r", encoding="utf-8") as f:
                    p = json.load(f).get("path")
                    if p: self.load_playlist_file(p)
            except: pass
        return False
    def on_vol_changed(self, scale):
        v = int(scale.get_value()); self.send_command({"command": ["set_property", "volume", v]}); scale.set_tooltip_text(f"{v}%")
    def on_fab_clicked(self, btn):
        if not self.revealer.get_reveal_child():
            res = self.send_command({"command": ["get_property", "volume"]})
            if res and "data" in res: v = res["data"]; self.vol_scale.set_value(v); self.vol_scale.set_tooltip_text(f"{int(v)}%")
        self.revealer.set_reveal_child(not self.revealer.get_reveal_child())
if __name__ == "__main__":
    win = MPVGTKManager(); Gtk.main()
