# playlistmanager for mpv
a python playlistmanager for MPV

it uses ipc socket

start it like ....

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

![alt text](https://github.com/m0g13r/playlistmanager-for-mpv/blob/8882484ac4c6c48858b5cc59c64084c3833c9ec9/pic.png)
