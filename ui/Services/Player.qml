pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Plays voice notes/audio through mpv (QtMultimedia isn't installed on this system).
// Progress is tracked by wall clock, which is accurate enough for a scrubber.
Singleton {
    id: root
    property string currentId: ""
    property real duration: 0
    property real position: 0
    property real speed: 1
    property bool playing: false
    property real _startedAt: 0
    property real _offset: 0

    function play(id, path, secs, from) {
        stop();
        currentId = id;
        duration = secs || 0;
        _offset = from || 0;
        position = _offset;
        _pendingCmd = ["mpv", "--no-video", "--really-quiet", "--no-terminal", "--speed=" + speed, "--start=" + _offset, path];
        _path = path;
        if (!proc.running)
            _launch();
        playing = true;
        _startedAt = Date.now();
    }
    property var _pendingCmd: null
    property string _path: ""
    function _launch() {
        proc.command = _pendingCmd;
        _pendingCmd = null;
        proc.running = true;
        _startedAt = Date.now();
    }
    function stop() {
        _pendingCmd = null;
        if (proc.running)
            proc.signal(15);
        playing = false;
    }
    function toggle(id, path, secs) {
        if (currentId === id && playing) {
            const pos = position;
            stop();
            position = pos;
            return;
        }
        const resume = currentId === id && position > 0 && position < duration - 0.3 ? position : 0;
        play(id, path, secs, resume);
    }
    function cycleSpeed() {
        speed = speed === 1 ? 1.5 : speed === 1.5 ? 2 : 1;
        if (playing) {
            const pos = position;
            play(currentId, _path, duration, pos);
        }
    }

    Process {
        id: proc
        onExited: {
            if (root._pendingCmd) {
                root._launch();
                return;
            }
            if (root.playing) {
                root.playing = false;
                root.position = 0;
            }
        }
    }
    Timer {
        interval: 100
        repeat: true
        running: root.playing
        onTriggered: root.position = Math.min(root.duration || 1e9, root._offset + (Date.now() - root._startedAt) / 1000 * root.speed)
    }
}
