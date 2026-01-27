import sys
import socket
import json
import os
import subprocess
import re
import gi
import threading
from pathlib import Path
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GObject, GLib, Gdk
os.environ["QT_ACCESSIBILITY"] = "0"
class MPVGTKManager(Gtk.Window):
    def __init__(self):
        super().__init__()
        self.socket_path = "/tmp/mpvsocket"
        self.fav_file = os.path.expanduser("~/.mpv_favorites.json")
        self.last_m3u_file = os.path.expanduser("~/.mpv_last_playlist.json")
        self.config_file = os.path.expanduser("~/.mpv_gtk_config.json")
        self.favorites = self.load_favs()
        self.favorites_lock = threading.Lock()
        self.file_lock = threading.Lock()
        self.update_lock = threading.Lock()
        self.sort_mode = 0
        self.current_playing_path = ""
        self.last_file_to_resume = ""
        self.resume_done = False
        self.current_group = "All"
        self.m3u_groups = {}
        self.full_list_data = []
        self.is_updating = False
        self.apply_css()
        self.ensure_mpv_running()
        self.set_default_size(200, 750)
        self.set_size_request(100, -1)
        self.load_window_state()
        hb = Gtk.HeaderBar()
        hb.set_show_close_button(True)
        hb.set_decoration_layout("menu:close")
        self.set_titlebar(hb)
        self.search_entry = Gtk.SearchEntry(placeholder_text="Search...")
        self.search_entry.set_width_chars(1)
        self.search_entry.set_hexpand(True)
        self.search_entry.connect("changed", lambda w: self.filter.refilter())
        hb.set_custom_title(self.search_entry)
        self.menu_button = Gtk.MenuButton(label="≡")
        self.main_menu = Gtk.Menu()
        for l, cb in [("Open Playlist", self.on_load_clicked), ("Toggle Sort", self.toggle_sort), ("Refresh", lambda x: self.update_playlist()), ("Clear Playlist", self.on_clear_clicked)]:
            mi = Gtk.MenuItem(label=l)
            mi.connect("activate", cb)
            self.main_menu.append(mi)
        self.main_menu.show_all()
        self.menu_button.set_popup(self.main_menu)
        hb.pack_end(self.menu_button)
        self.group_button = Gtk.MenuButton(label="▾")
        self.group_menu = Gtk.Menu()
        self.group_button.set_popup(self.group_menu)
        hb.pack_end(self.group_button)
        self.vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.add(self.vbox)
        self.scrolled = Gtk.ScrolledWindow()
        self.vbox.pack_start(self.scrolled, True, True, 0)
        self.list_store = Gtk.ListStore(str, int, int, str, str, str, str)
        self.filter = self.list_store.filter_new()
        self.filter.set_visible_func(self.filter_func)
        self.tree_view = Gtk.TreeView(model=self.filter, headers_visible=False)
        self.tree_view.connect("button-release-event", self.on_click)
        self.tree_view.connect("key-release-event", self.on_key_release)
        r_txt = Gtk.CellRendererText()
        r_txt.set_property("xpad", 8)
        r_txt.set_property("ypad", 6)
        r_txt.set_property("ellipsize", 3)
        col = Gtk.TreeViewColumn("Name", r_txt, text=0, weight=2, foreground=4, background=5)
        self.tree_view.append_column(col)
        self.scrolled.add(self.tree_view)
        self.drag_dest_set(Gtk.DestDefaults.ALL, [], Gdk.DragAction.COPY)
        self.drag_dest_add_uri_targets()
        self.connect("drag-data-received", self.on_drag_data_received)
        self.connect("delete-event", self.on_delete_event)
        self.show_all()
        GLib.idle_add(self.auto_load_last_m3u)
        GLib.timeout_add(2000, self.update_now_playing)
    def apply_css(self):
        css = b"""
        headerbar { min-height: 28px; padding: 0px 4px; }
        headerbar button { padding: 0px; min-width: 24px; min-height: 24px; margin: 2px 1px; }
        headerbar entry { min-height: 22px; margin: 2px 0px; padding: 0px 6px; }
        treeview { border-radius: 4px; }
        treeview selection { border-radius: 6px; }
        scrollbar trough { background-color: @theme_base_color; border: none; }
        """
        p = Gtk.CssProvider()
        p.load_from_data(css)
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), p, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
    def ensure_mpv_running(self):
        try:
            if os.path.exists(self.socket_path):
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(0.2)
                s.connect(self.socket_path)
                s.close()
            else:
                raise FileNotFoundError
        except:
            subprocess.Popen(["mpv", "--idle", f"--input-ipc-server={self.socket_path}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    def load_favs(self):
        try:
            if os.path.exists(self.fav_file):
                with open(self.fav_file, "r", encoding="utf-8") as f:
                    return set(json.load(f))
        except: pass
        return set()
    def save_favs(self):
        try:
            with self.file_lock:
                Path(os.path.dirname(self.fav_file) or ".").mkdir(parents=True, exist_ok=True)
                with open(self.fav_file, "w", encoding="utf-8") as f:
                    json.dump(list(self.favorites), f)
        except: pass
    def send_command(self, cmd, timeout=1.0):
        c = None
        try:
            c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            c.settimeout(timeout)
            c.connect(self.socket_path)
            c.sendall(json.dumps(cmd).encode() + b"\n")
            res = b""
            while True:
                chunk = c.recv(4096)
                if not chunk: break
                res += chunk
                if res.endswith(b"\n"): break
            return json.loads(res.decode(errors="ignore")) if res else None
        except: return None
        finally:
            if c: c.close()
    def update_playlist(self):
        with self.update_lock:
            if self.is_updating: return
            self.is_updating = True
        threading.Thread(target=self._update_thread, daemon=True).start()
    def _update_thread(self):
        res = self.send_command({"command": ["get_property", "playlist"]})
        path_res = self.send_command({"command": ["get_property", "path"]})
        curr_p = path_res.get("data", "") if path_res else ""
        if not res or "data" not in res:
            with self.update_lock: self.is_updating = False
            return
        groups, items = set(), []
        with self.favorites_lock: fav_copy = set(self.favorites)
        for idx, i in enumerate(res["data"]):
            fn = i.get("filename", "")
            name = i.get("title") or os.path.basename(fn)
            grp = self.m3u_groups.get(name, "Uncategorized")
            groups.add(grp)
            items.append({"name": name, "filename": fn, "orig_idx": idx, "group": grp})
        def sort_p(x):
            is_fav = x["name"] in fav_copy
            in_group = (self.current_group == "All") or (self.current_group == "★ Favorites" and is_fav) or (x["group"] == self.current_group)
            return (not in_group, not is_fav, x["name"].lower())
        full_sorted = sorted(items, key=sort_p, reverse=(self.sort_mode == 1))
        for target_idx, item in enumerate(full_sorted):
            if item["orig_idx"] != target_idx:
                self.send_command({"command": ["playlist-move", item["orig_idx"], target_idx]})
                for other in items:
                    if other["orig_idx"] < item["orig_idx"] and other["orig_idx"] >= target_idx:
                        other["orig_idx"] += 1
                item["orig_idx"] = target_idx
        GLib.idle_add(self._finalize_update, groups, full_sorted, curr_p)
    def _finalize_update(self, groups, full_sorted, curr_p):
        self.list_store.clear()
        self.full_list_data = full_sorted
        active_iter = None
        self.current_playing_path = curr_p
        with self.favorites_lock: fav_copy = set(self.favorites)
        for i in full_sorted:
            is_p = i["filename"] == curr_p
            is_f = i["name"] in fav_copy
            dn = f"★ {i['name']}" if is_f else i['name']
            if is_p: dn = f"▶ {dn}"
            bg, fg, w = ("#3584e4", "#ffffff", 800) if is_p else (None, "#555555", 400)
            it = self.list_store.append([dn, i["orig_idx"], w, i["group"], fg, bg, i["filename"]])
            if is_p: active_iter = it
        self.rebuild_group_menu(groups)
        self.filter.refilter()
        if active_iter:
            f_path = self.filter.convert_child_path_to_path(self.list_store.get_path(active_iter))
            if f_path:
                self.tree_view.get_selection().select_path(f_path)
                self.tree_view.scroll_to_cell(f_path, None, True, 0.5, 0.0)
        if not self.resume_done and self.last_file_to_resume:
            for i in full_sorted:
                if i["filename"] == self.last_file_to_resume:
                    self.send_command({"command": ["set_property", "playlist-pos", i["orig_idx"]]})
                    self.send_command({"command": ["set_property", "pause", True]})
                    self.resume_done = True
                    break
        with self.update_lock: self.is_updating = False
    def rebuild_group_menu(self, groups):
        for c in self.group_menu.get_children(): self.group_menu.remove(c)
        with self.favorites_lock: fav_copy = set(self.favorites)
        counts = {"All": len(self.full_list_data), "★ Favorites": sum(1 for x in self.full_list_data if x["name"] in fav_copy)}
        for g in groups: counts[g] = sum(1 for x in self.full_list_data if x["group"] == g)
        for o in ["All", "★ Favorites"] + sorted(list(groups)):
            lbl = f"{o} ({counts.get(o, 0)})"
            if o == self.current_group: lbl = f"• {lbl}"
            item = Gtk.MenuItem(label=lbl)
            item.connect("activate", self.on_group_selected, o)
            self.group_menu.append(item)
        self.group_menu.show_all()
    def on_group_selected(self, mi, name):
        self.current_group = name
        self.save_window_state_now()
        self.update_playlist()
    def update_now_playing(self):
        path_res = self.send_command({"command": ["get_property", "path"]})
        if path_res and "data" in path_res:
            if path_res["data"] != self.current_playing_path: self.update_playlist()
        res = self.send_command({"command": ["get_property", "media-title"]})
        self.set_title(str(res.get('data')) if (res and "data" in res) else "MPV")
        return True
    def filter_func(self, model, iter, data):
        dn = model.get_value(iter, 0)
        name = dn.replace("★ ", "").replace("▶ ", "")
        grp = model.get_value(iter, 3)
        q = self.search_entry.get_text().lower()
        if self.current_group == "★ Favorites":
            with self.favorites_lock:
                if name not in self.favorites: return False
        elif self.current_group != "All" and grp != self.current_group: return False
        return q in name.lower()
    def toggle_sort(self, mi):
        self.sort_mode = 1 - self.sort_mode
        self.update_playlist()
    def on_load_clicked(self, mi):
        diag = Gtk.FileChooserDialog(title="Playlist", parent=self, action=Gtk.FileChooserAction.OPEN)
        diag.add_buttons("_Cancel", Gtk.ResponseType.CANCEL, "_Open", Gtk.ResponseType.OK)
        if diag.run() == Gtk.ResponseType.OK: self.load_playlist_file(diag.get_filename())
        diag.destroy()
    def on_clear_clicked(self, mi):
        self.send_command({"command": ["playlist-clear"]})
        self.m3u_groups = {}
        self.update_playlist()
    def on_click(self, tree, event):
        if event.button == 1:
            pi = tree.get_path_at_pos(int(event.x), int(event.y))
            if pi: self.activate_row(pi[0])
        elif event.button == 3:
            pi = tree.get_path_at_pos(int(event.x), int(event.y))
            if pi:
                f_iter = self.filter.get_iter(pi[0])
                if f_iter:
                    dn = self.filter.get_value(f_iter, 0)
                    n = dn.replace("★ ", "").replace("▶ ", "").strip()
                    with self.favorites_lock:
                        if n in self.favorites: self.favorites.remove(n)
                        else: self.favorites.add(n)
                    self.save_favs()
                    self.update_playlist()
    def on_key_release(self, tree, event):
        if event.keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter, Gdk.KEY_space):
            model, iter = tree.get_selection().get_selected()
            if iter: self.activate_row(model.get_path(iter))
    def activate_row(self, path):
        f_iter = self.filter.get_iter(path)
        if f_iter:
            self.send_command({"command": ["set_property", "playlist-pos", self.filter.get_value(f_iter, 1)]})
            self.send_command({"command": ["set_property", "pause", False]})
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
        except: pass
        self.send_command({"command": ["loadlist", path, "replace"]})
        with self.file_lock:
            with open(self.last_m3u_file, "w", encoding="utf-8") as f: json.dump({"path": path}, f)
        GLib.timeout_add(500, self.update_playlist)
    def load_window_state(self):
        try:
            if os.path.exists(self.config_file):
                with open(self.config_file, "r", encoding="utf-8") as f:
                    c = json.load(f)
                    self.move(c.get("x", 100), c.get("y", 100))
                    self.resize(c.get("w", 150), c.get("h", 750))
                    self.last_file_to_resume = c.get("last_file", "")
                    self.current_group = c.get("current_group", "All")
        except: pass
    def save_window_state_now(self):
        try:
            path_res = self.send_command({"command": ["get_property", "path"]})
            curr_p = path_res.get("data", "") if path_res else ""
            with self.file_lock:
                with open(self.config_file, "w", encoding="utf-8") as f:
                    json.dump({"x": self.get_position()[0], "y": self.get_position()[1], "w": self.get_size()[0], "h": self.get_size()[1], "last_file": curr_p, "current_group": self.current_group}, f)
        except: pass
    def on_delete_event(self, w, e):
        self.save_window_state_now()
        Gtk.main_quit()
    def on_drag_data_received(self, w, c, x, y, s, i, t):
        uris = s.get_uris()
        if uris: self.load_playlist_file(GLib.filename_from_uri(uris[0])[0] if uris[0].startswith("file://") else uris[0])
        c.finish(True, False, t)
    def auto_load_last_m3u(self):
        if os.path.exists(self.last_m3u_file):
            try:
                with open(self.last_m3u_file, "r", encoding="utf-8") as f:
                    p = json.load(f).get("path")
                    if p:
                        self.load_playlist_file(p)
                        return False
            except: pass
        self.update_playlist()
        return False
if __name__ == "__main__":
    win = MPVGTKManager()
    Gtk.main()
