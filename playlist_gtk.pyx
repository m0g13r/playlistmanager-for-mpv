# cython: language_level=3, boundscheck=False, wraparound=False, cdivision=True
import sys,socket,json,os,subprocess,re,gi,threading,glob,urllib.request,tempfile,select,io,calendar
import time as time_mod
import xml.etree.ElementTree as ET
from datetime import datetime as _datetime
gi.require_version('Gtk','3.0')
from gi.repository import Gtk,GLib,Gdk,GdkPixbuf,Pango,PangoCairo,GObject
import cairo,math
os.environ["QT_ACCESSIBILITY"]="0"

cdef class PlaylistItem:
    cdef public str name
    cdef public str filename
    cdef public int orig_idx
    cdef public str group
    cdef public list nkey
    cdef public list nkey_rev
    def __init__(self,str name,str filename,int orig_idx,str group,list nkey):
        self.name=name
        self.filename=filename
        self.orig_idx=orig_idx
        self.group=group
        self.nkey=nkey
        self.nkey_rev=[(-rank,-val if isinstance(val,int) else ''.join(chr(0x10FFFF-ord(c)) for c in val)) for rank,val in nkey]

# ── helpers ───────────────────────────────────────────────────────────────────
def _rounded_rect(ctx,x,y,w,h,r):
    """Draw a rounded-rectangle path (no fill/stroke – caller decides)."""
    r=min(r,w/2,h/2)
    ctx.arc(x+r,   y+r,   r, math.pi,       3*math.pi/2)
    ctx.arc(x+w-r, y+r,   r, 3*math.pi/2,   0)
    ctx.arc(x+w-r, y+h-r, r, 0,              math.pi/2)
    ctx.arc(x+r,   y+h-r, r, math.pi/2,     math.pi)
    ctx.close_path()

# ── Custom cell renderer ──────────────────────────────────────────────────────
class EPGCellRenderer(Gtk.CellRenderer):
    """
    Renders a list row with:
      • channel name  (top, bold when playing)
      • EPG subtitle + remaining time  (middle, small – only when EPG present)
      • progress bar  (bottom – only when EPG present)
    """
    __gtype_name__ = 'EPGCellRenderer'

    # Properties bound to ListStore columns via add_attribute()
    display_text  = GObject.Property(type=str,   default='')
    weight        = GObject.Property(type=int,   default=400)
    fg_color      = GObject.Property(type=str,   default='')
    bg_color      = GObject.Property(type=str,   default='')
    epg_title     = GObject.Property(type=str,   default='')
    epg_progress  = GObject.Property(type=float, default=-1.0)
    epg_remaining = GObject.Property(type=int,   default=0)

    _H_NORMAL = 38
    _H_EPG    = 62
    _PAD_X    = 10
    _PAD_Y    = 6
    _RADIUS   = 8
    _PB_H     = 5
    _PB_R     = 2.5

    def __init__(self):
        super().__init__()
        self._font_normal = Pango.FontDescription('Sans 10')
        self._font_bold = Pango.FontDescription('Sans Bold 10')
        self._font_small = Pango.FontDescription('Sans 8')
        self._layout = None

    @property
    def _has_epg(self):
        return self.epg_progress >= 0.0

    # Gtk.CellRenderer virtual methods ────────────────────────────────────────
    def do_get_preferred_height(self, widget):
        h = self._H_EPG if self._has_epg else self._H_NORMAL
        return h, h

    def do_get_preferred_width(self, widget):
        return 60, 400

    def do_get_preferred_height_for_width(self, widget, width):
        h = self._H_EPG if self._has_epg else self._H_NORMAL
        return h, h

    def do_render(self, ctx, widget, background_area, cell_area, flags):
        selected = bool(flags & Gtk.CellRendererState.SELECTED)
        is_playing = bool(self.bg_color)

        ca = cell_area
        # inner rect with a small gap on all sides for the rounded card look
        rx = ca.x + 2
        ry = ca.y + 2
        rw = ca.width - 4
        rh = ca.height - 4

        # ── colours ──────────────────────────────────────────────────────
        if is_playing:
            # solid blue card
            ctx.save()
            ctx.set_source_rgba(0.208, 0.518, 0.894, 1.0)
            _rounded_rect(ctx, rx, ry, rw, rh, self._RADIUS)
            ctx.fill()
            ctx.restore()
            text_rgb  = (1.0, 1.0, 1.0)
            epg_rgb   = (0.72, 0.86, 1.0)
            rem_rgb   = (0.56, 0.76, 1.0)
            pb_bg     = (0.30, 0.60, 0.95)
            pb_fill   = (1.0, 1.0, 1.0)
        elif selected:
            # let the theme draw the row background; we only adjust text colours
            text_rgb  = (1.0, 1.0, 1.0)
            epg_rgb   = (0.82, 0.91, 1.0)
            rem_rgb   = (0.70, 0.84, 1.0)
            pb_bg     = (0.40, 0.65, 0.95)
            pb_fill   = (1.0, 1.0, 1.0)
        else:
            text_rgb  = (0.20, 0.20, 0.20)
            epg_rgb   = (0.53, 0.53, 0.53)
            rem_rgb   = (0.67, 0.67, 0.67)
            pb_bg     = (0.88, 0.88, 0.88)
            pb_fill   = (0.208, 0.518, 0.894)

        tx = rx + self._PAD_X
        ty = ry + self._PAD_Y
        tw = rw - 2 * self._PAD_X

        # ── channel name ─────────────────────────────────────────────────
        desc = self._font_bold if self.weight > 500 else self._font_normal
        ctx.save()
        ctx.set_source_rgb(*text_rgb)
        if self._layout is None:
            self._layout = PangoCairo.create_layout(ctx)
        else:
            PangoCairo.update_layout(ctx, self._layout)
        
        self._layout.set_text(self.display_text, -1)
        self._layout.set_width(tw * Pango.SCALE)
        self._layout.set_ellipsize(Pango.EllipsizeMode.END)
        self._layout.set_font_description(desc)
        ctx.move_to(tx, ty)
        PangoCairo.show_layout(ctx, self._layout)
        ctx.restore()

        if self._has_epg and self.epg_title:
            name_h = self._layout.get_pixel_size()[1]
            ey = ty + max(name_h, 20) + 2

            # ── EPG subtitle + remaining time ─────────────────────────────
            # remaining-time string (right-aligned)
            mins = self.epg_remaining // 60
            rem_str = f"+{mins}m" if mins > 0 else ""
            rem_w = 0
            if rem_str:
                ctx.save()
                ctx.set_source_rgb(*rem_rgb)
                self._layout.set_text(rem_str, -1)
                self._layout.set_font_description(self._font_small)
                self._layout.set_width(-1) # reset width for measurement
                rem_w, _ = self._layout.get_pixel_size()
                ctx.move_to(tx + tw - rem_w, ey)
                PangoCairo.show_layout(ctx, self._layout)
                ctx.restore()

            # EPG title (truncated so it doesn't overlap the time)
            ctx.save()
            ctx.set_source_rgb(*epg_rgb)
            self._layout.set_text(self.epg_title, -1)
            avail = tw - rem_w - (8 if rem_w else 0)
            self._layout.set_width(max(1, avail) * Pango.SCALE)
            self._layout.set_ellipsize(Pango.EllipsizeMode.END)
            self._layout.set_font_description(self._font_small)
            ctx.move_to(tx, ey)
            PangoCairo.show_layout(ctx, self._layout)
            ctx.restore()

            # ── progress bar ──────────────────────────────────────────────
            pby = ry + rh - self._PAD_Y - self._PB_H + 1
            pbx = tx
            pbw = tw

            # background track
            ctx.save()
            ctx.set_source_rgb(*pb_bg)
            _rounded_rect(ctx, pbx, pby, pbw, self._PB_H, self._PB_R)
            ctx.fill()

            # filled portion
            fill_w = max(0.0, min(float(pbw) * self.epg_progress, float(pbw)))
            if fill_w >= 1.0:
                ctx.set_source_rgb(*pb_fill)
                _rounded_rect(ctx, pbx, pby, fill_w, self._PB_H, self._PB_R)
                ctx.fill()
            ctx.restore()


