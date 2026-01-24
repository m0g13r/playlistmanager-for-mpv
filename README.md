# playlistmanager-for-mpv
a python playlistmanager for MPV

it uses ipc socket

start it like ....

mpv --idle --input-ipc-server=/tmp/mpvsocket &

while [ ! -S /tmp/mpvsocket ]; do sleep 0.1; done

python3 /your path to/playlist_gtk/qt.py

https://raw.githubusercontent.com/m0g13r/playlistmanager-for-mpv/refs/heads/main/pic.png
