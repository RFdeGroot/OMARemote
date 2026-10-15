#include "pasteguard.h"

#include <QClipboard>
#include <QGuiApplication>
#include <QPointer>
#include <QProcess>
#include <QTimer>
#include <QVariant>

bool PasteGuard::guard(QObject *field)
{
	if (!field)
		return false;
	// Made in QQuickTextInputPrivate::init with qmlobject_connect; a string disconnect finds it
	// by the same signal and slot index.
	bool cut = QObject::disconnect(QGuiApplication::clipboard(), SIGNAL(dataChanged()),
		field, SLOT(q_canPasteChanged()));
	if (!cut)
		qWarning("omaremote: no clipboard connection to cut on %s; Qt may have changed "
			"QQuickTextInput::q_canPasteChanged", field->metaObject()->className());
	return cut;
}

QString PasteGuard::clean(const QString &text)
{
	QString out;
	out.reserve(text.size());
	bool brk = false;
	for (QChar c : text) {
		if (c == u'\n' || c == u'\r') {
			brk = true;
			continue;
		}
		if (brk) {
			if (!out.isEmpty())
				out += u' ';
			brk = false;
		}
		if (c.category() == QChar::Other_Control)
			continue;
		out += c;
	}
	return out;
}

void PasteGuard::paste(QObject *field, bool primary)
{
	if (!field || field->property("readOnly").toBool())
		return;

	auto *proc = new QProcess(this);
	auto *data = new QByteArray;
	QPointer<QObject> target(field);
	auto *timer = new QTimer(proc);
	timer->setSingleShot(true);

	QObject::connect(timer, &QTimer::timeout, proc, [proc] {
		qWarning("omaremote: wl-paste took more than %d ms; nothing pasted", TimeoutMs);
		proc->kill();
	});
	QObject::connect(proc, &QProcess::readyReadStandardOutput, proc, [proc, data] {
		*data += proc->readAllStandardOutput();
		if (data->size() > MaxBytes) {
			qWarning("omaremote: clipboard holds more than %lld bytes; nothing pasted",
				static_cast<long long>(MaxBytes));
			proc->kill();
		}
	});
	QObject::connect(proc, &QProcess::finished, this, [this, proc, data, target](int code, QProcess::ExitStatus status) {
		QString text = clean(QString::fromUtf8(*data));
		bool ok = status == QProcess::NormalExit && code == 0 && data->size() <= MaxBytes;
		delete data;
		proc->deleteLater();
		if (!ok || text.isEmpty() || !target || target->property("readOnly").toBool())
			return;
		int start = target->property("selectionStart").toInt();
		int end = target->property("selectionEnd").toInt();
		int length = target->property("length").toInt();
		int maximum = target->property("maximumLength").toInt();
		// Qt would keep what fits: half a host name looks right and is not.
		if (length - (end - start) + text.size() > maximum) {
			qWarning("omaremote: the paste does not fit the field (at most %d characters); nothing pasted", maximum);
			emit tooLong(target, maximum);
			return;
		}
		if (end > start)
			QMetaObject::invokeMethod(target, "remove", Q_ARG(int, start), Q_ARG(int, end));
		int at = target->property("cursorPosition").toInt();
		QMetaObject::invokeMethod(target, "insert", Q_ARG(int, at), Q_ARG(QString, text));
	});
	// Not started (no wl-paste): finished never comes.
	QObject::connect(proc, &QProcess::errorOccurred, proc, [proc, data](QProcess::ProcessError err) {
		if (err != QProcess::FailedToStart)
			return;
		qWarning("omaremote: wl-paste not found (package wl-clipboard); nothing pasted");
		delete data;
		proc->deleteLater();
	});

	QStringList args{QStringLiteral("--no-newline"), QStringLiteral("--type"), QStringLiteral("text")};
	if (primary)
		args.prepend(QStringLiteral("--primary"));
	proc->setStandardInputFile(QProcess::nullDevice());
	proc->setStandardErrorFile(QProcess::nullDevice());
	proc->start(QStringLiteral("wl-paste"), args);
	timer->start(TimeoutMs);
}
