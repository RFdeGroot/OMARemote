#pragma once

#include <QImage>
#include <QQuickItem>
#include <QSet>
#include <QSocketNotifier>
#include <QTimer>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

#include "shortcutinhibit.h"
#include "yuvnode.h"

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
	// Every key to the session, Super and Hyprland's shortcuts too, while the picture has the focus
	// (Gliff tabs) and the pointer is over it, as in Gliff's own client. The session keys + Esc
	// (releaseShortcuts) or the release key hand the shortcuts back until the pointer leaves or the
	// picture is clicked.
	Q_PROPERTY(bool captureShortcuts READ captureShortcuts WRITE setCaptureShortcuts NOTIFY captureShortcutsChanged)
	// Whether the compositor's shortcuts are held right now.
	Q_PROPERTY(bool shortcutsCaptured READ shortcutsCaptured NOTIFY shortcutsCapturedChanged)
	// A key that gives them back besides the session keys + Esc: shift+escape, double-escape or none.
	Q_PROPERTY(QString releaseKey MEMBER m_releaseKey NOTIFY releaseKeyChanged)

public:
	explicit RdpView(QQuickItem* parent = nullptr);
	~RdpView() override;

	QString socketPath() const { return m_socketPath; }
	void setSocketPath(const QString& path);
	QString state() const { return m_state; }
	int exitCode() const { return m_exitCode; }
	bool attached() const { return m_fd >= 0; }
	QSize remoteSize() const { return m_gpu ? m_show.size : m_image.size(); }
	QVariantMap prompt() const { return m_prompt; }
	int desktopScale() const { return m_desktopScale; }
	void setDesktopScale(int scale);
	bool followSize() const { return m_followSize; }
	void setFollowSize(bool follow);
	bool captureShortcuts() const { return m_captureShortcuts; }
	void setCaptureShortcuts(bool capture);
	bool shortcutsCaptured() const { return m_inhibit.held(); }

	Q_INVOKABLE void answerCertificate(int answer);
	Q_INVOKABLE void answerCredentials(const QString& user, const QString& domain, const QString& password);
	Q_INVOKABLE void cancelPrompt();
	Q_INVOKABLE void sendCtrlAltDel();
	Q_INVOKABLE void disconnectSession();
	Q_INVOKABLE void releaseAllKeys();
	Q_INVOKABLE void cancelPaste(int job);
	// Hyprland's shortcuts back, while the pointer stays on the picture (the session keys + Esc).
	Q_INVOKABLE void releaseShortcuts();

signals:
	void socketPathChanged();
	void stateChanged();
	void attachedChanged();
	void remoteSizeChanged();
	void promptChanged();
	void desktopScaleChanged();
	void followSizeChanged();
	void captureShortcutsChanged();
	void releaseKeyChanged();
	// A paste from the remote that takes a while (Gliff): bytes so far, the total (0: unknown), what.
	void pasteProgress(int job, double got, double total, const QString& what);
	void pasteDone(int job);
	// A line about the stream, once a second (Gliff: fps, bandwidth, decode time).
	void statsChanged(const QString& text);
	void shortcutsCapturedChanged();

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
	void hoverEnterEvent(QHoverEvent* event) override;
	void hoverLeaveEvent(QHoverEvent* event) override;
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
	void addSurface(const QList<QByteArray>& w);
	void forgetSurfaces();
	void showSurfaces(const QList<QByteArray>& w);
	void sendLater(const QByteArray& line);
	void setState(const QString& state, int code = 0);
	void scheduleSize();
	void sendSize();
	void sendClipboard(bool force = false);
	void updateCapture();
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

	QImage m_image;
	bool m_dirty = false;

	// Gliff pictures as dmabufs (yuvnode.h): the surfaces the session handed over, the newest
	// "show" and whether the render thread took it, and the one it draws (released to the
	// session once a newer one replaces it).
	bool m_gpu = false; // drawing the shown surfaces, not m_image
	bool m_gpuFailed = false; // this GPU could not import them: never ask again
	bool m_nodeGpu = false;
	QHash<quint32, DmabufSurface> m_surfaces;
	quint64 m_surfaceGeneration = 1;
	struct Show
	{
		quint64 seq = 0;
		quint32 main = 0, aux = 0;
		bool dual = false;
		QSize size;
	} m_show;
	bool m_showTaken = true;
	quint64 m_drawnSeq = 0;

	QVariantMap m_prompt;
	int m_desktopScale = 0;
	bool m_followSize = true;
	bool m_captureShortcuts = false;
	bool m_released = false; // the release key gave the shortcuts back; a click or leaving undoes it
	bool m_pointerInside = false; // the shortcuts are taken only with the pointer on the picture
	QString m_releaseKey = QStringLiteral("shift+escape");
	qint64 m_lastEscape = 0; // for double-escape
	ShortcutInhibit m_inhibit;
	QSet<quint32> m_pressed;
	// A key that came with modifiers no modifier key was pressed for (Hyprland's sendshortcut, as
	// Omarchy's Super+V/C/X use): the modifiers sent around it, and a held Super lifted for it.
	// evdev code and keysym of each, by the key's evdev code.
	struct Chord { QList<QPair<quint32, quint32>> added, lifted; };
	QHash<quint32, Chord> m_chords;
	QHash<quint32, QCursor> m_cursors;
	QString m_lastClip;
	Qt::MouseButtons m_buttons;
};
