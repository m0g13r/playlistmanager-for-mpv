# playlistmanager for mpv
a python playlistmanager for MPV

it uses ipc socket

start it like ....

.

mpv --idle --input-ipc-server=/dev/shm/mpvsocket &

while [ ! -S /dev/shm/mpvsocket ]; do sleep 0.1; done

python3 /your path to/playlist_gtk/qt.py

.

for the elf version

mpv --idle --input-ipc-server=/dev/shm/mpvsocket &

while [ ! -S /dev/shm/mpvsocket ]; do sleep 0.1; done

/your path to/playlist_gtk/qt

.

drag and drop

right click = add to Favorites

Toggle Sort - is also sorting the internal playlist

selecting a group from dropdown sets selected group lists on top of internal playlist

.

added cython gcc compiled versions .... it's like a native elf more ore less ;)

.

![alt text](https://raw.githubusercontent.com/m0g13r/playlistmanager-for-mpv/refs/heads/main/pic.png)
