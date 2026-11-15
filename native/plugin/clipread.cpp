#include "clipread.h"

#include <QPointer>
#include <QProcess>
#include <QTimer>

#include <memory>

#include <signal.h>
#include <sys/prctl.h>

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

void clipboardMarked(QObject* owner, int timeoutMs, bool emptyIsMarked, std::function<void(bool marked)> done)
{
	auto* proc = new QProcess;
	QPointer<QObject> target(owner);
	auto* timer = new QTimer(proc);
	timer->setSingleShot(true);
	QObject::connect(timer, &QTimer::timeout, proc, [proc] { proc->kill(); });
	QObject::connect(proc, &QProcess::finished, proc, [proc, target, done, emptyIsMarked](int code, QProcess::ExitStatus status) {
		constexpr qint64 cap = 64 * 1024;
		const QByteArray types = proc->read(cap + 1);
		proc->deleteLater();
		if (!target)
			return;
		// wl-paste exits 1 with nothing on the clipboard.
		const bool told = status == QProcess::NormalExit && (code == 0 || (code == 1 && !emptyIsMarked)) && types.size() <= cap;
		done(!told || types.split('\n').contains("x-kde-passwordManagerHint"));
	});
	QObject::connect(proc, &QProcess::errorOccurred, proc, [proc, target, done](QProcess::ProcessError err) {
		if (err != QProcess::FailedToStart)
			return;
		proc->deleteLater();
		if (target)
			done(true);
	});
	proc->setStandardInputFile(QProcess::nullDevice());
	proc->setStandardErrorFile(QProcess::nullDevice());
	proc->start(QStringLiteral("wl-paste"), {QStringLiteral("--list-types")});
	timer->start(timeoutMs);
}

QProcess* watchClipboard(QObject* owner, std::function<void(bool first, bool empty)> changed,
                         std::function<void()> ended)
{
	auto* proc = new QProcess;
	auto first = std::make_shared<bool>(true);
	QPointer<QObject> target(owner);
	QObject::connect(proc, &QProcess::readyReadStandardOutput, proc, [proc, first, target, changed] {
		// One short word per change; a longer line is cut into pieces, each counting as a change.
		while (target && proc->canReadLine()) {
			const QByteArray state = proc->readLine(64).trimmed();
			const bool isFirst = *first;
			*first = false;
			changed(isFirst, state == "nil" || state == "clear");
		}
	});
	const auto over = [proc, target, ended] {
		proc->deleteLater();
		if (target)
			ended();
	};
	QObject::connect(proc, &QProcess::finished, proc, over);
	QObject::connect(proc, &QProcess::errorOccurred, proc, [over](QProcess::ProcessError err) {
		if (err == QProcess::FailedToStart)
			over();
	});
	proc->setStandardInputFile(QProcess::nullDevice());
	proc->setStandardErrorFile(QProcess::nullDevice());
	// It would outlive a window that crashed, watching for nobody.
	proc->setChildProcessModifier([] { prctl(PR_SET_PDEATHSIG, SIGTERM); });
	proc->start(QStringLiteral("wl-paste"),
	            {QStringLiteral("--watch"), QStringLiteral("printenv"), QStringLiteral("CLIPBOARD_STATE")});
	return proc;
}

void stopClipboardWatch(QProcess* watch)
{
	if (!watch)
		return;
	watch->disconnect();
	QObject::connect(watch, &QProcess::finished, watch, &QObject::deleteLater);
	if (watch->state() == QProcess::NotRunning)
		watch->deleteLater();
	else
		watch->kill();
}

} // namespace oma
