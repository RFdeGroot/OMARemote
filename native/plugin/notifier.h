#pragma once

#include <QHash>
#include <QObject>
#include <QtQml/qqmlregistration.h>

// Desktop notifications over D-Bus (org.freedesktop.Notifications), straight from this process:
// what a program in a terminal asks to show (OSC 9, OSC 777) is the remote side's text, so it never
// goes on a command line (notify-send's argv), and neither title nor body can read as markup: &, <
// and > become look-alikes for every server (escaping is not enough: Omarchy's shell decodes
// entities before it lets tags and links through), control and bidirectional characters are left out.
//
// notify(key, …): key groups notifications (a session id); a click on one emits activated(key);
// close(key) takes back every notification of that key still showing.
class Notifier : public QObject
{
	Q_OBJECT
	QML_ELEMENT

public:
	explicit Notifier(QObject* parent = nullptr);

	// expireMs: -1 the server's default, 0 never, otherwise milliseconds.
	Q_INVOKABLE void notify(const QString& key, const QString& title, const QString& body, int expireMs);
	Q_INVOKABLE void close(const QString& key);

signals:
	void activated(const QString& key);

private slots:
	void onActionInvoked(uint id, const QString& action);
	void onClosed(uint id, uint reason);

private:
	QHash<uint, QString> m_keys; // notification id -> key, while it shows
};
