#pragma once

#include <QObject>
#include <QtQml/qqmlregistration.h>

// Keeps text fields away from the clipboard until someone pastes.
//
// Qt's TextInput asks the clipboard for its full text on every clipboard change while it is
// editable (QQuickTextInput::q_canPasteChanged, to keep canPaste current), and pastes whatever it
// holds, however large. On Wayland every such read is a transfer from the app that owns the
// clipboard. guard() cuts the first; paste() is the only way text gets in: wl-paste with a time
// and size limit, cleaned to a single line (omarchy-plugin-marketplace#11361).
class PasteGuard : public QObject
{
	Q_OBJECT
	QML_ELEMENT
	QML_SINGLETON

public:
	using QObject::QObject;

	// Largest paste read (the longest field, 4096 characters, as UTF-8), and how long wl-paste
	// may take.
	static constexpr qsizetype MaxBytes = 16 * 1024;
	static constexpr int TimeoutMs = 2000;

	// Stops field (a TextInput) following clipboard changes. False, with a warning, when there was
	// no such connection to cut: a Qt that renamed the slot needs a look.
	Q_INVOKABLE bool guard(QObject *field);

	// Reads the clipboard (or, with primary, the selection) and puts it in field at the cursor,
	// over the selected text. Asynchronous; nothing happens when the read fails or is too large,
	// and text that would not fit the field's maximumLength is refused whole (tooLong), never cut.
	Q_INVOKABLE void paste(QObject *field, bool primary = false);

	// The text as it goes into a single-line field: no line breaks, tabs or other control
	// characters (a line break becomes a space). Public for the test.
	Q_INVOKABLE static QString clean(const QString &text);

signals:
	void tooLong(QObject *field, int maximum);
};
