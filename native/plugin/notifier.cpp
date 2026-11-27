#include "notifier.h"

#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QVariantMap>

namespace {
const QString Service = QStringLiteral("org.freedesktop.Notifications");
const QString Path = QStringLiteral("/org/freedesktop/Notifications");
const QString Interface = QStringLiteral("org.freedesktop.Notifications");
constexpr int MaxTitle = 256, MaxBody = 4096, MaxShowing = 64;

// Plain text, whatever the server makes of markup: no &, < or >, but look-alikes (‹ › ＆). Escaping is
// not enough: Omarchy's shell decodes entities (three passes) before it escapes, then lets <b>, <a
// href> and the like through, so an escaped tag from the remote side came back as a working link
// with a label of its choosing. No control characters but line breaks and tabs (C0, DEL, C1), no
// bidirectional controls (a right-to-left override flips how a toast reads); at most `max` characters.
QString plain(const QString& text, int max)
{
	QString out;
	for (const QChar c : text.left(max))
	{
		const char16_t u = c.unicode();
		if ((u < 0x20 && u != '\n' && u != '\t') || (u >= 0x7f && u <= 0x9f))
			continue;
		if ((u >= 0x202a && u <= 0x202e) || (u >= 0x2066 && u <= 0x2069) || u == 0x200e || u == 0x200f || u == 0x061c)
			continue;
		if (u == '&')
			out += QChar(0xff06);
		else if (u == '<')
			out += QChar(0x2039);
		else if (u == '>')
			out += QChar(0x203a);
		else
			out += c;
	}
	return out;
}
}

Notifier::Notifier(QObject* parent) : QObject(parent)
{
	QDBusConnection bus = QDBusConnection::sessionBus();
	bus.connect(Service, Path, Interface, QStringLiteral("ActionInvoked"), this,
	            SLOT(onActionInvoked(uint, QString)));
	bus.connect(Service, Path, Interface, QStringLiteral("NotificationClosed"), this, SLOT(onClosed(uint, uint)));
}

void Notifier::notify(const QString& key, const QString& title, const QString& body, int expireMs)
{
	if (m_keys.size() >= MaxShowing)
		return;
	QDBusMessage call = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("Notify"));
	QVariantMap hints;
	hints.insert(QStringLiteral("desktop-entry"), QStringLiteral("omaremote"));
	call << QStringLiteral("OMARemote") << uint(0) << QStringLiteral("omaremote") << plain(title, MaxTitle)
	     << plain(body, MaxBody) << QStringList{ QStringLiteral("default"), QStringLiteral("Show") } << hints
	     << qint32(expireMs < -1 ? -1 : expireMs);
	auto* watcher = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(call), this);
	connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, watcher, key] {
		QDBusPendingReply<uint> reply = *watcher;
		if (reply.isValid() && reply.value())
			m_keys.insert(reply.value(), key);
		watcher->deleteLater();
	});
}

void Notifier::close(const QString& key)
{
	for (auto it = m_keys.begin(); it != m_keys.end();)
	{
		if (it.value() != key)
		{
			++it;
			continue;
		}
		QDBusMessage call = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("CloseNotification"));
		call << it.key();
		QDBusConnection::sessionBus().asyncCall(call);
		it = m_keys.erase(it);
	}
}

void Notifier::onActionInvoked(uint id, const QString& action)
{
	// Only ours: every client on the bus hears every ActionInvoked.
	const auto it = m_keys.constFind(id);
	if (it == m_keys.constEnd() || action != QLatin1String("default"))
		return;
	emit activated(it.value());
}

void Notifier::onClosed(uint id, uint)
{
	m_keys.remove(id);
}