# ── Main window ───────────────────────────────────────────────────────────────
class MPVGTKManager(Gtk.Window):
    # ListStore column indices
    # 0  display_text  str
    # 1  orig_idx      int
    # 2  weight        int   (Pango weight)
    # 3  group         str
    # 4  fg            str
    # 5  bg            str
    # 6  filename      str
    # 7  name          str
    # 8  name_lower    str
    # 9  epg_title     str
    # 10 epg_progress  float  (-1.0 = no EPG)
    # 11 epg_remaining int    (seconds)

    def __init__(self):
        super().__init__()
        self.socket_path="/dev/shm/mpvsocket"
        self.config_file=os.path.expanduser("~/.mpv_gtk_config.json")
        self.favorites,self.m3u_groups,self.url_to_group,self.full_list_data,self.m3u_logos=set(),{},{},[],{}
        self.logo_cache={}
        self._logo_hover_active=False
        self._current_hover_url=None
        self._last_hover_path=None
        self._logo_timer_id=None
        self._playlist_needs_sort=True
        self._logo_sem=threading.Semaphore(4)
        self.url_to_name={}
        self.url_to_tvgid={}
        self.epg_data={}
        self.epg_path=""
        self.file_lock,self.update_lock,self.favorites_lock,self.logo_lock=threading.Lock(),threading.Lock(),threading.Lock(),threading.Lock()
        self.sort_mode,self.current_playing_path,self.current_group,self.is_updating,self.resume_done,self.last_file_path,self.is_paused=0,"","All",False,False,"",False
        self.last_playlist_path=""
        self.show_fab_enabled=True
        self.show_logos_enabled=True
        self._url_to_iter={}
        self._last_playing_path=""
        self._last_pause_state=False
        self.is_probing_sockets=False
        self.available_sockets=[]
        self._save_pending=False
        self.last_mpv_cnt=0
        self._nkey_cache={}
        self._norm_cache={}
        self._re_nonword=re.compile(r'\W+')
        self._re_digit=re.compile(r'(\d+)')
        self._re_m3u_group=re.compile(r'group-title="([^"]+)"')
        self._re_m3u_logo=re.compile(r'tvg-logo="([^"]+)"')
        self._re_m3u_name=re.compile(r',(.+)$')
        self._re_m3u_tvgname=re.compile(r'tvg-name="([^"]+)"')
        self._re_m3u_tvgid=re.compile(r'tvg-id="([^"]+)"')
        # Logo popup ───────────────────────────────────────────────────────────
        self.logo_popup=Gtk.Window(type=Gtk.WindowType.POPUP)
        self.logo_popup.set_decorated(False)
        self.logo_popup.set_skip_taskbar_hint(True)
        self.logo_popup.set_skip_pager_hint(True)
        rgba_visual=self.get_screen().get_rgba_visual()
        if rgba_visual is not None:
            self.logo_popup.set_visual(rgba_visual)
        self.logo_popup.set_app_paintable(True)
        self.logo_popup.connect("draw",self._on_logo_popup_draw)
        self.logo_image=Gtk.Image()
        self.logo_popup.add(self.logo_image)
        self.apply_css()
        self.ensure_mpv_running()
        self.set_default_size(200,750)
        self.set_size_request(50,-1)
        self.load_all_data()
        # Header bar ──────────────────────────────────────────────────────────
        hb=Gtk.HeaderBar(show_close_button=True,decoration_layout="menu:close")
        hb.get_style_context().add_class("compact-header")
        self.set_titlebar(hb)
        self.search_entry=Gtk.SearchEntry(placeholder_text="Search...",hexpand=True,width_chars=1)
        self.current_search_query=""
        def on_search_changed(w):
            self.current_search_query=self.search_entry.get_text().lower()
            self.filter.refilter()
        self.search_entry.connect("changed",on_search_changed)
        hb.set_custom_title(self.search_entry)
        self.menu_button,self.group_button=Gtk.MenuButton(label="≡"),Gtk.MenuButton(label="▾")
        self.main_menu,self.group_menu=Gtk.Menu(),Gtk.Menu()
        self.socket_submenu=Gtk.Menu()
        self.socket_root_item=Gtk.MenuItem(label="Select Player")
        self.socket_root_item.set_submenu(self.socket_submenu)
        self.rebuild_main_menu()
        self.menu_button.set_popup(self.main_menu)
        self.group_button.set_popup(self.group_menu)
        hb.pack_end(self.menu_button)
        hb.pack_end(self.group_button)
        # Content area ────────────────────────────────────────────────────────
        self.overlay=Gtk.Overlay()
        self.add(self.overlay)
        self.scrolled=Gtk.ScrolledWindow()
        self.overlay.add(self.scrolled)
        # ListStore: 12 columns (9–11 are EPG)
        self.list_store=Gtk.ListStore(str,int,int,str,str,str,str,str,str,str,float,int)
        self.filter_cached_favs=set()
        self.filter=self.list_store.filter_new()
        self.filter.set_visible_func(self.filter_func)
        self.tree_view=Gtk.TreeView(model=self.filter,headers_visible=False)
        self.tree_view.set_enable_search(False)
        self.tree_view.set_events(Gdk.EventMask.POINTER_MOTION_MASK|Gdk.EventMask.LEAVE_NOTIFY_MASK)
        self.tree_view.connect("button-release-event",self.on_click)
        self.tree_view.connect("key-press-event",self.on_key_press)
        self.tree_view.connect("motion-notify-event",self.on_mouse_motion)
        self.tree_view.connect("leave-notify-event",self._on_leave_hide_logo)
        self.connect("leave-notify-event",self._on_leave_hide_logo)
        # EPG cell renderer ────────────────────────────────────────────────────
        self.epg_renderer=EPGCellRenderer()
        col=Gtk.TreeViewColumn("Name")
        col.pack_start(self.epg_renderer,True)
        col.add_attribute(self.epg_renderer,'display_text',0)
        col.add_attribute(self.epg_renderer,'weight',2)
        col.add_attribute(self.epg_renderer,'fg_color',4)
        col.add_attribute(self.epg_renderer,'bg_color',5)
        col.add_attribute(self.epg_renderer,'epg_title',9)
        col.add_attribute(self.epg_renderer,'epg_progress',10)
        col.add_attribute(self.epg_renderer,'epg_remaining',11)
        self.tree_view.append_column(col)
        self.scrolled.add(self.tree_view)
        # FAB ─────────────────────────────────────────────────────────────────
        self.fab_container=Gtk.Box(orientation=Gtk.Orientation.VERTICAL,spacing=6,halign=Gtk.Align.END,valign=Gtk.Align.END,margin_bottom=25,margin_right=25)
        self.revealer=Gtk.Revealer(transition_type=Gtk.RevealerTransitionType.SLIDE_UP)
        sub_box=Gtk.Box(orientation=Gtk.Orientation.VERTICAL,spacing=6)
        adj=Gtk.Adjustment(value=100,lower=0,upper=130,step_increment=1,page_increment=5,page_size=0)
        self.vol_scale=Gtk.Scale(orientation=Gtk.Orientation.VERTICAL,adjustment=adj,inverted=True,draw_value=False)
        self.vol_scale.set_size_request(28,120)
        self.vol_scale.get_style_context().add_class("fab-vol-slider")
        self.vol_scale.connect("value-changed",self.on_vol_changed)
        sub_box.pack_start(self.vol_scale,False,False,0)
        for icon,cmd in [("media-playlist-shuffle-symbolic",["playlist-shuffle"]),("media-skip-forward-symbolic",["playlist-next"]),("media-playback-start-symbolic",["cycle","pause"]),("media-skip-backward-symbolic",["playlist-prev"])]:
            btn=Gtk.Button.new_from_icon_name(icon,Gtk.IconSize.MENU)
            btn.get_style_context().add_class("fab-button")
            if icon=="media-playlist-shuffle-symbolic":
                btn.get_style_context().add_class("fab-shuffle")
                def on_shuf(w):
                    self.sort_mode=2
                    self.send_command({"command":["playlist-shuffle"]})
                    self.revealer.set_reveal_child(False)
                    self.save_all_data()
                    self.update_playlist()
                btn.connect("clicked",on_shuf)
            else:
                btn.get_style_context().add_class("fab-small")
                btn.connect("clicked",lambda w,c=cmd:(self.send_command({"command":c}),self.revealer.set_reveal_child(False)))
            sub_box.pack_start(btn,False,False,0)
        self.revealer.add(sub_box)
        self.fab_container.pack_start(self.revealer,False,False,0)
        self.main_fab=Gtk.Button.new_from_icon_name("view-more-horizontal-symbolic",Gtk.IconSize.MENU)
        for c in ["fab-button","fab-trigger"]:self.main_fab.get_style_context().add_class(c)
        self.main_fab.connect("clicked",self.on_fab_clicked)
        self.fab_container.pack_start(self.main_fab,False,False,0)
        self.overlay.add_overlay(self.fab_container)
        self.fab_container.set_visible(self.show_fab_enabled)
        # Drag & drop ─────────────────────────────────────────────────────────
        self.drag_dest_set(Gtk.DestDefaults.ALL,[],Gdk.DragAction.COPY)
        self.drag_dest_add_uri_targets()
        self.connect("drag-data-received",self.on_drag_data_received)
        self.connect("delete-event",self.on_delete_event)
        self.connect("configure-event",self.on_configure_event)
        self.show_all()
        GLib.idle_add(self.auto_load_last_m3u)
        GLib.timeout_add(1000,self.update_now_playing)
        GLib.timeout_add(5000,self.refresh_sockets)
        # EPG refresh every 30 s ───────────────────────────────────────────────
        GLib.timeout_add(30000,self._update_epg_display)

    # ── helpers ───────────────────────────────────────────────────────────────
    def _normalize(self,s):
        if s is None:return ""
        if s in self._norm_cache:return self._norm_cache[s]
        res=self._re_nonword.sub('',s).lower()
        self._norm_cache[s]=res
        return res
    def _get_nkey(self,s):
        if s in self._nkey_cache:return self._nkey_cache[s]
        parts=self._re_digit.split(s)
        res=[]
        for t in parts:
            if not t:continue
            if t.isdigit():res.append((1,int(t)))
            else:res.append((0,t.lower()))
        self._nkey_cache[s]=res
        return res

    # ── EPG ──────────────────────────────────────────────────────────────────
    def _parse_epg_time(self,s):
        """Parse XMLTV timestamp (YYYYMMDDHHmmss ±HHMM) → UTC float."""
        try:
            s=s.strip()
            if ' ' in s:dt_str,tz_str=s.split(' ',1)
            elif len(s)>14:dt_str=s[:14];tz_str=s[14:].strip()
            else:dt_str=s;tz_str='+0000'
            sign=1 if (not tz_str or tz_str[0]!='-') else -1
            tz_h=int(tz_str[1:3]) if len(tz_str)>=3 else 0
            tz_m=int(tz_str[3:5]) if len(tz_str)>=5 else 0
            tz_off=sign*(tz_h*3600+tz_m*60)
            dt=_datetime(int(dt_str[0:4]),int(dt_str[4:6]),int(dt_str[6:8]),
                         int(dt_str[8:10]),int(dt_str[10:12]),int(dt_str[12:14]))
            return float(calendar.timegm(dt.timetuple())-tz_off)
        except:return 0.0

    def get_current_programme(self,tvg_id):
        """Return (title, progress 0-1, remaining_seconds) or (None, 0.0, 0)."""
        now=time_mod.time()
        progs=self.epg_data.get(tvg_id)
        if not progs:return None,0.0,0
        lo,hi=0,len(progs)-1
        idx=-1
        while lo<=hi:
            mid=(lo+hi)//2
            if progs[mid][0]<=now:idx=mid;lo=mid+1
            else:hi=mid-1
        if idx>=0:
            start,stop,title=progs[idx]
            if now<stop:
                dur=stop-start
                prog=float((now-start)/dur) if dur>0 else 0.0
                return title,min(1.0,max(0.0,prog)),int(stop-now)
        return None,0.0,0

    def load_epg_file(self,path):
        """Load EPG XML (file path or HTTP URL) in a background thread."""
        threading.Thread(target=self._load_epg_bg,args=(path,),daemon=True).start()

    def _load_epg_bg(self,path):
        try:
            now=time_mod.time()
            cutoff_old=now-4*3600
            cutoff_new=now+48*3600
            if path.startswith(('http://','https://')):
                req=urllib.request.Request(path,headers={'User-Agent':'Mozilla/5.0'})
                data=urllib.request.urlopen(req,timeout=30).read()
                src=io.BytesIO(data)
            else:
                src=path
            epg={}
            for event,elem in ET.iterparse(src,events=('end',)):
                if elem.tag=='programme':
                    ch=elem.get('channel','')
                    start=self._parse_epg_time(elem.get('start',''))
                    stop=self._parse_epg_time(elem.get('stop',''))
                    if start and stop and start<cutoff_new and stop>cutoff_old:
                        tel=elem.find('title')
                        title=(tel.text or '') if tel is not None else ''
                        if ch not in epg:epg[ch]=[]
                        epg[ch].append((start,stop,title))
                    elem.clear()
            for ch in epg:epg[ch].sort(key=lambda x:x[0])
            self.epg_data=epg
            self.epg_path=path
            self.save_all_data()
            GLib.idle_add(self._update_epg_display)
        except Exception:pass

    def _update_epg_display(self):
        """Refresh EPG columns in the ListStore without rebuilding the whole list."""
        if not self.epg_data: return True
        cdef str fn, tvg_id, title
        cdef float prog
        cdef int rem
        # Only update if the window is actually visible to save CPU
        if not self.get_visible(): return True
        
        # We still need to iterate, but let's make it as lean as possible
        # For very large lists, this is still O(N). 
        # A better way would be to only update visible rows, but ListStore doesn't easily support that.
        for row in self.list_store:
            fn = row[6]
            tvg_id = self.url_to_tvgid.get(fn)
            if tvg_id:
                title, prog, rem = self.get_current_programme(tvg_id)
                if title:
                    if row[9] != title: row[9] = title
                    if abs(row[10] - prog) > 0.01: row[10] = prog
                    if row[11] != rem: row[11] = rem
                elif row[9]:
                    row[9] = ''; row[10] = -1.0; row[11] = 0
        return True

    def on_load_epg_clicked(self,mi):
        """Show file-chooser or URL dialog for the EPG XML."""
        diag=Gtk.FileChooserDialog(title="EPG XML",parent=self,action=Gtk.FileChooserAction.OPEN)
        diag.add_buttons("_Cancel",Gtk.ResponseType.CANCEL,"_Open",Gtk.ResponseType.OK)
        ff=Gtk.FileFilter(); ff.set_name("XML / GZ"); ff.add_pattern("*.xml"); ff.add_pattern("*.gz")
        diag.add_filter(ff)
        resp=diag.run()
        path=diag.get_filename() if resp==Gtk.ResponseType.OK else None
        diag.destroy()
        if path:
            self.load_epg_file(path)
            return
        # Fallback: URL entry
        url_diag=Gtk.Dialog(title="Load EPG URL",parent=self,flags=0)
        url_diag.add_buttons("_Cancel",Gtk.ResponseType.CANCEL,"_OK",Gtk.ResponseType.OK)
        url_diag.set_default_response(Gtk.ResponseType.OK)
        entry=Gtk.Entry(); entry.set_activates_default(True)
        entry.set_placeholder_text("https://…/epg.xml")
        url_diag.get_content_area().add(entry)
        url_diag.show_all()
        if url_diag.run()==Gtk.ResponseType.OK:
            url=entry.get_text().strip()
            if url:self.load_epg_file(url)
        url_diag.destroy()

    # ── Logo popup ────────────────────────────────────────────────────────────
    def _on_logo_popup_draw(self,widget,ctx):
        ctx.set_operator(cairo.OPERATOR_SOURCE)
        ctx.set_source_rgba(0,0,0,0)
        ctx.paint()
        return False

    def _on_leave_hide_logo(self,widget,event):
        if event.detail in (Gdk.NotifyType.INFERIOR,Gdk.NotifyType.VIRTUAL,Gdk.NotifyType.NONLINEAR_VIRTUAL):
            return False
        self._logo_hover_active=False
        self._current_hover_url=None
        self._last_hover_path=None
        if self._logo_timer_id:
            GLib.source_remove(self._logo_timer_id)
            self._logo_timer_id=None
        self.logo_popup.hide()
        return False

    def apply_css(self):
        css=b".compact-header{min-height:24px;padding:0;}.compact-header button{padding:1px 2px;min-height:20px;min-width:20px;}.compact-header entry{min-height:20px;margin:2px 0;}.fab-button{border-radius:50%;border:none;padding:0;transition:all 150ms ease;box-shadow:none;}.fab-trigger{min-width:32px;min-height:32px;background:rgba(53,132,228,0.7);color:white;}.fab-trigger:hover{background:rgba(53,132,228,0.9);}.fab-small{min-width:28px;min-height:28px;background:rgba(60,60,60,0.6);color:white;}.fab-small:hover{background:rgba(80,80,80,0.8);}.fab-shuffle{min-width:28px;min-height:28px;background:rgba(60,60,60,0.6);color:#444444;}.fab-shuffle:hover{background:rgba(80,80,80,0.8);}.fab-vol-slider{background:rgba(60,60,60,0.6);border-radius:14px;padding:12px 0;}scale.fab-vol-slider contents trough{background:rgba(255,255,255,0.2);min-width:4px;border-radius:2px;margin:0 12px;}scale.fab-vol-slider contents trough highlight{background:#3584e4;border-radius:2px;}scale.fab-vol-slider contents trough slider{background:#3584e4;min-width:12px;min-height:12px;border-radius:50%;margin:-4px;border:none;box-shadow:none;}treeview{background-color:transparent;}treeview selection{border-radius:8px;}treeview:selected{border-radius:8px;background-color:#3584e4;color:white;}"
        p=Gtk.CssProvider()
        p.load_from_data(css)
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(),p,Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    def ensure_mpv_running(self):
        if not os.path.exists(self.socket_path):subprocess.Popen(["mpv","--idle",f"--input-ipc-server={self.socket_path}"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)

    def rebuild_main_menu(self):
        for c in self.main_menu.get_children():self.main_menu.remove(c)
        sort_labels={0:"Sort: A-Z",1:"Sort: Z-A"}
        current_sort_label=sort_labels.get(self.sort_mode,"Sort: A-Z")
        for l,cb in [("Open Playlist",self.on_load_clicked),("Load URL",self.on_load_url_clicked),(current_sort_label,self.toggle_sort),("Refresh",self.on_refresh_clicked),("Load EPG",self.on_load_epg_clicked),("Clear Playlist",self.on_clear_clicked)]:
            mi=Gtk.MenuItem(label=l)
            mi.connect("activate",cb)
            self.main_menu.append(mi)
        self.main_menu.append(Gtk.SeparatorMenuItem())
        mi_fab=Gtk.CheckMenuItem(label="Show FAB")
        mi_fab.set_active(self.show_fab_enabled)
        mi_fab.connect("toggled",self.toggle_fab_visibility)
        self.main_menu.append(mi_fab)
        mi_logos=Gtk.CheckMenuItem(label="Show Logos on Hover")
        mi_logos.set_active(self.show_logos_enabled)
        mi_logos.connect("toggled",self.toggle_logos_visibility)
        self.main_menu.append(mi_logos)
        self.main_menu.append(Gtk.SeparatorMenuItem())
        self.main_menu.append(self.socket_root_item)
        self.main_menu.show_all()

    def toggle_fab_visibility(self,mi):
        self.show_fab_enabled=mi.get_active()
        self.fab_container.set_visible(self.show_fab_enabled)
        self.save_all_data()

    def toggle_logos_visibility(self,mi):
        self.show_logos_enabled=mi.get_active()
        if not self.show_logos_enabled:self.logo_popup.hide()
        self.save_all_data()

    def refresh_sockets(self):
        if self.is_probing_sockets:return True
        self.is_probing_sockets=True
        def _bg_probe():
            try:
                sockets=sorted(glob.glob("/dev/shm/mpvsocket*")+glob.glob("/tmp/mpvsocket*"))
                new_available=[]
                for s in sockets:
                    title_res=self.send_command({"command":["get_property","media-title"]},path=s)
                    label=title_res.get("data") if (title_res and title_res.get("data")) else os.path.basename(s)
                    new_available.append((s,label))
                GLib.idle_add(self._apply_socket_refresh,new_available)
            finally:self.is_probing_sockets=False
        threading.Thread(target=_bg_probe,daemon=True).start()
        return True

    def _apply_socket_refresh(self,new_list):
        self.available_sockets=new_list
        self.rebuild_socket_menu()
        return False

    def rebuild_socket_menu(self):
        for c in self.socket_submenu.get_children():self.socket_submenu.remove(c)
        for s,label in self.available_sockets:
            mi=Gtk.MenuItem(label=f"✔ {label}" if s==self.socket_path else label)
            mi.connect("activate",self.switch_socket,s)
            self.socket_submenu.append(mi)
        self.socket_submenu.show_all()

    def switch_socket(self,mi,path):
        self.socket_path=path
        self.update_playlist()

    def send_command(self,cmd,path=None):
        try:
            with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as c:
                c.settimeout(0.5)
                c.connect(path or self.socket_path)
                payload=dict(cmd)
                payload["request_id"]=999
                c.sendall(json.dumps(payload).encode()+b"\n")
                c.setblocking(False)
                res=b""
                while True:
                    r,_,_=select.select([c],[],[],0.5)
                    if r:
                        try:chunk=c.recv(16384)
                        except BlockingIOError:continue
                        except Exception:break
                        if not chunk:break
                        res+=chunk
                        lines=res.split(b"\n")
                        n_lines=len(lines)
                        if n_lines>1:
                            for line in lines[:n_lines-1]:
                                if not line.strip():continue
                                try:
                                    data=json.loads(line)
                                    if data.get("request_id")==999:return data
                                except:continue
                            res=lines[n_lines-1]
                    else:break
        except:pass
        return None

    def send_commands_batch(self,cmds):
        if not cmds:return None
        try:
            with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as c:
                c.settimeout(1.0)
                c.connect(self.socket_path)
                for cmd in cmds:c.sendall(json.dumps(cmd).encode()+b"\n")
                c.setblocking(False)
                while True:
                    r,_,_=select.select([c],[],[],0.2)
                    if r:
                        try:chunk=c.recv(16384)
                        except BlockingIOError:continue
                        except Exception:break
                        if not chunk:break
                    else:break
        except:pass
        return None

    def send_commands_batch_read(self,cmds):
        cdef int i,n_cmds,received
        n_cmds=len(cmds)
        results=[None]*n_cmds
        if not n_cmds:return results
        try:
            with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as c:
                c.settimeout(1.0)
                c.connect(self.socket_path)
                for i,cmd in enumerate(cmds):
                    payload=dict(cmd)
                    payload["request_id"]=i
                    c.sendall(json.dumps(payload).encode()+b"\n")
                c.setblocking(False)
                buf=b""
                received=0
                while received<n_cmds:
                    r,_,_=select.select([c],[],[],1.0)
                    if r:
                        try:chunk=c.recv(16384)
                        except BlockingIOError:continue
                        except Exception:break
                        if not chunk:break
                        buf+=chunk
                        lines=buf.split(b"\n")
                        n_lines=len(lines)
                        for line in lines[:n_lines-1]:
                            if not line.strip():continue
                            try:
                                data=json.loads(line)
                                rid=data.get("request_id")
                                if rid is not None and 0<=rid<n_cmds:
                                    results[rid]=data
                                    received+=1
                            except:continue
                        buf=lines[n_lines-1]
                    else:break
        except:pass
        return results

    def update_playlist(self):
        with self.update_lock:
            if self.is_updating:return
            self.is_updating=True
        threading.Thread(target=self._update_thread,daemon=True).start()

    def _update_thread(self):
        cdef int idx,sm
        cdef bint paused
        cdef str cur_grp,curr_p,fn,name,grp
        cdef dict group_counts={}
        cdef list items=[]
        cdef list move_cmds=[]
        try:
            results=self.send_commands_batch_read([{"command":["get_property","playlist"]},{"command":["get_property","path"]},{"command":["get_property","pause"]}])
            res=results[0] if results else None
            path_res=results[1] if results else None
            pause_res=results[2] if results else None
            curr_p=path_res.get("data","") if path_res else ""
            paused=pause_res.get("data",False) if pause_res else False
            if not res or "data" not in res:
                GLib.idle_add(self._finalize_update,{},[]," ",False)
                return
            with self.favorites_lock:fav_copy=set(self.favorites)
            url_to_group=self.url_to_group
            url_to_name=self.url_to_name
            m3u_groups=self.m3u_groups
            _normalize=self._normalize
            _get_nkey=self._get_nkey
            self.last_mpv_cnt=len(res["data"])
            for idx,entry in enumerate(res["data"]):
                fn=entry.get("filename","")
                name=(url_to_name.get(fn) or entry.get("title") or os.path.basename(fn) or "Unknown").strip()
                grp=url_to_group.get(fn) or m3u_groups.get(name) or m3u_groups.get(_normalize(name)) or "Uncategorized"
                group_counts[grp]=group_counts.get(grp,0)+1
                items.append(PlaylistItem(name,fn,idx,grp,_get_nkey(name)))
            sm=self.sort_mode
            cur_grp=self.current_group
            if sm!=2:
                cur_grp_all=(cur_grp=="All")
                cur_grp_fav=(cur_grp=="★ Favorites")
                def sort_key(x):
                    in_fav=(x.name in fav_copy)
                    tier=-((2 if in_fav else 0)+(1 if (cur_grp_all or (cur_grp_fav and in_fav) or x.group==cur_grp) else 0))
                    return (tier,x.nkey_rev if sm==1 else x.nkey,x.filename)
                items.sort(key=sort_key)
            n=len(items)
            if n>0:
                target_state=[it.orig_idx for it in items]
                current_mpv_state=list(range(n))
                pos_map={val:i for i,val in enumerate(current_mpv_state)}
                for i in range(n):
                    target=target_state[i]
                    if current_mpv_state[i]!=target:
                        current_pos=pos_map[target]
                        move_cmds.append({"command":["playlist-move",current_pos,i]})
                        val=current_mpv_state.pop(current_pos)
                        current_mpv_state.insert(i,val)
                        start=min(i,current_pos); end=max(i,current_pos)
                        for j in range(start,end+1): pos_map[current_mpv_state[j]]=j
            if move_cmds and self._playlist_needs_sort:
                self.send_commands_batch(move_cmds)
                self._playlist_needs_sort=False
                for i in range(n):
                    items[i].orig_idx=i
            GLib.idle_add(self._finalize_update,group_counts,items,curr_p,paused)
        except Exception:GLib.idle_add(self._set_updating_false)

    def _set_updating_false(self):
        with self.update_lock:self.is_updating=False
        return False

    def _finalize_update(self,group_counts,list full_sorted,str curr_p,bint paused):
        cdef PlaylistItem item_obj
        self.tree_view.set_model(None)
        self.list_store.clear()
        self.full_list_data=full_sorted
        self.current_playing_path=curr_p
        self.is_paused=paused
        # Ensure current group is valid for the new playlist
        if self.current_group not in group_counts and self.current_group not in ("All","★ Favorites"):
            self.current_group="All"
        with self.favorites_lock:fav_copy=set(self.favorites)
        self.filter_cached_favs=fav_copy
        active_store_path=None
        ls_append=self.list_store.append
        have_epg=bool(self.epg_data)
        for item_obj in full_sorted:
            fn=item_obj.filename
            nm=item_obj.name
            is_p=(fn==curr_p)
            is_f=(nm in fav_copy)
            status_icon="⏸ " if (is_p and paused) else ("▶ " if is_p else "")
            dn=status_icon+("★ " if is_f else "")+nm
            bg,fg,w=("#3584e4","#ffffff",800) if is_p else ("","",400)
            # EPG lookup
            epg_title=""; epg_prog=-1.0; epg_rem=0
            if have_epg:
                tvg_id=self.url_to_tvgid.get(fn)
                if tvg_id:
                    t,p,r=self.get_current_programme(tvg_id)
                    if t:epg_title=t; epg_prog=p; epg_rem=r
            ls_append([dn,item_obj.orig_idx,w,item_obj.group,fg,bg,fn,nm,nm.lower(),epg_title,epg_prog,epg_rem])
            if is_p:
                active_store_path=len(self.list_store)-1
                self._last_playing_path = fn
        self.rebuild_group_menu(group_counts)
        self.tree_view.set_model(self.filter)
        self.filter.refilter()
        if active_store_path is not None:
            store_iter=self.list_store.iter_nth_child(None,active_store_path)
            if store_iter:
                filter_path=self.filter.convert_child_path_to_path(self.list_store.get_path(store_iter))
                if filter_path:
                    self.tree_view.get_selection().select_path(filter_path)
                    self.tree_view.scroll_to_cell(filter_path,None,True,0.5,0.5)
        if not self.resume_done and self.last_file_path:
            for item_obj in full_sorted:
                if item_obj.filename==self.last_file_path:
                    self.send_command({"command":["set_property","playlist-pos",item_obj.orig_idx]})
                    self.send_command({"command":["set_property","pause",True]})
                    self.resume_done=True
                    break
        with self.update_lock:self.is_updating=False
        return False

    def rebuild_group_menu(self,group_counts):
        for c in self.group_menu.get_children():self.group_menu.remove(c)
        with self.favorites_lock:fav_copy=set(self.favorites)
        f_count=sum(1 for x in self.full_list_data if x.name in fav_copy)
        cur=self.current_group
        for gn,c in [("All",len(self.full_list_data)),("★ Favorites",f_count)]:
            lbl=f"{gn} ({c})"
            item=Gtk.MenuItem(label=f"• {lbl}" if gn==cur else lbl)
            item.connect("activate",self.on_group_selected,gn)
            self.group_menu.append(item)
        self.group_menu.append(Gtk.SeparatorMenuItem())
        for g in sorted(group_counts.keys()):
            lbl=f"{g} ({group_counts[g]})"
            item=Gtk.MenuItem(label=f"• {lbl}" if g==cur else lbl)
            item.connect("activate",self.on_group_selected,g)
            self.group_menu.append(item)
        self.group_menu.show_all()

    def on_group_selected(self,mi,name):
        self.current_group=name
        self.save_all_data()
        self.update_playlist()

    def update_now_playing(self):
        results=self.send_commands_batch_read([{"command":["get_property","path"]},{"command":["get_property","pause"]},{"command":["get_property","media-title"]},{"command":["get_property","playlist-count"]}])
        if not results:return True
        path_res,pause_res,title_res,count_res=results[0],results[1],results[2],results[3]
        new_path=path_res.get("data","") if path_res else ""
        new_pause=pause_res.get("data",False) if pause_res else False
        new_count=count_res.get("data",-1) if count_res else -1
        path_changed=(new_path!=self.current_playing_path)
        pause_changed=(new_pause!=self.is_paused)
        count_changed=(new_count>=0 and new_count!=self.last_mpv_cnt)
        if count_changed:
            self.current_playing_path=new_path
            self.is_paused=new_pause
            self.update_playlist()
        elif path_changed or pause_changed:
            self.current_playing_path=new_path
            self.is_paused=new_pause
            self._update_playing_state_ui()
        if title_res and "data" in title_res:self.set_title(str(title_res.get('data')) or "MPV")
        return True

    def _update_playing_state_ui(self):
        with self.favorites_lock: fav_copy = set(self.favorites)
        cdef str curr_p = self.current_playing_path
        cdef str last_p = self._last_playing_path
        cdef bint paused = self.is_paused
        
        if curr_p == last_p and self._last_pause_state == paused:
            return

        self._last_pause_state = paused
        # Instead of O(N) loop, we just find the rows that need updating
        # We'll do a quick pass because we don't have a stable mapping yet (ListStore iters change)
        # But we can optimize the loop by only doing work when necessary
        for row in self.list_store:
            fn = row[6]
            if fn == curr_p or fn == last_p:
                nm = row[7]
                is_p = (fn == curr_p)
                is_f = (nm in fav_copy)
                status_icon = "⏸ " if (is_p and paused) else ("▶ " if is_p else "")
                dn = status_icon + ("★ " if is_f else "") + nm
                bg, fg, w = ("#3584e4", "#ffffff", 800) if is_p else ("", "", 400)
                if row[0] != dn: row[0] = dn
                if row[2] != w: row[2] = w
                if row[4] != fg: row[4] = fg
                if row[5] != bg: row[5] = bg
        
        self._last_playing_path = curr_p

    def filter_func(self,model,tree_iter,data):
        cg=self.current_group; sq=self.current_search_query
        if cg=="All" and not sq:return True
        fc=self.filter_cached_favs
        name=model.get_value(tree_iter,7)
        is_fav=(name in fc)
        if cg=="★ Favorites":
            if not is_fav:return False
            if not sq:return True
            return sq in model.get_value(tree_iter,8)
        if not is_fav:
            grp=model.get_value(tree_iter,3)
            if cg!="All" and grp!=cg:return False
        if not sq:return True
        return sq in model.get_value(tree_iter,8)

    def toggle_sort(self,mi):
        self.sort_mode=1 if self.sort_mode==0 else 0
        self._playlist_needs_sort=True
        self.rebuild_main_menu()
        self.save_all_data()
        self.update_playlist()

    def on_load_clicked(self,mi):
        diag=Gtk.FileChooserDialog(title="Select Playlist",parent=self,action=Gtk.FileChooserAction.OPEN)
        diag.add_buttons("_Cancel",Gtk.ResponseType.CANCEL,"_Open",Gtk.ResponseType.OK)
        if diag.run()==Gtk.ResponseType.OK:self.load_playlist_file(diag.get_filename())
        diag.destroy()

    def on_load_url_clicked(self,mi):
        diag=Gtk.Dialog(title="Load URL",parent=self,flags=0)
        diag.add_buttons("_Cancel",Gtk.ResponseType.CANCEL,"_OK",Gtk.ResponseType.OK)
        diag.set_default_response(Gtk.ResponseType.OK)
        entry=Gtk.Entry(); entry.set_activates_default(True)
        diag.get_content_area().add(entry)
        diag.show_all()
        if diag.run()==Gtk.ResponseType.OK:
            url=entry.get_text()
            if url:self.load_playlist_file(url)
        diag.destroy()

    def on_clear_clicked(self,mi):
        self.send_command({"command":["stop"]})
        self.send_command({"command":["playlist-clear"]})
        self.m3u_groups,self.url_to_group,self.m3u_logos,self.logo_cache,self.url_to_name={},{},{},{},{}
        self.url_to_tvgid={}
        self.update_playlist()

    def on_click(self,tree,event):
        pi=tree.get_path_at_pos(int(event.x),int(event.y))
        if not pi:return
        if event.button==1:self.activate_row(pi[0])
        elif event.button==3:
            f_iter=self.filter.get_iter(pi[0])
            if f_iter:
                n=self.filter.get_value(f_iter,7)
                with self.favorites_lock:
                    if n in self.favorites:self.favorites.discard(n)
                    else:self.favorites.add(n)
                self.save_all_data()
                self.update_playlist()

    def on_key_press(self,tree,event):
        if event.keyval in (Gdk.KEY_Return,Gdk.KEY_KP_Enter,Gdk.KEY_space):
            model,it=tree.get_selection().get_selected()
            if it:self.activate_row(model.get_path(it))
            return True
        return False

    def activate_row(self,path):
        f_iter=self.filter.get_iter(path)
        if f_iter:
            target_idx=self.filter.get_value(f_iter,1)
            res=self.send_command({"command":["get_property","playlist-pos"]})
            if res and res.get("data")==target_idx:self.send_command({"command":["playlist-play-index",target_idx]})
            else:self.send_command({"command":["set_property","playlist-pos",target_idx]})
            self.send_command({"command":["set_property","pause",False]})

    def on_mouse_motion(self,tree,event):
        if not self.show_logos_enabled:return False
        res=tree.get_path_at_pos(int(event.x),int(event.y))
        if res:
            path_str=res[0].to_string()
            if self._last_hover_path==path_str:
                if self.logo_popup.get_visible():
                    self.logo_popup.move(int(event.x_root)+20,int(event.y_root)+10)
                return False
            self._last_hover_path=path_str
            self._logo_hover_active=True
            f_iter=self.filter.get_iter(res[0])
            name=self.filter.get_value(f_iter,7)
            url=self.m3u_logos.get(name)
            if self._logo_timer_id:
                GLib.source_remove(self._logo_timer_id)
                self._logo_timer_id=None
            if url:
                with self.logo_lock:cached=self.logo_cache.get(url)
                if cached:
                    self._show_logo(cached,int(event.x_root),int(event.y_root))
                else:
                    self._current_hover_url=url
                    self._logo_timer_id=GLib.timeout_add(200,self._logo_timer_cb,url,name,int(event.x_root),int(event.y_root))
            else:
                self._current_hover_url=None
                self._show_logo(self._get_text_placeholder(name),int(event.x_root),int(event.y_root))
            return False
        self._last_hover_path=None
        self._logo_hover_active=False
        self._current_hover_url=None
        if self._logo_timer_id:
            GLib.source_remove(self._logo_timer_id)
            self._logo_timer_id=None
        self.logo_popup.hide()
        return False

    def _logo_timer_cb(self,url,name,x,y):
        self._logo_timer_id=None
        if not self._logo_hover_active or url!=self._current_hover_url:return False
        with self.logo_lock:cached=self.logo_cache.get(url)
        if cached:self._show_logo(cached,x,y)
        else:threading.Thread(target=self._load_logo_async,args=(url,x,y,name),daemon=True).start()
        return False

    def _get_text_placeholder(self,name):
        cache_key="txt_"+name
        if cache_key in self.logo_cache:return self.logo_cache[cache_key]
        surface=cairo.ImageSurface(cairo.FORMAT_ARGB32,60,60)
        ctx=cairo.Context(surface)
        ctx.arc(30,30,30,0,2*math.pi)
        ctx.set_source_rgba(0,0,0,0.5)
        ctx.fill()
        layout=PangoCairo.create_layout(ctx)
        layout.set_text(name,-1)
        layout.set_width(44*Pango.SCALE)
        layout.set_wrap(Pango.WrapMode.WORD_CHAR)
        layout.set_alignment(Pango.Alignment.CENTER)
        current_size=14
        while current_size>5:
            desc=Pango.FontDescription(f"Sans Bold {current_size}")
            layout.set_font_description(desc)
            w,h=layout.get_pixel_size()
            if h<=44:break
            current_size-=1
        ctx.set_source_rgb(0.9,0.9,0.9)
        w,h=layout.get_pixel_size()
        ctx.move_to(8,(60-h)/2)
        PangoCairo.show_layout(ctx,layout)
        pb=Gdk.pixbuf_get_from_surface(surface,0,0,60,60)
        self.logo_cache[cache_key]=pb
        return pb

    def _load_logo_async(self,url,x,y,name):
        with self._logo_sem:
            if url!=self._current_hover_url:return
            try:
                if url.startswith("http"):
                    req=urllib.request.Request(url,headers={'User-Agent':'Mozilla/5.0'})
                    data=urllib.request.urlopen(req,timeout=1).read()
                    loader=GdkPixbuf.PixbufLoader()
                    try:
                        loader.write(data); loader.close()
                        pb=loader.get_pixbuf()
                    except:
                        try:loader.close()
                        except:pass
                        pb=None
                else:pb=GdkPixbuf.Pixbuf.new_from_file(url)
                if pb:
                    orig_w,orig_h=pb.get_width(),pb.get_height()
                    scale=min(50/orig_w,50/orig_h)
                    nw,nh=max(1,int(orig_w*scale)),max(1,int(orig_h*scale))
                    pb=pb.scale_simple(nw,nh,GdkPixbuf.InterpType.BILINEAR)
                    surface=cairo.ImageSurface(cairo.FORMAT_ARGB32,60,60)
                    ctx=cairo.Context(surface)
                    ctx.arc(30,30,30,0,2*math.pi)
                    ctx.set_source_rgba(0,0,0,0.5)
                    ctx.fill()
                    Gdk.cairo_set_source_pixbuf(ctx,pb,(60-nw)/2,(60-nh)/2)
                    ctx.paint()
                    round_pb=Gdk.pixbuf_get_from_surface(surface,0,0,60,60)
                    with self.logo_lock:
                        if len(self.logo_cache)>200:self.logo_cache.clear()
                        self.logo_cache[url]=round_pb
                    GLib.idle_add(self._show_logo,round_pb,x,y)
                else:GLib.idle_add(self._show_logo,self._get_text_placeholder(name),x,y)
            except:GLib.idle_add(self._show_logo,self._get_text_placeholder(name),x,y)

    def _show_logo(self,pb,x,y):
        if not self.show_logos_enabled or not self._logo_hover_active:return
        self.logo_image.set_from_pixbuf(pb)
        self.logo_popup.move(x+20,y+10)
        self.logo_popup.show_all()

    def on_refresh_clicked(self,mi):
        if self.last_playlist_path:
            path_res=self.send_command({"command":["get_property","path"]})
            if path_res and path_res.get("data"):
                self.last_file_path=path_res["data"]
            self.resume_done=False
            self.load_playlist_file(self.last_playlist_path)
        else:
            self.update_playlist()

    def _parse_m3u_lines(self,lines):
        cdef str lg,line,cn,tvgn,last_name,last_tvgid
        cdef list entries=[]
        re_group=self._re_m3u_group
        re_logo=self._re_m3u_logo
        re_name=self._re_m3u_name
        re_tvgname=self._re_m3u_tvgname
        re_tvgid=self._re_m3u_tvgid
        _normalize=self._normalize
        new_groups={}; new_url={}; new_logos={}; new_url_to_name={}; new_url_to_tvgid={}
        lg="Uncategorized"; last_name=""; last_tvgid=""
        for line in lines:
            line=line.strip()
            if line.startswith("#EXTINF"):
                m=re_group.search(line)
                logo=re_logo.search(line)
                nm=re_name.search(line)
                tvg=re_tvgname.search(line)
                tid=re_tvgid.search(line)
                lg=m.group(1) if m else "Uncategorized"
                last_name=""; last_tvgid=tid.group(1).strip() if tid else ""
                if tvg:
                    tvgn=tvg.group(1).strip()
                    new_groups[_normalize(tvgn)]=lg
                    new_groups[tvgn]=lg
                    if logo:new_logos[tvgn]=logo.group(1)
                    last_name=tvgn
                if nm:
                    cn=nm.group(1).strip()
                    new_groups[_normalize(cn)]=lg
                    new_groups[cn]=lg
                    if logo:new_logos[cn]=logo.group(1)
                    if not last_name:last_name=cn
            elif line and not line.startswith("#"):
                entries.append(line)
                new_url[line]=lg
                if last_name:new_url_to_name[line]=last_name
                if last_tvgid:new_url_to_tvgid[line]=last_tvgid
                last_name=""; last_tvgid=""
        self.m3u_groups=new_groups
        self.url_to_group=new_url
        self.m3u_logos=new_logos
        self.url_to_name=new_url_to_name
        self.url_to_tvgid=new_url_to_tvgid
        return entries

    def load_playlist_file(self,path,append=False):
        cdef bint is_remote
        cdef str lg,line,cn,cmd,cmd_type,temp_m3u,root,f_name
        cdef list files
        cdef tuple exts,pl_exts
        if not path:return
        is_remote=path.startswith(('http://','https://','ftp://'))
        if not append:self.logo_cache={}
        if not is_remote and os.path.isdir(path):
            files=[]
            exts=('.mkv','.mp4','.webm','.avi','.mov','.flv','.wmv','.ts','.m2ts','.mts','.vob','.ogv','.qt','.rmvb','.asf','.amv','.m4v','.mpg','.mpeg','.m2v','.divx','.3gp','.3g2','.mp3','.flac','.wav','.opus','.ogg','.m4a','.aac','.alac','.wma','.aiff','.dsf','.dff','.ape','.wv','.tta','.mpc','.mka','.m4b','.jpg','.jpeg','.png','.webp','.gif','.bmp','.tiff','.svg')
            for root,dirs,fnames in os.walk(path):
                for f_name in sorted(fnames):
                    if f_name.lower().endswith(exts):files.append(os.path.join(root,f_name))
            if files:
                temp_m3u=""
                try:
                    with tempfile.NamedTemporaryFile(mode='w',suffix='.m3u',delete=False,encoding='utf-8') as tf:
                        tf.write('#EXTM3U\n')
                        for f_name in files:tf.write(f_name+'\n')
                        temp_m3u=tf.name
                    cmd_type="append" if append else "replace"
                    self.send_command({"command":["loadlist",temp_m3u,cmd_type]})
                    def _cleanup(p=temp_m3u):
                        try:os.remove(p)
                        except OSError:pass
                        return False
                    GLib.timeout_add(8000,_cleanup)
                except:
                    if temp_m3u and os.path.exists(temp_m3u):
                        try:os.remove(temp_m3u)
                        except OSError:pass
        else:
            pl_exts=('.m3u','.m3u8','.pls','.xspf','.cue','.asx','.txt')
            cmd_type="append" if append else "replace"
            m3u_entries=[]
            if not is_remote and os.path.exists(path) and path.lower().split("?")[0].endswith(pl_exts):
                try:
                    with open(path,"r",encoding="utf-8",errors="ignore") as f:
                        m3u_entries=self._parse_m3u_lines(f)
                except:pass
            elif is_remote:
                try:
                    req=urllib.request.Request(path,headers={"User-Agent":"Mozilla/5.0"})
                    m3u_content=urllib.request.urlopen(req,timeout=15).read().decode("utf-8",errors="ignore")
                    if "#EXTINF" in m3u_content:
                        m3u_entries=self._parse_m3u_lines(m3u_content.splitlines())
                except:pass

            if m3u_entries:
                if not append:
                    self.send_command({"command":["stop"]})
                    self.send_command({"command":["playlist-clear"]})
                # Load in batches of 500 for performance
                for i in range(0,len(m3u_entries),500):
                    batch=[{"command":["loadfile",url,"append"]} for url in m3u_entries[i:i+500]]
                    self.send_commands_batch(batch)
            else:
                cmd="loadlist" if (not is_remote and path.lower().split("?")[0].endswith(pl_exts)) else "loadfile"
                self.send_command({"command":[cmd,path,cmd_type]})

        if not append:
            self.last_playlist_path=path
            self._playlist_needs_sort=True
        self.save_all_data()
        self.send_command({"command":["set_property","pause",False]})
        GLib.timeout_add(1500,self.update_playlist)

    def load_all_data(self):
        try:
            if os.path.exists(self.config_file):
                with open(self.config_file,"r",encoding="utf-8") as f:
                    c=json.load(f)
                    self.move(c.get("x",100),c.get("y",100))
                    self.resize(c.get("w",200),c.get("h",750))
                    self.current_group=c.get("current_group","All")
                    self.last_file_path=c.get("last_playing","")
                    self.favorites=set(c.get("favorites",[]))
                    self.last_playlist_path=c.get("last_playlist_path","")
                    self.sort_mode=c.get("sort_mode",0)
                    self.show_fab_enabled=c.get("show_fab",True)
                    self.show_logos_enabled=c.get("show_logos",True)
                    self.epg_path=c.get("epg_path","")
        except:pass

    def save_all_data(self):
        try:
            path_res=self.send_command({"command":["get_property","path"]})
            curr=path_res.get("data","") if path_res else self.last_file_path
            pos,size=self.get_position(),self.get_size()
            with self.file_lock:
                with open(self.config_file,"w",encoding="utf-8") as f:
                    json.dump({"x":pos[0],"y":pos[1],"w":size[0],"h":size[1],"current_group":self.current_group,"last_playing":curr,"favorites":list(self.favorites),"last_playlist_path":self.last_playlist_path,"sort_mode":self.sort_mode,"show_fab":self.show_fab_enabled,"show_logos":self.show_logos_enabled,"epg_path":self.epg_path},f)
        except:pass

    def on_configure_event(self,w,e):
        if not self._save_pending:
            self._save_pending=True
            GLib.timeout_add(500,self._do_save)
        return False

    def _do_save(self):
        self._save_pending=False
        self.save_all_data()
        return False

    def on_delete_event(self,w,e):
        self.save_all_data()
        self.logo_popup.destroy()
        Gtk.main_quit()

    def on_drag_data_received(self,w,c,x,y,s,i,t):
        uris=s.get_uris()
        if uris:
            for idx,uri in enumerate(uris):
                try:p=GLib.filename_from_uri(uri)[0] if uri.startswith("file://") else uri
                except Exception:p=uri
                self.load_playlist_file(p,append=(idx>0))
        c.finish(True,False,t)

    def auto_load_last_m3u(self):
        if self.last_playlist_path:
            is_remote=self.last_playlist_path.startswith(('http://','https://','ftp://'))
            if is_remote or os.path.exists(self.last_playlist_path):
                self.load_playlist_file(self.last_playlist_path)
                # Reload EPG after playlist is loaded (delay so tvg-ids are parsed)
                if self.epg_path:
                    GLib.timeout_add(3000,lambda:self.load_epg_file(self.epg_path) or False)
                return False
        self.update_playlist()
        return False

    def on_vol_changed(self,scale):
        v=int(scale.get_value())
        self.send_command({"command":["set_property","volume",v]})

    def on_fab_clicked(self,btn):
        if not self.revealer.get_reveal_child():
            res=self.send_command({"command":["get_property","volume"]})
            if res and "data" in res:self.vol_scale.set_value(res["data"])
        self.revealer.set_reveal_child(not self.revealer.get_reveal_child())

if __name__=="__main__":
    win=MPVGTKManager()
    Gtk.main()
