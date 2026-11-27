import QtQuick
import QtTest
import OMARemote

// Run by tests/test_search.py through qmltestrunner (offscreen): an RdpView on a fake session
// (@SOCKET@), a middle click on it once attached, then waits for the session to hang up.
Item {
    width: 200
    height: 100

    RdpView {
        id: view
        anchors.fill: parent
        socketPath: "@SOCKET@"
        shareClipboard: true // as an SSH tab
        withholdPasswords: false
    }

    TestCase {
        name: "Primary"
        when: windowShown

        function test_a_middle_click() {
            tryVerify(function () { return view.attached }, 5000)
            wait(300) // the session's first want-primary, before any click, has been read
            mousePress(view, 20, 20, Qt.MiddleButton)
            mouseRelease(view, 20, 20, Qt.MiddleButton)
            tryVerify(function () { return !view.attached }, 10000)
        }
    }
}
