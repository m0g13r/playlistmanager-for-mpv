# cython: language_level=3, boundscheck=False, wraparound=False, cdivision=True
import sys,socket,json,os,subprocess,re,threading,glob,urllib.request,tempfile,select,io,calendar
import time as time_mod
import xml.etree.ElementTree as ET
from datetime import datetime as _datetime
from PySide6.QtWidgets import QApplication,QMainWindow,QWidget,QVBoxLayout,QHBoxLayout,QLineEdit,QListView,QPushButton,QFileDialog,QAbstractItemView,QFrame,QMenu,QSlider,QLabel,QToolTip,QInputDialog,QStyledItemDelegate,QStyle
from PySide6.QtCore import Qt,QTimer,Signal,QObject,QPoint,QItemSelectionModel,QEvent,QRect,QRectF,QSize
from PySide6.QtGui import QStandardItemModel,QStandardItem,QColor,QFont,QIcon,QPixmap,QImage,QPainter,QFontMetrics,QBrush,QPainterPath
os.environ["QT_ACCESSIBILITY"]="0"

cdef class PlaylistItem:
    cdef public str name
    cdef public str name_lower
    cdef public str filename
    cdef public int orig_idx
    cdef public str group
    cdef public list nkey
    cdef public list nkey_rev
    def __init__(self,str name,str filename,int orig_idx,str group,list nkey):
        self.name=name
        self.name_lower=name.lower()
        self.filename=filename
        self.orig_idx=orig_idx
        self.group=group
        self.nkey=nkey
        # For reverse sort, we flip the ranks and the values
        self.nkey_rev=[(-rank,-val if isinstance(val,int) else ''.join(chr(0x10FFFF-ord(c)) for c in val)) for rank,val in nkey]

class UpdateSignals(QObject):
    finished=Signal(dict,list,str,bool)
    logo_loaded=Signal(object,QPoint)
    sockets_refreshed=Signal(list)

class LogoPopup(QLabel):
    def __init__(self):
        super().__init__(None)
        self.setWindowFlags(Qt.ToolTip|Qt.FramelessWindowHint|Qt.WindowTransparentForInput|Qt.WindowStaysOnTopHint)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setFixedSize(64,64)
        self.setAlignment(Qt.AlignCenter)
        self.padding=6
    def paintEvent(self,event):
        painter=QPainter(self)
        painter.setRenderHint(QPainter.Antialiasing)
        painter.setBrush(QBrush(QColor(13,13,13,127)))
        painter.setPen(Qt.NoPen)
        painter.drawRoundedRect(self.rect(),32,32)
        pm=self.pixmap()
        if pm and pm.width()>0 and pm.height()>0:
            target_rect=self.rect().adjusted(self.padding,self.padding,-self.padding,-self.padding)
            aspect_ratio=pm.width()/pm.height()
            w=float(target_rect.width())
            h=float(target_rect.height())
            if w/aspect_ratio<=h:h=w/aspect_ratio
            else:w=h*aspect_ratio
            x=target_rect.x()+(target_rect.width()-w)/2
            y=target_rect.y()+(target_rect.height()-h)/2
            painter.drawPixmap(QRect(int(x),int(y),int(w),int(h)),pm)
        painter.end()

