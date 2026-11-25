import QtQuick
import QtTest

// Run by tests/test_scrollhint.py through qmltestrunner (offscreen), with ScrollHint and its
// stand-ins on the import path: the pointer on the bar keeps it shown, and the thumb drags.
Item {
    id: root
    width: 400
    height: 300

    ListView {
        id: list
        x: 20
        y: 50
        width: 180
        height: 200
        model: 100
        delegate: Text { text: "row " + index; height: 20 }
        ScrollHint { id: hint; flickable: list }
    }

    TestCase {
        name: "ScrollHint"
        when: windowShown

        // Each test from the top, the pointer away and the bar faded out.
        function init() {
            mouseMove(root, 300, 280)
            list.contentY = 0
            tryCompare(hint, "visible", false, 3000)
        }

        function test_the_bar_stays_under_the_pointer_and_drags() {
            mouseMove(root, 300, 280)                        // outside the pane
            tryCompare(hint, "visible", false, 2000)
            mouseMove(list, 90, 100)                         // over the pane
            tryCompare(hint, "shown", true, 1000)
            tryCompare(hint, "opacity", 1, 1000)
            // On the bar itself: shown the whole time, no flicker (it blinked before).
            mouseMove(hint, 3, 10)
            for (let i = 0; i < 20; i++) {
                wait(50)
                compare(hint.shown, true, "faded under the pointer after " + (i * 50) + " ms")
                compare(hint.visible, true)
            }
            // Grab the thumb at the top and drag it down: the list follows.
            compare(list.contentY, 0)
            mousePress(hint, 3, 10)
            mouseMove(hint, 3, hint.height / 2)
            mouseMove(hint, 3, hint.height - 5)
            mouseRelease(hint, 3, hint.height - 5)
            verify(list.contentY > list.contentHeight / 2, "the thumb did not drag: " + list.contentY)
            // Leaving the pane: hidden at once.
            mouseMove(root, 300, 280)
            compare(hint.shown, false)
            tryCompare(hint, "visible", false, 1000)
        }

        function test_leaving_right_after_a_scroll_hides_it_the_same() {
            mouseMove(list, 90, 100)
            tryCompare(hint, "shown", true, 1000)
            list.contentY = 300                              // a scroll while over the pane
            mouseMove(root, 300, 280)
            compare(hint.shown, false, "the scroll kept it shown after the pointer left")
            tryCompare(hint, "visible", false, 1000)
        }

        function test_a_scroll_by_keys_shows_it_a_moment() {
            mouseMove(root, 300, 280)                        // the pointer elsewhere
            tryCompare(hint, "visible", false, 2000)
            list.contentY = 100                              // j/k moving the selection
            compare(hint.shown, true)
            tryCompare(hint, "shown", false, 2000)
        }
    }
}
