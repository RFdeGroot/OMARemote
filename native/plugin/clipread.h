#pragma once

#include <QByteArray>
#include <QObject>

#include <functional>

// The one way the UI reads the clipboard: wl-paste in a process of its own, with a size and a time
// limit, never QClipboard::text(). Qt's Wayland read waits for the clipboard's owner with no
// overall deadline or byte limit, in the GUI thread, so any app holding the clipboard could stall
// or exhaust OMARemote's window (omarchy-plugin-marketplace#11361, #11850).
namespace oma
{

// Reads the clipboard (or, with primary, the selection) as text and calls done once, in owner's
// thread: ok false (with a warning) when wl-paste is missing, fails, takes longer than timeoutMs or
// gives more than maxBytes. Never called when owner is gone by then.
void readClipboard(QObject* owner, qsizetype maxBytes, int timeoutMs, bool primary,
                   std::function<void(bool ok, const QByteArray& data)> done);

} // namespace oma