# ── EPG cell delegate ─────────────────────────────────────────────────────────
class EPGDelegate(QStyledItemDelegate):
    """Paints list rows with an optional EPG subtitle + progress bar."""
    EPG_ROLE   = Qt.UserRole+2
    _H_NORMAL  = 36   # px  – matches QSS padding (6+~20+6)
    _H_EPG     = 62   # px  – name + subtitle + progress bar
    _PB_H      = 5    # progress-bar height
    _RADIUS    = 8.0  # item corner radius
    _PB_R      = 2.5  # progress-bar corner radius

    IS_PLAYING_ROLE = Qt.UserRole+4   # bool stored directly on item

    # ── colours per state ──────────────────────────────────────────────────
    _C = {
        'play': dict(
            bg='#3584e4', name='#ffffff', epg='#b8d8ff', rem='#8ec0ff',
            pb_bg=(255,255,255,60), pb_fill='#ffffff'),
        'sel': dict(
            bg='#ddeeff', name='#003366', epg='#336699', rem='#5588bb',
            pb_bg=(80,140,210,60), pb_fill='#3584e4'),
        'norm': dict(
            bg=None, name='#333333', epg='#888888', rem='#aaaaaa',
            pb_bg='#e0e0e0', pb_fill='#3584e4'),
    }

    def sizeHint(self,option,index):
        w=max(option.rect.width(),120)
        return QSize(w,self._H_EPG if index.data(self.EPG_ROLE) else self._H_NORMAL)

    def paint(self,painter,option,index):
        painter.save()
        painter.setRenderHint(QPainter.Antialiasing)
        painter.setRenderHint(QPainter.TextAntialiasing)

        epg     = index.data(self.EPG_ROLE)
        is_play = bool(index.data(self.IS_PLAYING_ROLE))
        is_sel  = not is_play and bool(option.state & QStyle.State_Selected)
        c        = self._C['play'] if is_play else (self._C['sel'] if is_sel else self._C['norm'])

        rect = QRectF(option.rect.adjusted(0,0,0,-2))

        # Background ──────────────────────────────────────────────────────────
        if c['bg']:
            path=QPainterPath()
            path.addRoundedRect(rect,self._RADIUS,self._RADIUS)
            painter.fillPath(path,QColor(c['bg']))

        inner = rect.adjusted(10,6,-10,-6)
        display = index.data(Qt.DisplayRole) or ""
        fd = index.data(Qt.FontRole)
        bold = fd.bold() if fd else False

        if epg:
            epg_title,progress,remaining_sec = epg

            # Name ─────────────────────────────────────────────────────────
            nf=QFont(); nf.setBold(bold)
            painter.setFont(nf); painter.setPen(QColor(c['name']))
            nm_r=QRect(int(inner.left()),int(inner.top()),int(inner.width()),20)
            painter.drawText(nm_r,Qt.AlignLeft|Qt.AlignVCenter,
                             QFontMetrics(nf).elidedText(display,Qt.ElideRight,nm_r.width()))

            # EPG subtitle ─────────────────────────────────────────────────
            ef=QFont(); ef.setPointSize(8)
            painter.setFont(ef)
            fm2=QFontMetrics(ef)
            mins=remaining_sec//60
            tstr=f"+{mins}m" if mins>0 else ""
            tw=fm2.horizontalAdvance(tstr)+2 if tstr else 0

            if tstr:
                painter.setPen(QColor(c['rem']))
                painter.drawText(QRect(int(inner.right()-tw),int(inner.top())+22,tw,14),
                                 Qt.AlignRight|Qt.AlignVCenter,tstr)

            painter.setPen(QColor(c['epg']))
            er=QRect(int(inner.left()),int(inner.top())+22,int(inner.width())-tw-4,14)
            painter.drawText(er,Qt.AlignLeft|Qt.AlignVCenter,
                             fm2.elidedText(epg_title,Qt.ElideRight,er.width()))

            # Progress bar ─────────────────────────────────────────────────
            pby=int(inner.bottom())-self._PB_H-2
            pbr=QRectF(inner.left(),pby,inner.width(),self._PB_H)
            painter.setPen(Qt.NoPen)

            pb_bg=c['pb_bg']
            if isinstance(pb_bg,str):  bg_c=QColor(pb_bg)
            else:                       bg_c=QColor(*pb_bg)
            bp=QPainterPath(); bp.addRoundedRect(pbr,self._PB_R,self._PB_R)
            painter.fillPath(bp,bg_c)

            fw=inner.width()*min(1.0,max(0.0,progress))
            if fw>1:
                fp=QPainterPath()
                fp.addRoundedRect(QRectF(inner.left(),pby,fw,self._PB_H),self._PB_R,self._PB_R)
                painter.fillPath(fp,QColor(c['pb_fill']))
        else:
            # Plain single-line ────────────────────────────────────────────
            nf=QFont(); nf.setBold(bold)
            painter.setFont(nf); painter.setPen(QColor(c['name']))
            painter.drawText(inner.toRect(),Qt.AlignLeft|Qt.AlignVCenter,display)

        painter.restore()

