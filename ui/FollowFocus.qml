import QtQuick

// Keeps the focused field of a scrolling form in view: Tab walking down a long form scrolls it.
Item {
    id: root
    // The Flickable to scroll; the focused item must be inside its content.
    property Flickable flickable: null
    readonly property Item focused: flickable && flickable.Window.window ? flickable.Window.window.activeFocusItem : null

    onFocusedChanged: {
        if (!flickable || !focused)
            return
        var p = focused
        while (p && p !== flickable.contentItem)
            p = p.parent
        if (!p)
            return
        var top = focused.mapToItem(flickable.contentItem, 0, 0).y
        var margin = 24
        if (top - margin < flickable.contentY)
            flickable.contentY = Math.max(0, top - margin)
        else if (top + focused.height + margin > flickable.contentY + flickable.height)
            flickable.contentY = Math.min(Math.max(0, flickable.contentHeight - flickable.height),
                                          top + focused.height + margin - flickable.height)
    }
}
