import sys, socket, json, os, subprocess, re, gi, threading
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GObject, GLib, GdkPixbuf, Gdk

os.environ["QT_ACCESSIBILITY"] = "0"

class MPVGTKManager(Gtk.Window):
    def __init__(self):
        super().__init__(title="MPV Playlist Manager")
        self.socket_path, self.fav_file = "/tmp/mpvsocket", os.path.expanduser("~/.mpv_favorites.json")
        self.last_m3u_file = os.path.expanduser("~/.mpv_last_playlist.json")
        self.config_file = os.path.expanduser("~/.mpv_gtk_config.json")
        self.favorites, self.sort_mode, self.current_playing_idx = self.load_favs(), 0, -1
        self.current_group, self.m3u_groups = "Alle", {}
        self.full_list_data, self.is_updating = [], False
        self.resume_done = False
        self.last_file = ""

        self.apply_css()
        self.ensure_mpv_running()
        self.load_window_state()
        
        self.vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        self.add(self.vbox)
        
        self.drag_dest_set(Gtk.DestDefaults.ALL, [], Gdk.DragAction.COPY)
        self.drag_dest_add_uri_targets()
        self.connect("drag-data-received", self.on_drag_data_received)
        self.connect("delete-event", self.on_delete_event)
        
        self.search_entry = Gtk.SearchEntry(placeholder_text="Suchen...")
        self.search_entry.connect("changed", lambda w: self.filter.refilter())
        self.vbox.pack_start(self.search_entry, False, False, 5)
        
        self.group_combo = Gtk.ComboBoxText()
        self.group_combo.connect("changed", self.on_group_changed)
        self.vbox.pack_start(self.group_combo, False, False, 0)
        
        self.scrolled = Gtk.ScrolledWindow()
        self.vbox.pack_start(self.scrolled, True, True, 0)
        
        self.list_store = Gtk.ListStore(str, int, str, str, str, str, str, str)
        self.filter = self.list_store.filter_new()
        self.filter.set_visible_func(self.filter_func)
        
        self.tree_view = Gtk.TreeView(model=self.filter, headers_visible=False)
        self.tree_view.connect("row-activated", self.on_row_activated)
        self.tree_view.connect("button-press-event", self.on_right_click)
        
        col1 = Gtk.TreeViewColumn("S", Gtk.CellRendererPixbuf(), icon_name=4)
        self.tree_view.append_column(col1)
        
        renderer_text = Gtk.CellRendererText()
        col2 = Gtk.TreeViewColumn("N", renderer_text, text=0, weight=2)
        col2.add_attribute(renderer_text, "foreground", 5)
        col2.add_attribute(renderer_text, "background", 6)
        self.tree_view.append_column(col2)
        
        self.scrolled.add(self.tree_view)
        
        self.bbox = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=2)
        self.vbox.pack_start(self.bbox, False, False, 5)
        
        for label, cb in [("M3U", self.on_load_clicked), ("Leeren", self.on_clear_clicked), ("A-Z", self.toggle_sort), ("Refresh", lambda x: self.update_playlist())]:
            btn = Gtk.Button(label=label)
            btn.connect("clicked", cb)
            self.bbox.pack_start(btn, True, True, 0)
            
        self.show_all()
        GLib.idle_add(self.auto_load_last_m3u)
        GLib.timeout_add(2000, self.update_now_playing)

    def apply_css(self):
        css = b"treeview { background-color: #ffffff; color: #333333; outline: none; } treeview:hover { background-color: #f5f5f5; } treeview:selected { background-color: #3584e4; color: #ffffff; }"
        provider = Gtk.CssProvider()
        provider.load_from_data(css)
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

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
                self.set_default_size(c.get("w", 500), c.get("h", 750))
                self.last_file = c.get("last_file", "")
        except: self.set_default_size(500, 750)

    def on_delete_event(self, w, e):
        x, y = self.get_position()
        w, h = self.get_size()
        path_res = self.send_command({"command": ["get_property", "path"]})
        curr_path = path_res.get("data", "") if path_res else ""
        with open(self.config_file, "w") as f:
            json.dump({"x": x, "y": y, "w": w, "h": h, "last_file": curr_path}, f)
        Gtk.main_quit()

    def send_command(self, cmd):
        client = None
        try:
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(0.5)
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
        if not res or "data" not in res:
            self.is_updating = False
            return
        groups, items = set(), []
        for idx, i in enumerate(res["data"]):
            fname = i.get("filename", "Unknown")
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
        GLib.idle_add(self._finalize_update, groups, full_sorted)

    def _finalize_update(self, groups, full_sorted):
        self.list_store.clear()
        self.full_list_data = full_sorted
        active_iter = None
        for i in full_sorted:
            is_p = i['orig_idx'] == self.current_playing_idx
            dn = f"★ {i['name']}" if i['name'] in self.favorites else i['name']
            bg = "#3584e4" if is_p else None
            fg = "#ffffff" if is_p else "#333333"
            it = self.list_store.append([dn, i["orig_idx"], "800" if is_p else "400", i["group"], "media-playback-start" if is_p else None, fg, bg, i["filename"]])
            if is_p: active_iter = it
            
        self.update_combo(groups)
        self.filter.refilter()
        
        if not self.resume_done and self.last_file:
            for i in full_sorted:
                if i["filename"] == self.last_file:
                    self.send_command({"command": ["set_property", "playlist-pos", i["orig_idx"]]})
                    self.send_command({"command": ["set_property", "pause", True]})
                    self.resume_done = True
                    break

        if active_iter:
            try:
                child_path = self.list_store.get_path(active_iter)
                filter_path = self.filter.convert_child_path_to_path(child_path)
                if filter_path:
                    self.tree_view.get_selection().select_path(filter_path)
                    self.tree_view.scroll_to_cell(filter_path, None, True, 0.5, 0.0)
            except: pass
        self.is_updating = False

    def update_combo(self, groups):
        active = self.group_combo.get_active_text() or self.current_group
        self.group_combo.handler_block_by_func(self.on_group_changed)
        self.group_combo.remove_all()
        opts = ["Alle", "★ Favoriten"] + sorted(list(groups))
        for o in opts: self.group_combo.append_text(o)
        if active in opts: self.group_combo.set_active(opts.index(active))
        else: self.group_combo.set_active(0)
        self.group_combo.handler_unblock_by_func(self.on_group_changed)

    def update_now_playing(self):
        idx = self.send_command({"command": ["get_property", "playlist-pos"]})
        title_res = self.send_command({"command": ["get_property", "media-title"]})
        if title_res and "data" in title_res: self.set_title(title_res["data"])
        if idx and "data" in idx and idx["data"] != self.current_playing_idx:
            self.current_playing_idx = idx["data"]
            self.update_playlist()
        return True

    def filter_func(self, model, iter, data):
        name = model[iter][0].replace("★ ", "")
        grp = model[iter][3]
        q = self.search_entry.get_text().lower()
        if self.current_group == "★ Favoriten":
            if name not in self.favorites: return False
        elif self.current_group != "Alle":
            if grp != self.current_group: return False
        return q in name.lower()

    def on_group_changed(self, combo):
        self.current_group = combo.get_active_text() or "Alle"
        self.update_playlist()

    def toggle_sort(self, w):
        self.sort_mode = 1 - self.sort_mode
        self.update_playlist()

    def on_load_clicked(self, w):
        diag = Gtk.FileChooserDialog(title="M3U", parent=self, action=Gtk.FileChooserAction.OPEN)
        diag.add_buttons(Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL, Gtk.STOCK_OPEN, Gtk.ResponseType.OK)
        if diag.run() == Gtk.ResponseType.OK: self.load_playlist_file(diag.get_filename())
        diag.destroy()

    def on_clear_clicked(self, w):
        self.send_command({"command": ["playlist-clear"]})
        self.m3u_groups = {}
        self.update_playlist()

    def on_drag_data_received(self, w, c, x, y, s, i, t):
        uris = s.get_uris()
        if uris:
            uri = uris[0]
            path = GLib.filename_from_uri(uri)[0] if uri.startswith('file://') else uri
            self.load_playlist_file(path)
        c.finish(True, False, t)

    def on_right_click(self, tree, event):
        if event.button == 3:
            pi = tree.get_path_at_pos(int(event.x), int(event.y))
            if pi:
                name = self.filter[pi[0]][0].replace("★ ", "")
                if name in self.favorites: self.favorites.remove(name)
                else: self.favorites.add(name)
                self.save_favs(); self.update_playlist()

    def on_row_activated(self, tree, path, col):
        self.send_command({"command": ["set_property", "playlist-pos", self.filter[path][1]]})
        self.send_command({"command": ["set_property", "pause", False]})

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
            GLib.timeout_add(500, self.update_playlist)

    def auto_load_last_m3u(self):
        if os.path.exists(self.last_m3u_file):
            try:
                with open(self.last_m3u_file, "r") as f:
                    d = json.load(f); self.sort_mode = d.get("sort_mode", 0)
                    self.load_playlist_file(d.get("path"))
            except: pass
        else: self.update_playlist()

if __name__ == "__main__":
    win = MPVGTKManager()
    Gtk.main()