# ── Main window ───────────────────────────────────────────────────────────────
class MPVQtManager(QMainWindow):
    USER_ROLE     = Qt.UserRole
    RAW_NAME_ROLE = Qt.UserRole+1
    EPG_ROLE      = Qt.UserRole+2
    FILENAME_ROLE = Qt.UserRole+3
    IS_PLAYING_ROLE = Qt.UserRole+4

    def __init__(self):
        super().__init__()
        self.lock=threading.Lock()
        self.setWindowFlags(Qt.Window|Qt.CustomizeWindowHint|Qt.WindowCloseButtonHint)
        self.setAcceptDrops(True)
        self.setWindowTitle("MPV")
        self.socket_path="/dev/shm/mpvsocket"
        self.config_file=os.path.expanduser("~/.mpv_qt_config.json")
        self._re_nonword=re.compile(r'\W+')
        self._re_digit=re.compile(r'(\d+)')
        self._re_m3u_group=re.compile(r'group-title="([^"]+)"')
        self._re_m3u_logo=re.compile(r'tvg-logo="([^"]+)"')
        self._re_m3u_name=re.compile(r',(.+)$')
        self._re_m3u_tvgname=re.compile(r'tvg-name="([^"]+)"')
        self._re_m3u_tvgid=re.compile(r'tvg-id="([^"]+)"')
        self.favorites,self.m3u_groups,self.url_to_group,self.m3u_logos,self.logo_cache=set(),{},{},{},{}
        self.url_to_name={}
        self.url_to_tvgid={}          # url → tvg-id
        self.epg_data={}              # channel-id → [(start_ts, stop_ts, title), …]
        self.epg_path=""
        self._nkey_cache={}
        self._norm_cache={}
        self.sort_mode,self.current_playing_filename,self.is_paused,self.current_group=0,"",False,"All"
        self.full_list,self.group_counts,self.is_updating,self.resume_done,self.last_file,self.last_playlist_path=[],{},False,False,"",""
        self.show_fab_enabled,self.show_logos_enabled=True,True
        self._logo_hover_active=False
        self._current_hover_url=None
        self._last_hover_idx=None
        self._logo_timer_id=None
        self._playlist_needs_sort=True
        self._logo_sem=threading.Semaphore(4)
        self.update_lock=threading.Lock()
        self.logo_lock=threading.Lock()
        self.is_probing_sockets=False
        self._save_timer=None
        self.last_mpv_cnt=0
        self.load_all_data()
        self.signals=UpdateSignals()
        self.signals.finished.connect(self._finalize_update)
        self.signals.sockets_refreshed.connect(self._apply_socket_refresh)
        self.signals.logo_loaded.connect(self._show_logo_popup)
        self.apply_styles()
        self.ensure_mpv_running()
        central=QWidget()
        self.setCentralWidget(central)
        self.vbox=QVBoxLayout(central)
        self.vbox.setSpacing(4)
        self.vbox.setContentsMargins(5,5,5,5)
        self.header=QHBoxLayout()
        self.header.setSpacing(4)
        self.search_entry=QLineEdit()
        self.search_entry.setPlaceholderText("Search...")
        self.search_entry.setFixedHeight(28)
        self.search_entry.textChanged.connect(self.filter_playlist)
        self.group_btn,self.burger_btn=QPushButton("▾"),QPushButton("≡")
        self.group_btn.setFixedSize(28,28)
        self.burger_btn.setFixedSize(28,28)
        self.header.addWidget(self.search_entry)
        self.header.addWidget(self.group_btn)
        self.header.addWidget(self.burger_btn)
        self.vbox.addLayout(self.header)
        self.tree_view=QListView()
        self.tree_view.setFrameShape(QFrame.NoFrame)
        self.tree_view.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.tree_view.setVerticalScrollBarPolicy(Qt.ScrollBarAsNeeded)
        self.list_model=QStandardItemModel()
        self.tree_view.setModel(self.list_model)
        self.tree_view.setEditTriggers(QAbstractItemView.NoEditTriggers)
        self.tree_view.setMouseTracking(True)
        self.tree_view.viewport().installEventFilter(self)
        # EPG delegate ─────────────────────────────────────────────────────
        self._epg_delegate=EPGDelegate(self.tree_view)
        self.tree_view.setItemDelegate(self._epg_delegate)
        self.vbox.addWidget(self.tree_view)
        self.logo_label=LogoPopup()
        self.fab_container=QWidget(self)
        self.fab_layout=QVBoxLayout(self.fab_container)
        self.fab_layout.setContentsMargins(0,0,0,0)
        self.fab_layout.setSpacing(6)
        self.sub_buttons=QWidget()
        self.sub_layout=QVBoxLayout(self.sub_buttons)
        self.sub_layout.setContentsMargins(0,0,0,0)
        self.sub_layout.setSpacing(6)
        self.vol_slider=QSlider(Qt.Vertical)
        self.vol_slider.setRange(0,130)
        self.vol_slider.setFixedSize(32,120)
        self.vol_slider.setObjectName("fab-vol")
        self.vol_slider.valueChanged.connect(self.on_vol_changed)
        self.sub_layout.addWidget(self.vol_slider)
        for icon_name,cmd in [("media-playlist-shuffle-symbolic",["playlist-shuffle"]),("media-skip-forward-symbolic",["playlist-next"]),("media-playback-start-symbolic",["cycle","pause"]),("media-skip-backward-symbolic",["playlist-prev"])]:
            btn=QPushButton()
            btn.setIcon(QIcon.fromTheme(icon_name))
            if icon_name=="media-playlist-shuffle-symbolic":
                btn.setObjectName("fab-shuffle")
                btn.clicked.connect(self.on_shuffle_clicked)
            else:
                btn.setObjectName("fab-small")
                btn.clicked.connect(lambda checked=False,c=cmd:self.send_command({"command":c}))
            btn.setFixedSize(32,32)
            self.sub_layout.addWidget(btn)
        self.sub_buttons.setVisible(False)
        self.main_fab=QPushButton()
        self.main_fab.setIcon(QIcon.fromTheme("view-more-horizontal-symbolic"))
        self.main_fab.setObjectName("fab-trigger")
        self.main_fab.setFixedSize(32,32)
        self.main_fab.clicked.connect(self.toggle_fab)
        self.fab_layout.addWidget(self.sub_buttons)
        self.fab_layout.addWidget(self.main_fab)
        self.fab_container.setVisible(self.show_fab_enabled)
        self.group_btn.clicked.connect(self.show_group_menu)
        self.burger_btn.clicked.connect(self.show_burger_menu)
        self.tree_view.clicked.connect(self.on_row_activated)
        self.tree_view.setContextMenuPolicy(Qt.CustomContextMenu)
        self.tree_view.customContextMenuRequested.connect(self.on_right_click)
        QTimer.singleShot(0,self.auto_load_last_m3u)
        self.timer=QTimer()
        self.timer.timeout.connect(self.update_now_playing)
        self.timer.start(1000)
        self.socket_timer=QTimer()
        self.socket_timer.timeout.connect(self.refresh_sockets)
        self.socket_timer.start(5000)
        # EPG refresh timer (every 30 s, updates progress without rebuilding list)
        self.epg_timer=QTimer()
        self.epg_timer.timeout.connect(self._update_epg_display)
        self.epg_timer.start(30000)
        self.available_sockets=[]

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
        """Return (title, progress 0-1, remaining_seconds) or (None,0,0)."""
        now=time_mod.time()
        progs=self.epg_data.get(tvg_id)
        if not progs:return None,0.0,0
        # binary-search for the last programme that has started
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
            # Full rebuild so sizeHint is re-queried and EPG rows get correct height
            QTimer.singleShot(0,self.filter_playlist)
        except Exception:pass

    def _update_epg_display(self):
        """Refresh progress/remaining values every 30 s — no layout change needed
        because heights are already correct after the initial filter_playlist call."""
        if not self.epg_data:return
        changed=False
        for r in range(self.list_model.rowCount()):
            item=self.list_model.item(r)
            if item is None:continue
            fn=item.data(self.FILENAME_ROLE)
            if not fn:continue
            tvg_id=self.url_to_tvgid.get(fn)
            if not tvg_id:continue
            title,prog,rem=self.get_current_programme(tvg_id)
            new_epg=(title,prog,rem) if title else None
            if item.data(self.EPG_ROLE)!=new_epg:
                item.setData(new_epg,self.EPG_ROLE)
                changed=True
        if changed:
            top=self.list_model.index(0,0)
            bot=self.list_model.index(max(0,self.list_model.rowCount()-1),0)
            self.list_model.dataChanged.emit(top,bot)
            self.tree_view.updateGeometries()

    def on_load_epg_clicked(self):
        """Open file dialog or accept a URL for the EPG XML."""
        path,_=QFileDialog.getOpenFileName(self,"EPG XML","","XML Files (*.xml *.gz);;All (*)")
        if not path:
            path,ok=QInputDialog.getText(self,"Load EPG URL","Enter EPG URL (http/https):")
            if not ok or not path:return
        self.load_epg_file(path.strip())

    # ── FAB / shuffle ─────────────────────────────────────────────────────────
    def on_shuffle_clicked(self,checked=False):
        self.sort_mode=2
        self.send_command({"command":["playlist-shuffle"]})
        self.sub_buttons.setVisible(False)
        self.update_fab_pos()
        self.save_all_data()
        self.update_playlist()

    def apply_styles(self):
        self.setStyleSheet("""QMainWindow{background-color:#ffffff;}*{outline:none;}QPushButton{border:none;background-color:#f2f2f2;border-radius:4px;color:#333;padding:0;margin:0;}QPushButton:hover{background-color:#e5e5e5;}QLineEdit{padding:4px 10px;border:1px solid #eee;border-radius:5px;background:#f9f9f9;}QPushButton#fab-trigger{border-radius:16px;background-color:rgba(53,132,228,180);qproperty-iconSize:20px;}QPushButton#fab-trigger:hover{background-color:rgba(53,132,228,255);}QPushButton#fab-small{border-radius:16px;background-color:rgba(60,60,60,160);qproperty-iconSize:16px;}QPushButton#fab-small:hover{background-color:rgba(80,80,80,220);}QPushButton#fab-shuffle{border-radius:16px;background-color:rgba(60,60,60,160);qproperty-iconSize:16px;color:#444444;}QPushButton#fab-shuffle:hover{background-color:rgba(80,80,80,220);}QSlider#fab-vol{background:rgba(60,60,60,160);border-radius:16px;padding:10px 0px;}QSlider::groove:vertical#fab-vol{background:rgba(255,255,255,40);width:4px;border-radius:2px;}QSlider::handle:vertical#fab-vol{background:#3584e4;height:12px;width:12px;margin:0 -4px;border-radius:6px;}QSlider::sub-page:vertical#fab-vol{background:rgba(255,255,255,40);border-radius:2px;}QSlider::add-page:vertical#fab-vol{background:#3584e4;border-radius:2px;}QListView{background-color:white;border:none;}QListView::item{padding:0px;border-radius:8px;margin-bottom:2px;}QListView::item:selected{background-color:transparent;}QScrollBar:vertical{border:none;background:transparent;width:8px;margin:0;}QScrollBar::handle:vertical{background:#ccc;border-radius:4px;min-height:20px;}QScrollBar::handle:vertical:hover{background:#3584e4;}QScrollBar::add-line,QScrollBar::sub-line,QScrollBar::add-page,QScrollBar::sub-page{background:none;height:0px;}QToolTip{background-color:#333;color:white;border:1px solid #555;padding:3px;border-radius:4px;font-weight:bold;}""")

    def eventFilter(self,source,event):
        if source is self.tree_view.viewport():
            et=event.type()
            if et==QEvent.MouseMove and self.show_logos_enabled:
                idx=self.tree_view.indexAt(event.position().toPoint())
                if idx.isValid():
                    if self._last_hover_idx == idx:
                        if not self.logo_label.isHidden():
                            self.logo_label.move(event.globalPosition().toPoint().x()+15, event.globalPosition().toPoint().y()+15)
                        return False
                    self._last_hover_idx = idx
                    self._logo_hover_active=True
                    name=self.list_model.itemFromIndex(idx).data(self.RAW_NAME_ROLE)
                    url=self.m3u_logos.get(name)
                    pos=event.globalPosition().toPoint()
                    if self._logo_timer_id is not None:
                        self._logo_timer_id.stop()
                        self._logo_timer_id=None
                    if url:
                        with self.logo_lock:cached=self.logo_cache.get(url)
                        if cached:
                            self._show_logo_popup(cached,pos)
                        else:
                            self._current_hover_url=url
                            t=QTimer()
                            t.setSingleShot(True)
                            t.timeout.connect(lambda u=url,n=name,p=pos:self._logo_timer_cb(u,n,p))
                            t.start(200)
                            self._logo_timer_id=t
                    else:
                        self._current_hover_url=None
                        self._show_logo_popup(self._get_text_placeholder(name),pos)
                    return False
                else:
                    self._last_hover_idx=None
                    self._logo_hover_active=False
                    self._current_hover_url=None
                    if self._logo_timer_id is not None:
                        self._logo_timer_id.stop()
                        self._logo_timer_id=None
                    self.logo_label.hide()
            elif et in (QEvent.Leave,QEvent.Wheel):
                self._last_hover_idx=None
                self._logo_hover_active=False
                self._current_hover_url=None
                if self._logo_timer_id is not None:
                    self._logo_timer_id.stop()
                    self._logo_timer_id=None
                self.logo_label.hide()
        return super().eventFilter(source,event)

    def _logo_timer_cb(self,url,name,pos):
        self._logo_timer_id=None
        if not self._logo_hover_active or url!=self._current_hover_url:return
        with self.logo_lock:cached=self.logo_cache.get(url)
        if cached:self._show_logo_popup(cached,pos)
        else:threading.Thread(target=self._load_logo_async,args=(url,pos,name),daemon=True).start()

    def _get_text_placeholder(self,name):
        cache_key="txt_"+name
        if cache_key in self.logo_cache:return self.logo_cache[cache_key]
        pix=QPixmap(64,64)
        pix.fill(Qt.transparent)
        pnt=QPainter(pix)
        pnt.setRenderHint(QPainter.Antialiasing)
        pnt.setRenderHint(QPainter.TextAntialiasing)
        pnt.setPen(QColor("#e6e6e6"))
        fs,p,rect,flags=11,8,QRect(8,8,48,48),Qt.AlignCenter|Qt.TextWordWrap
        font=QFont("Sans Serif",fs,QFont.Bold)
        while fs>5:
            font.setPointSize(fs)
            pnt.setFont(font)
            fm=QFontMetrics(font)
            br=fm.boundingRect(rect,flags,name)
            if br.height()<=48 and not any(fm.horizontalAdvance(w)>48 for w in name.split()):break
            fs-=1
        pnt.drawText(rect,flags,name)
        pnt.end()
        self.logo_cache[cache_key]=pix
        return pix

    def _load_logo_async(self,url,pos,name):
        with self._logo_sem:
            if url!=self._current_hover_url:return
            try:
                if url.startswith("http"):
                    data=urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'Mozilla/5.0'}),timeout=1).read()
                    img=QImage.fromData(data)
                else:img=QImage(url)
                if not img.isNull():
                    pix=QPixmap.fromImage(img).scaled(64,64,Qt.KeepAspectRatio,Qt.SmoothTransformation)
                    with self.logo_lock:
                        if len(self.logo_cache)>200:self.logo_cache.clear()
                        self.logo_cache[url]=pix
                    self.signals.logo_loaded.emit(pix,pos)
                else:self.signals.logo_loaded.emit(name,pos)
            except:self.signals.logo_loaded.emit(name,pos)

    def _show_logo_popup(self,img_or_name,pos):
        if not self._logo_hover_active or not self.show_logos_enabled:return
        if isinstance(img_or_name,str):pix=self._get_text_placeholder(img_or_name)
        else:pix=img_or_name
        self.logo_label.setPixmap(pix)
        self.logo_label.move(pos.x()+15,pos.y()+15)
        if self.logo_label.isHidden():self.logo_label.show()

    def toggle_fab(self):
        self.sub_buttons.setVisible(not self.sub_buttons.isVisible())
        if self.sub_buttons.isVisible():
            res=self.send_command({"command":["get_property","volume"]})
            if res and "data" in res:
                self.vol_slider.blockSignals(True)
                self.vol_slider.setValue(int(res["data"]))
                self.vol_slider.blockSignals(False)
        self.update_fab_pos()

    def on_vol_changed(self,val):
        self.send_command({"command":["set_property","volume",val]})
        QToolTip.showText(self.vol_slider.mapToGlobal(QPoint(-55,50)),f"{val}%",self.vol_slider)

    def resizeEvent(self,event):
        super().resizeEvent(event)
        self.update_fab_pos()
        self._schedule_save()

    def _schedule_save(self):
        if self._save_timer is None:
            self._save_timer=QTimer()
            self._save_timer.setSingleShot(True)
            self._save_timer.timeout.connect(self._do_save)
        self._save_timer.start(500)

    def _do_save(self):self.save_all_data()

    def moveEvent(self,event):
        super().moveEvent(event)
        self._schedule_save()

    def update_fab_pos(self):
        h=32
        if self.sub_buttons.isVisible():h=32+6+120+6+(4*32)+(3*6)+10
        self.fab_container.setFixedSize(32,h)
        self.fab_container.move(self.width()-52,self.height()-h-20)

    def ensure_mpv_running(self):
        if not os.path.exists(self.socket_path):subprocess.Popen(["mpv","--idle",f"--input-ipc-server={self.socket_path}"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)

    def refresh_sockets(self):
        if self.is_probing_sockets:return
        self.is_probing_sockets=True
        def _bg_probe():
            try:
                new_sockets=[]
                for s in sorted(glob.glob("/dev/shm/mpvsocket*")+glob.glob("/tmp/mpvsocket*")):
                    title_res=self.send_command({"command":["get_property","media-title"]},path=s)
                    new_sockets.append((s,title_res.get("data") if (title_res and title_res.get("data")) else os.path.basename(s)))
                self.signals.sockets_refreshed.emit(new_sockets)
            finally:self.is_probing_sockets=False
        threading.Thread(target=_bg_probe,daemon=True).start()

    def _apply_socket_refresh(self,new_list):self.available_sockets=new_list

    def send_command(self,cmd,timeout=0.5,path=None):
        try:
            with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as c:
                c.settimeout(timeout)
                c.connect(path or self.socket_path)
                payload=dict(cmd)
                payload["request_id"]=999
                c.sendall(json.dumps(payload).encode()+b"\n")
                c.setblocking(False)
                res=b""
                while True:
                    r,_,_=select.select([c],[],[],timeout)
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
        cdef bint ps
        cdef str cur_grp,cp,fn,nm,grp
        cdef list items=[]
        cdef list move_cmds=[]
        cdef dict gc={}
        try:
            results=self.send_commands_batch_read([{"command":["get_property","playlist"]},{"command":["get_property","path"]},{"command":["get_property","pause"]}])
            res=results[0] if results else None
            curr=results[1] if results else None
            pause_res=results[2] if results else None
            cp=(curr.get("data","") if curr else "")
            ps=(pause_res.get("data",False) if pause_res else False)
            if not res or "data" not in res:
                self.signals.finished.emit({},[]," ",False)
                return
            with self.lock:fc=set(self.favorites)
            url_to_group=self.url_to_group
            url_to_name=self.url_to_name
            m3u_groups=self.m3u_groups
            _normalize=self._normalize
            _get_nkey=self._get_nkey
            self.last_mpv_cnt=len(res["data"])
            for idx,entry in enumerate(res["data"]):
                fn=entry.get("filename","")
                nm=(url_to_name.get(fn) or entry.get("title") or os.path.basename(fn) or "Unknown").strip()
                grp=url_to_group.get(fn) or m3u_groups.get(nm) or m3u_groups.get(_normalize(nm)) or "Uncategorized"
                gc[grp]=gc.get(grp,0)+1
                items.append(PlaylistItem(nm,fn,idx,grp,_get_nkey(nm)))
            cur_grp=self.current_group
            sm=self.sort_mode
            if sm!=2:
                cur_grp_all=(cur_grp=="All")
                cur_grp_fav=(cur_grp=="★ Favorites")
                def sort_key(x):
                    in_fav=(x.name in fc)
                    tier=-((2 if in_fav else 0)+(1 if (cur_grp_all or (cur_grp_fav and in_fav) or x.group==cur_grp) else 0))
                    return (tier,x.nkey_rev if sm==1 else x.nkey,x.filename)
                items.sort(key=sort_key)
            n=len(items)
            if n>0:
                target_state=[it.orig_idx for it in items]
                current_mpv_state=list(range(n))
                # Use a position map to avoid O(N) search in each iteration
                pos_map={val:i for i,val in enumerate(current_mpv_state)}
                for i in range(n):
                    target=target_state[i]
                    if current_mpv_state[i]!=target:
                        current_pos=pos_map[target]
                        move_cmds.append({"command":["playlist-move",current_pos,i]})
                        # Update our local simulation of mpv state
                        # Note: pop and insert are still O(N), but avoiding .index() is a huge gain.
                        val=current_mpv_state.pop(current_pos)
                        current_mpv_state.insert(i,val)
                        # Only update map for shifted items
                        start=min(i,current_pos)
                        end=max(i,current_pos)
                        for j in range(start,end+1):
                            pos_map[current_mpv_state[j]]=j
            if move_cmds and self._playlist_needs_sort:
                self.send_commands_batch(move_cmds)
                self._playlist_needs_sort=False
                for i in range(n):
                    items[i].orig_idx=i
            self.signals.finished.emit(gc,items,cp,ps)
        except Exception:
            with self.update_lock:self.is_updating=False

    def _finalize_update(self,group_counts,full_sorted,curr_path,is_paused):
        self.full_list=full_sorted
        self.group_counts=group_counts
        # Ensure current group is valid for the new playlist
        if self.current_group not in group_counts and self.current_group not in ("All","★ Favorites"):
            self.current_group="All"
        # ── resume last position BEFORE building the list ─────────────────
        # so filter_playlist already knows the correct current file
        if not self.resume_done and self.last_file:
            for item in full_sorted:
                if item.filename==self.last_file:
                    self.send_command({"command":["set_property","playlist-pos",item.orig_idx]})
                    self.send_command({"command":["set_property","pause",True]})
                    self.resume_done=True
                    curr_path=item.filename
                    is_paused=True
                    break
        self.current_playing_filename=curr_path or ""
        self.is_paused=is_paused
        self.filter_playlist()
        with self.update_lock:self.is_updating=False

    def show_group_menu(self):
        menu=QMenu(self)
        with self.lock:fc=set(self.favorites)
        f_count=sum(1 for x in self.full_list if x.name in fc)
        cur=self.current_group
        for gn,c in [("All",len(self.full_list)),("★ Favorites",f_count)]:
            lbl=f"• {gn} ({c})" if gn==cur else f"{gn} ({c})"
            menu.addAction(lbl).triggered.connect(lambda chk=False,n=gn:self.set_active_group(n))
        menu.addSeparator()
        for g in sorted(self.group_counts.keys()):
            lbl=f"• {g} ({self.group_counts[g]})" if g==cur else f"{g} ({self.group_counts[g]})"
            menu.addAction(lbl).triggered.connect(lambda chk=False,n=g:self.set_active_group(n))
        menu.exec(self.group_btn.mapToGlobal(QPoint(0,28)))

    def set_active_group(self,name):
        self.current_group=name
        self.save_all_data()
        self.update_playlist()

    def show_burger_menu(self):
        menu=QMenu(self)
        sort_labels={0:"Sort: A-Z",1:"Sort: Z-A"}
        current_sort_label=sort_labels.get(self.sort_mode,"Sort: A-Z")
        for l,cb in [("Open Playlist",self.on_load_clicked),("Load URL",self.on_load_url_clicked),(current_sort_label,self.toggle_sort),("Refresh",self.on_refresh_clicked),("Load EPG",self.on_load_epg_clicked)]:
            menu.addAction(l).triggered.connect(lambda chk=False,f=cb:f())
        menu.addSeparator()
        for l,state,cb in [("Show FAB",self.show_fab_enabled,self.toggle_fab_v),("Show Logos on Hover",self.show_logos_enabled,self.toggle_logos_v)]:
            mi=menu.addAction(l)
            mi.setCheckable(True)
            mi.setChecked(state)
            mi.triggered.connect(cb)
        menu.addSeparator()
        sm=menu.addMenu("Select Player")
        for p,l in self.available_sockets:
            sm.addAction(f"✔ {l}" if p==self.socket_path else l).triggered.connect(lambda chk=False,path=p:self.switch_socket(path))
        menu.addSeparator()
        menu.addAction("Clear Playlist").triggered.connect(lambda chk=False:self.on_clear_clicked())
        menu.exec(self.burger_btn.mapToGlobal(QPoint(0,28)))

    def toggle_fab_v(self,chk):
        self.show_fab_enabled=chk
        self.fab_container.setVisible(chk)
        if chk:self.update_fab_pos()
        self.save_all_data()

    def toggle_logos_v(self,chk):
        self.show_logos_enabled=chk
        if not chk:self.logo_label.hide()
        self.save_all_data()

    def switch_socket(self,p):
        self.socket_path=p
        self.update_playlist()

    def filter_playlist(self):
        self.list_model.clear()
        q=self.search_entry.text().lower().strip()
        si=None
        with self.lock:fc=set(self.favorites)
        show_all=(self.current_group=="All")
        show_favs=(self.current_group=="★ Favorites")
        cur_grp=self.current_group
        cp=self.current_playing_filename
        ps=self.is_paused
        bold_font=QFont()
        bold_font.setBold(True)
        playing_bg=QColor("#3584e4")
        playing_fg=QColor("#ffffff")
        items_to_add=[]
        have_epg=bool(self.epg_data)
        for i in self.full_list:
            nm=i.name
            grp=i.group
            idx=i.orig_idx
            fn=i.filename
            isf=(nm in fc)
            if not show_all:
                if show_favs and not isf:continue
                if not show_favs and not isf and grp!=cur_grp:continue
            if q and q not in i.name_lower:continue
            isp=(fn==cp)
            dnm=(f"{'⏸ ' if ps else '▶ '}" if isp else "")+(f"★ {nm}" if isf else nm)
            qi=QStandardItem(dnm)
            qi.setData(idx,self.USER_ROLE)
            qi.setData(nm,self.RAW_NAME_ROLE)
            qi.setData(fn,self.FILENAME_ROLE)
            qi.setData(isp,self.IS_PLAYING_ROLE)
            # EPG data ────────────────────────────────────────────────────
            if have_epg:
                tvg_id=self.url_to_tvgid.get(fn)
                if tvg_id:
                    title,prog,rem=self.get_current_programme(tvg_id)
                    if title:
                        qi.setData((title,prog,rem),self.EPG_ROLE)
            if isp:
                qi.setFont(bold_font)
                qi.setBackground(playing_bg)
                qi.setForeground(playing_fg)
                si=qi
            items_to_add.append(qi)
        if items_to_add:
            self.list_model.invisibleRootItem().appendRows(items_to_add)
        if si:
            sidx=self.list_model.indexFromItem(si)
            self.tree_view.selectionModel().setCurrentIndex(sidx,QItemSelectionModel.ClearAndSelect)
            self.tree_view.scrollTo(sidx,QAbstractItemView.PositionAtCenter)

    def update_now_playing(self):
        results=self.send_commands_batch_read([{"command":["get_property","path"]},{"command":["get_property","pause"]},{"command":["get_property","media-title"]},{"command":["get_property","playlist-count"]}])
        if not results:return
        path_res,pause_res,title_res,count_res=results[0],results[1],results[2],results[3]
        new_path=path_res.get("data","") if path_res else ""
        new_pause=pause_res.get("data",False) if pause_res else False
        new_count=count_res.get("data",-1) if count_res else -1
        need_full_update=(new_count>=0 and new_count!=self.last_mpv_cnt)
        path_changed=(new_path!=self.current_playing_filename)
        pause_changed=(new_pause!=self.is_paused)
        # Also trigger update if current path is NOT in our list (out of sync)
        if not need_full_update and new_path and not any(x.filename==new_path for x in self.full_list):
            need_full_update=True
        if need_full_update:
            self.current_playing_filename=new_path
            self.is_paused=new_pause
            self.update_playlist()
        elif path_changed or pause_changed:
            self.current_playing_filename=new_path
            self.is_paused=new_pause
            self._update_playing_state_ui()
        if title_res and "data" in title_res:self.setWindowTitle(str(title_res['data']) or "MPV")

    def _update_playing_state_ui(self):
        with self.lock:fc=set(self.favorites)
        cp=self.current_playing_filename
        ps=self.is_paused
        # Map filename to PlaylistItem instead of name to avoid ambiguity
        file_to_item={x.filename:x for x in self.full_list}
        no_brush=QBrush()
        plain_font=QFont()
        si=None
        for r in range(self.list_model.rowCount()):
            item=self.list_model.item(r)
            fn=item.data(self.FILENAME_ROLE)
            nm=item.data(self.RAW_NAME_ROLE)
            match=file_to_item.get(fn)
            if not match:continue
            isp=(fn==cp)
            isf=(nm in fc)
            dnm=(f"{'⏸ ' if ps else '▶ '}" if isp else "")+(f"★ {nm}" if isf else nm)
            if item.text()!=dnm:item.setText(dnm)
            has_bg=(item.background().style()!=Qt.NoBrush)
            if isp:
                si=item
                if not has_bg:
                    f=QFont(); f.setBold(True)
                    item.setFont(f)
                    item.setBackground(QColor("#3584e4"))
                    item.setForeground(QColor("#ffffff"))
            elif not isp and has_bg:
                item.setFont(plain_font)
                item.setBackground(no_brush)
                item.setForeground(no_brush)
            item.setData(isp,self.IS_PLAYING_ROLE)
        if si:
            sidx=self.list_model.indexFromItem(si)
            self.tree_view.selectionModel().setCurrentIndex(sidx,QItemSelectionModel.ClearAndSelect)
            self.tree_view.scrollTo(sidx,QAbstractItemView.PositionAtCenter)

    def toggle_sort(self):
        self.sort_mode=1 if self.sort_mode==0 else 0
        self._playlist_needs_sort=True
        self.save_all_data()
        self.update_playlist()

    def on_refresh_clicked(self):
        if self.last_playlist_path:
            pr=self.send_command({"command":["get_property","path"]})
            if pr and pr.get("data"):
                self.last_file=pr["data"]
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
        new_groups={}
        new_url={}
        new_logos={}
        new_url_to_name={}
        new_url_to_tvgid={}
        lg="Uncategorized"
        last_name=""
        last_tvgid=""
        for line in lines:
            line=line.strip()
            if line.startswith("#EXTINF"):
                m=re_group.search(line)
                logo=re_logo.search(line)
                nm=re_name.search(line)
                tvg=re_tvgname.search(line)
                tid=re_tvgid.search(line)
                lg=m.group(1) if m else "Uncategorized"
                last_name=""
                last_tvgid=tid.group(1).strip() if tid else ""
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
                last_name=""
                last_tvgid=""
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
                    QTimer.singleShot(8000,lambda p=temp_m3u:os.remove(p) if os.path.exists(p) else None)
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
        QTimer.singleShot(1500,self.update_playlist)

    def auto_load_last_m3u(self):
        if self.last_playlist_path:
            is_remote=self.last_playlist_path.startswith(('http://','https://','ftp://'))
            if is_remote or os.path.exists(self.last_playlist_path):
                self.load_playlist_file(self.last_playlist_path)
                return
        self.update_playlist()

    def dragEnterEvent(self,e):e.acceptProposedAction() if e.mimeData().hasUrls() else e.ignore()
    def dragMoveEvent(self,e):e.acceptProposedAction() if e.mimeData().hasUrls() else e.ignore()
    def dropEvent(self,e):
        urls=e.mimeData().urls()
        if urls:
            for idx,u in enumerate(urls):
                p=u.toLocalFile() if u.isLocalFile() else u.toString()
                self.load_playlist_file(p,append=(idx>0))
            e.acceptProposedAction()

    def on_load_clicked(self):
        p,_=QFileDialog.getOpenFileName(self,"Playlist","","All (*)")
        if p:self.load_playlist_file(p)

    def on_load_url_clicked(self):
        url,ok=QInputDialog.getText(self,"Load URL","Enter URL:")
        if ok and url:self.load_playlist_file(url)

    def on_clear_clicked(self):
        self.send_command({"command":["stop"]})
        self.send_command({"command":["playlist-clear"]})
        self.m3u_groups,self.url_to_group,self.m3u_logos,self.logo_cache,self.url_to_name={},{},{},{},{}
        self.url_to_tvgid={}
        self.update_playlist()

    def on_right_click(self,pos):
        idx=self.tree_view.indexAt(pos)
        if idx.isValid():
            name=self.list_model.itemFromIndex(idx).data(self.RAW_NAME_ROLE)
            with self.lock:
                if name in self.favorites:self.favorites.discard(name)
                else:self.favorites.add(name)
            self.save_all_data()
            self.update_playlist()

    def on_row_activated(self,idx):
        oi=idx.data(self.USER_ROLE)
        if oi is not None:
            res=self.send_command({"command":["get_property","playlist-pos"]})
            if res and res.get("data")==oi:self.send_command({"command":["playlist-play-index",oi]})
            else:self.send_command({"command":["set_property","playlist-pos",oi]})
            self.send_command({"command":["set_property","pause",False]})

    def load_all_data(self):
        try:
            if os.path.exists(self.config_file):
                with open(self.config_file,"r",encoding="utf-8") as f:
                    c=json.load(f)
                    self.move(c.get("x",100),c.get("y",100))
                    self.resize(c.get("w",200),c.get("h",750))
                    self.current_group=c.get("current_group","All")
                    self.last_file=c.get("last_playing","")
                    self.favorites=set(c.get("favorites",[]))
                    self.last_playlist_path=c.get("last_playlist_path","")
                    self.sort_mode=c.get("sort_mode",0)
                    self.show_fab_enabled=c.get("show_fab",True)
                    self.show_logos_enabled=c.get("show_logos",True)
                    self.epg_path=c.get("epg_path","")
        except:pass

    def save_all_data(self):
        try:
            pr=self.send_command({"command":["get_property","path"]})
            cp=pr.get("data","") if pr else self.last_file
            with self.lock:
                with open(self.config_file,"w",encoding="utf-8") as f:
                    json.dump({"x":self.x(),"y":self.y(),"w":self.width(),"h":self.height(),"current_group":self.current_group,"last_playing":cp,"favorites":list(self.favorites),"last_playlist_path":self.last_playlist_path,"sort_mode":self.sort_mode,"show_fab":self.show_fab_enabled,"show_logos":self.show_logos_enabled,"epg_path":self.epg_path},f)
        except:pass

    def closeEvent(self,event):
        self.save_all_data()
        self.logo_label.close()
        super().closeEvent(event)

if __name__=="__main__":
    app=QApplication(sys.argv)
    win=MPVQtManager()
    win.show()
    # Re-load EPG from saved path (after playlist is loaded in auto_load_last_m3u)
    if win.epg_path:
        QTimer.singleShot(3000,lambda:win.load_epg_file(win.epg_path))
    sys.exit(app.exec())
