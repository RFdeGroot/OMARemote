#pragma once

#include <QByteArray>
#include <QObject>

#include <functional>

class QProcess;

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

// Whether a password manager marked what is on the clipboard (x-kde-passwordManagerHint), read with
// wl-paste --list-types under the same limits. Whatever cannot be told (wl-paste missing, stuck, a
// list too long to read) counts as marked, so nothing goes on a guess. emptyIsMarked: an empty
// clipboard counts too, for the check after a read: what was read may be a password cleared since.
void clipboardMarked(QObject* owner, int timeoutMs, bool emptyIsMarked, std::function<void(bool marked)> done);

// Tells owner, in its thread, each time the clipboard changes: wl-paste --watch running printenv, so
// only the state reaches this process and nothing waits on the clipboard's owner. wl-paste does ask
// the owner for the content each time, as any clipboard history does (a wl-copy --paste-once is
// used up by it), into a pipe that printenv closes unread. The first call is what the clipboard
// holds now, not a change (first true). ended is called once if the watch stops by itself (wl-paste
// missing, or a compositor without data-control). Returns the process for stopClipboardWatch.
QProcess* watchClipboard(QObject* owner, std::function<void(bool first, bool empty)> changed,
                         std::function<void()> ended);
void stopClipboardWatch(QProcess* watch);

} // namespace oma
