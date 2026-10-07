#pragma once

#include <QImage>
#include <QQuickItem>
#include <QSet>
#include <QSocketNotifier>
#include <QTimer>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

#include <deque>

class QSGTexture;

// Shows one remote session (omaremote-rdp or omaremote-vnc, same protocol) inside the window and
// forwards input to it.
//
// The session process owns the connection; this item attaches to its Unix socket, maps the
// framebuffer it is handed, and redraws the damage it reports. Detaching (closing the tab view,
// quitting the app) leaves the session running, and attaching again picks it up where it was.
class RdpView : public QQuickItem
{
	Q_OBJECT
	QML_ELEMENT

	Q_PROPERTY(QString socketPath READ socketPath WRITE setSocketPath NOTIFY socketPathChanged)
	// detached, connecting, connected, ended, failed
	Q_PROPERTY(QString state READ state NOTIFY stateChanged)
	Q_PROPERTY(int exitCode READ exitCode NOTIFY stateChanged)
	Q_PROPERTY(bool attached READ attached NOTIFY attachedChanged)
	Q_PROPERTY(QSize remoteSize READ remoteSize NOTIFY remoteSizeChanged)
	// A question the session is waiting on: {kind: "cert"|"auth", ...}; empty when none.
	Q_PROPERTY(QVariantMap prompt READ prompt NOTIFY promptChanged)
	// Desktop scale to ask for, in percent; 0 follows the window's device pixel ratio.
	Q_PROPERTY(int desktopScale READ desktopScale WRITE setDesktopScale NOTIFY desktopScaleChanged)
	// When false the remote desktop keeps its size and the picture is scaled to the item.
	Q_PROPERTY(bool followSize READ followSize WRITE setFollowSize NOTIFY followSizeChanged)

public:
	explicit RdpView(QQuickItem* parent = nullptr);
	~RdpView() override;

	QString socketPath() const { return m_socketPath; }
	void setSocketPath(const QString& path);
	QString state() const { return m_state; }
	int exitCode() const { return m_exitCode; }
	bool attached() const { return m_fd >= 0; }
	QSize remoteSize() const { return m_image.size(); }
	QVariantMap prompt() const { return m_prompt; }
	int desktopScale() const { return m_desktopScale; }
	void setDesktopScale(int scale);
	bool followSize() const { return m_followSize; }
	void setFollowSize(bool follow);

	Q_INVOKABLE void answerCertificate(int answer);
	Q_INVOKABLE void answerCredentials(const QString& user, const QString& domain, const QString& password);
	Q_INVOKABLE void cancelPrompt();
	Q_INVOKABLE void sendCtrlAltDel();
	Q_INVOKABLE void disconnectSession();
	Q_INVOKABLE void releaseAllKeys();

signals:
	void socketPathChanged();
	void stateChanged();
	void attachedChanged();
	void remoteSizeChanged();
	void promptChanged();
	void desktopScaleChanged();
	void followSizeChanged();

protected:
	QSGNode* updatePaintNode(QSGNode* old, UpdatePaintNodeData*) override;
	void geometryChange(const QRectF& newGeometry, const QRectF& oldGeometry) override;
	void itemChange(ItemChange change, const ItemChangeData& value) override;
	void keyPressEvent(QKeyEvent* event) override;
	void keyReleaseEvent(QKeyEvent* event) override;
	void mousePressEvent(QMouseEvent* event) override;
	void mouseReleaseEvent(QMouseEvent* event) override;
	void mouseMoveEvent(QMouseEvent* event) override;
	void hoverMoveEvent(QHoverEvent* event) override;
	void wheelEvent(QWheelEvent* event) override;
	void focusInEvent(QFocusEvent* event) override;
	void focusOutEvent(QFocusEvent* event) override;

private:
	void tryAttach();
	void detach();
	void onReadable();
	void handleLine(const QByteArray& line);
	void send(const QByteArray& line);
	void mapFrame(int fd, int w, int h, int stride);
	void unmapFrame();
	void setState(const QString& state, int code = 0);
	void scheduleSize();
	void sendSize();
	void sendClipboard();
	QRectF imageRect() const;
	QPoint toRemote(const QPointF& p) const;
	qreal devicePixelRatio() const;

	QString m_socketPath;
	QString m_state = QStringLiteral("detached");
	int m_exitCode = 0;
	int m_fd = -1;
	QSocketNotifier* m_notifier = nullptr;
	QByteArray m_inbuf;
	std::deque<int> m_fds;
	QTimer m_attachTimer;
	QTimer m_sizeTimer;

	void* m_map = nullptr;
	size_t m_mapSize = 0;
	QImage m_image;
	bool m_dirty = false;

	QVariantMap m_prompt;
	int m_desktopScale = 0;
	bool m_followSize = true;
	QSet<quint32> m_pressed;
	QHash<quint32, QCursor> m_cursors;
	QString m_lastClip;
	Qt::MouseButtons m_buttons;
};
