#pragma once

#include <QCursor>
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
	// Whether this view passes the clipboard between the desktop and the session (the connection's
	// Clipboard switch; Gliff's session process has its own). Off: the clipboard is never read,
	// and text from the session never set.
	Q_PROPERTY(bool shareClipboard READ shareClipboard WRITE setShareClipboard NOTIFY shareClipboardChanged)

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
	bool shareClipboard() const { return m_shareClipboard; }
	void setShareClipboard(bool share);

	// The most clipboard text passed either way, in bytes of UTF-8 (as native/common/link.hpp's
	// kMaxClipBytes), how long reading it may take, and the longest line the session may send.
	static constexpr qsizetype MaxClipBytes = 1024 * 1024;
	static constexpr int ClipTimeoutMs = 2000;
	static constexpr qsizetype MaxLineBytes = 32 * 1024 * 1024;
	// The largest cursor taken (as link.hpp's kMaxCursorSide) and how many are kept: the least
	// recently used one goes first, so a server sending new shapes cannot fill memory.
	static constexpr int MaxCursorSide = 512;
	static constexpr int MaxCursors = 64;
	// The largest desktop mapped (as link.hpp's kMaxFrameSide; addSurface holds to the same).
	static constexpr int MaxFrameSide = 8192;

	Q_INVOKABLE void answerCertificate(int answer);
	Q_INVOKABLE void answerCredentials(const QString& user, const QString& domain, const QString& password);
	Q_INVOKABLE void cancelPrompt();
	Q_INVOKABLE void sendCtrlAltDel();
	Q_INVOKABLE void disconnectSession();
	Q_INVOKABLE void releaseAllKeys();
	Q_INVOKABLE void cancelPaste(int job);
	// A lost SSH connection that is being tried again: try at once, or give it up.
	Q_INVOKABLE void reconnectNow();
	Q_INVOKABLE void cancelReconnect();
	// Hyprland's shortcuts back, while the pointer stays on the picture (the session keys + Esc).
	Q_INVOKABLE void releaseShortcuts();
	Q_INVOKABLE int cachedCursors() const { return int(m_cursors.size()); } // for tests

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
	void shareClipboardChanged();
	// A paste from the remote that takes a while (Gliff): bytes so far, the total (0: unknown), what.
	void pasteProgress(int job, double got, double total, const QString& what);
	void pasteDone(int job);
	// A line about the stream, once a second (Gliff: fps, bandwidth, decode time).
	void statsChanged(const QString& text);
	// SSH trying a lost connection again: phase "wait" (seconds until the next try), "trying",
	// or "off" (back, or given up); attempt counts the tries since the drop.
	void reconnectChanged(const QString& phase, int attempt, int seconds);
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
	void offerClipboard(const QString& text, bool force);
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
	bool m_skipLine = false; // dropping the rest of an overlong line, up to its newline
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
	struct CachedCursor { QCursor cursor; quint64 used = 0; };
	QHash<quint32, CachedCursor> m_cursors;
	quint64 m_cursorClock = 0;
	QString m_lastClip;
	// Text from the session while this view did not have the keyboard: set when it gets it back,
	// dropped when the desktop's clipboard changes first (whichever changed last wins, as Gliff).
	// A server never rewrites the clipboard while the user works elsewhere.
	QString m_heldClip;
	bool m_hasHeldClip = false;
	void applyHeldClip();
	bool m_shareClipboard = false;
	bool m_clipReading = false; // a read is under way; one more follows it when asked meanwhile
	bool m_clipAgain = false;
	bool m_clipAgainForce = false;
	Qt::MouseButtons m_buttons;
};
