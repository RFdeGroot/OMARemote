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

// Plain text, whatever the server makes of markup: &, < and > as entities, no control characters
// but line breaks and tabs, at most `max` characters.
QString plain(const QString& text, int max, bool escape)
{
	QString out;
	for (const QChar c : text.left(max))
	{
		if (c.unicode() < 0x20 && c != '\n' && c != '\t')
			continue;
		if (c.unicode() == 0x7f)
			continue;
		if (escape && c == '&')
			out += QStringLiteral("&amp;");
		else if (escape && c == '<')
			out += QStringLiteral("&lt;");
		else if (escape && c == '>')
			out += QStringLiteral("&gt;");
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
	auto* caps = new QDBusPendingCallWatcher(
		bus.asyncCall(QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("GetCapabilities"))), this);
	connect(caps, &QDBusPendingCallWatcher::finished, this, [this, caps] {
		QDBusPendingReply<QStringList> reply = *caps;
		if (reply.isValid())
			m_markup = reply.value().contains(QStringLiteral("body-markup"));
		caps->deleteLater();
	});
}

void Notifier::notify(const QString& key, const QString& title, const QString& body, int expireMs)
{
	if (m_keys.size() >= MaxShowing)
		return;
	QDBusMessage call = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("Notify"));
	QVariantMap hints;
	hints.insert(QStringLiteral("desktop-entry"), QStringLiteral("omaremote"));
	call << QStringLiteral("OMARemote") << uint(0) << QStringLiteral("omaremote") << plain(title, MaxTitle, false)
	     << plain(body, MaxBody, m_markup) << QStringList{ QStringLiteral("default"), QStringLiteral("Show") } << hints
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
