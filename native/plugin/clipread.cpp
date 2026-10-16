#include "clipread.h"

#include <QPointer>
#include <QProcess>
#include <QTimer>

#include <memory>

namespace oma
{

void readClipboard(QObject* owner, qsizetype maxBytes, int timeoutMs, bool primary,
                   std::function<void(bool ok, const QByteArray& data)> done)
{
	auto* proc = new QProcess;
	auto data = std::make_shared<QByteArray>();
	auto tooLarge = std::make_shared<bool>(false);
	QPointer<QObject> target(owner);
	auto* timer = new QTimer(proc);
	timer->setSingleShot(true);

	QObject::connect(timer, &QTimer::timeout, proc, [proc, timeoutMs] {
		qWarning("omaremote: wl-paste took more than %d ms; nothing pasted", timeoutMs);
		proc->kill();
	});
	QObject::connect(proc, &QProcess::readyReadStandardOutput, proc, [proc, data, tooLarge, maxBytes] {
		if (*tooLarge)
			return;
		*data += proc->readAllStandardOutput();
		if (data->size() > maxBytes) {
			qWarning("omaremote: clipboard holds more than %lld bytes; nothing pasted",
				static_cast<long long>(maxBytes));
			*tooLarge = true;
			data->clear();
			proc->kill();
		}
	});
	QObject::connect(proc, &QProcess::finished, proc,
		[proc, data, tooLarge, target, done](int code, QProcess::ExitStatus status) {
			proc->deleteLater();
			if (!target)
				return;
			bool ok = status == QProcess::NormalExit && code == 0 && !*tooLarge;
			done(ok, ok ? *data : QByteArray());
		});
	// Not started (no wl-paste): finished never comes.
	QObject::connect(proc, &QProcess::errorOccurred, proc, [proc, target, done](QProcess::ProcessError err) {
		if (err != QProcess::FailedToStart)
			return;
		qWarning("omaremote: wl-paste not found (package wl-clipboard); nothing pasted");
		proc->deleteLater();
		if (target)
			done(false, QByteArray());
	});

	QStringList args{QStringLiteral("--no-newline"), QStringLiteral("--type"), QStringLiteral("text")};
	if (primary)
		args.prepend(QStringLiteral("--primary"));
	proc->setStandardInputFile(QProcess::nullDevice());
	proc->setStandardErrorFile(QProcess::nullDevice());
	proc->start(QStringLiteral("wl-paste"), args);
	timer->start(timeoutMs);
}

} // namespace oma
