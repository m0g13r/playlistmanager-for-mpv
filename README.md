# playlistmanager-for-mpv

A high-performance external GUI for mpv written in **Cython**. It communicates with mpv via **IPC socket** to provide a fluid playlist management experience.

## Features

* **IPC Integration:** Fast communication via `/dev/shm/mpvsocket`.
* **Drag and Drop:** Add files or folders directly into the interface.
* **Favorites:** Right-click an entry to add it to your Favorites.
* **Toggle Sort:** Synchronizes the GUI sorting with mpv's internal playlist.
* **Group Management:** Selecting a group from the dropdown moves the selected group's list to the top of the internal playlist.
* **Minimal Overhead:** Built with Cython for maximum performance.

## Preview

![Interface Preview](https://github.com/m0g13r/playlistmanager-for-mpv/blob/8882484ac4c6c48858b5cc59c64084c3833c9ec9/pic.png)

## Dependencies

* **mpv** (compiled with IPC support)
* **GTK3/4** or **Qt5/6** libraries
* **Python 3** environment (for the pre-compiled Cython binaries)

## Usage

Start mpv with the IPC server, wait for the socket, and launch the manager:

```bash
mpv --idle --input-ipc-server=/dev/shm/mpvsocket &

while [ ! -S /dev/shm/mpvsocket ]; do sleep 0.1; done

/path/to/playlist_gtk_qt
