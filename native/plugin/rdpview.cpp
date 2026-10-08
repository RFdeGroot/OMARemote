#include "rdpview.h"

#include <QClipboard>
#include <QCursor>
#include <QGuiApplication>
#include <QPixmap>
#include <QQuickWindow>
#include <QSGImageNode>
#include <QSGTexture>

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

// Toggle-key bits of the RDP synchronize event (KBD_SYNC_*).
static constexpr int kSyncScroll = 1, kSyncNum = 2, kSyncCaps = 4;

RdpView::RdpView(QQuickItem* parent) : QQuickItem(parent)
{
	setFlag(ItemHasContents, true);
	setFlag(ItemIsFocusScope, false);
	setAcceptedMouseButtons(Qt::AllButtons);
	setAcceptHoverEvents(true);
	setActiveFocusOnTab(false);

	m_attachTimer.setInterval(300);
	connect(&m_attachTimer, &QTimer::timeout, this, &RdpView::tryAttach);
	m_sizeTimer.setSingleShot(true);
	m_sizeTimer.setInterval(400);
	connect(&m_sizeTimer, &QTimer::timeout, this, &RdpView::sendSize);

	connect(QGuiApplication::clipboard(), &QClipboard::dataChanged, this, [this] {
		if (hasActiveFocus())
			sendClipboard();
	});
}

RdpView::~RdpView()
{
	detach();
	unmapFrame();
}

void RdpView::setSocketPath(const QString& path)
{
	if (path == m_socketPath)
		return;
	detach();
	m_socketPath = path;
	emit socketPathChanged();
	if (!path.isEmpty())
	{
		tryAttach();
		if (m_fd < 0)
			m_attachTimer.start();
	}
}

void RdpView::setDesktopScale(int scale)
{
	if (scale == m_desktopScale)
		return;
	m_desktopScale = scale;
	emit desktopScaleChanged();
	scheduleSize();
}

void RdpView::setFollowSize(bool follow)
{
	if (follow == m_followSize)
		return;
	m_followSize = follow;
	emit followSizeChanged();
	scheduleSize();
}

// ---------------------------------------------------------------- socket

void RdpView::tryAttach()
{
	if (m_fd >= 0 || m_socketPath.isEmpty())
		return;
	const QByteArray path = m_socketPath.toLocal8Bit();
	sockaddr_un addr = {};
	addr.sun_family = AF_UNIX;
	if (static_cast<size_t>(path.size()) >= sizeof(addr.sun_path))
		return;
	memcpy(addr.sun_path, path.constData(), static_cast<size_t>(path.size()));
	const int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
	if (fd < 0)
		return;
	if (::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0)
	{
		close(fd);
		return; // not listening yet; the timer tries again
	}
	m_attachTimer.stop();
	m_fd = fd;
	m_notifier = new QSocketNotifier(fd, QSocketNotifier::Read, this);
	connect(m_notifier, &QSocketNotifier::activated, this, &RdpView::onReadable);
	emit attachedChanged();
	sendSize();
}

void RdpView::detach()
{
	m_attachTimer.stop();
	if (m_fd < 0)
		return;
	releaseAllKeys();
	delete m_notifier;
	m_notifier = nullptr;
	close(m_fd);
	m_fd = -1;
	for (int fd : m_fds)
		close(fd);
	m_fds.clear();
	m_inbuf.clear();
	emit attachedChanged();
}

void RdpView::send(const QByteArray& line)
{
	if (m_fd < 0)
		return;
	QByteArray data = line + '\n';
	qsizetype off = 0;
	while (off < data.size())
	{
		const ssize_t n = ::send(m_fd, data.constData() + off, static_cast<size_t>(data.size() - off), MSG_NOSIGNAL);
		if (n < 0)
		{
			if (errno == EINTR)
				continue;
			if (errno == EAGAIN)
			{
				// Input is tiny; a full buffer means the session is stuck. Drop this line.
				return;
			}
			detach();
			setState(QStringLiteral("detached"));
			return;
		}
		off += n;
	}
}

void RdpView::onReadable()
{
	char buf[65536];
	char cbuf[CMSG_SPACE(sizeof(int) * 8)];
	for (;;)
	{
		iovec iov = { buf, sizeof(buf) };
		msghdr msg = {};
		msg.msg_iov = &iov;
		msg.msg_iovlen = 1;
		msg.msg_control = cbuf;
		msg.msg_controllen = sizeof(cbuf);
		const ssize_t n = recvmsg(m_fd, &msg, MSG_DONTWAIT | MSG_CMSG_CLOEXEC);
		if (n > 0)
		{
			for (cmsghdr* c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c))
			{
				if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS)
				{
					const size_t count = (c->cmsg_len - CMSG_LEN(0)) / sizeof(int);
					for (size_t i = 0; i < count; i++)
					{
						int fd;
						memcpy(&fd, CMSG_DATA(c) + i * sizeof(int), sizeof(int));
						m_fds.push_back(fd);
					}
				}
			}
			m_inbuf.append(buf, n);
			continue;
		}
		if (n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR))
		{
			// The session ended (or crashed); its last state line already said which.
			detach();
			if (m_state == QStringLiteral("connecting") || m_state == QStringLiteral("connected"))
				setState(QStringLiteral("detached"));
			if (!m_socketPath.isEmpty())
				m_attachTimer.start();
			return;
		}
		break;
	}
	qsizetype pos;
	while ((pos = m_inbuf.indexOf('\n')) >= 0)
	{
		const QByteArray line = m_inbuf.left(pos);
		m_inbuf.remove(0, pos + 1);
		handleLine(line);
	}
}

static QString unb64(const QByteArray& s)
{
	return s == "-" ? QString() : QString::fromUtf8(QByteArray::fromBase64(s));
}

void RdpView::handleLine(const QByteArray& line)
{
	const QList<QByteArray> w = line.split(' ');
	const QByteArray& cmd = w[0];
	auto num = [&](int i) { return i < w.size() ? w[i].toInt() : 0; };

	if (cmd == "damage")
	{
		if (!m_dirty)
		{
			m_dirty = true;
			if (isVisible())
				update();
		}
	}
	else if (cmd == "frame" && w.size() >= 4)
	{
		if (m_fds.empty())
			return;
		const int fd = m_fds.front();
		m_fds.pop_front();
		mapFrame(fd, num(1), num(2), num(3));
	}
	else if (cmd == "state" && w.size() >= 2)
		setState(QString::fromLatin1(w[1]), num(2));
	else if (cmd == "cursor" && w.size() >= 7)
	{
		const int width = num(4), height = num(5);
		QByteArray pixels = QByteArray::fromBase64(w[6]);
		if (width > 0 && height > 0 && pixels.size() >= width * height * 4)
		{
			QImage img(reinterpret_cast<const uchar*>(pixels.constData()), width, height, width * 4,
			           QImage::Format_ARGB32);
			QPixmap pm = QPixmap::fromImage(img.copy());
			// The server drew it for its own scale, which matches ours: show it pixel for pixel.
			pm.setDevicePixelRatio(devicePixelRatio());
			const qreal dpr = devicePixelRatio();
			m_cursors.insert(static_cast<quint32>(num(1)),
			                 QCursor(pm, static_cast<int>(num(2) / dpr), static_cast<int>(num(3) / dpr)));
		}
	}
	else if (cmd == "cursor-set" && w.size() >= 2)
	{
		const auto it = m_cursors.constFind(static_cast<quint32>(num(1)));
		if (it != m_cursors.constEnd())
			setCursor(*it);
	}
	else if (cmd == "cursor-hide")
		setCursor(Qt::BlankCursor);
	else if (cmd == "cursor-default")
		setCursor(Qt::ArrowCursor);
	else if (cmd == "clip" && w.size() >= 2)
	{
		m_lastClip = unb64(w[1]);
		QGuiApplication::clipboard()->setText(m_lastClip);
	}
	else if (cmd == "cert" && w.size() >= 8)
	{
		m_prompt = { { "kind", "cert" },
			         { "changed", num(1) != 0 },
			         { "host", unb64(w[2]) },
			         { "port", num(3) },
			         { "commonName", unb64(w[4]) },
			         { "subject", unb64(w[5]) },
			         { "issuer", unb64(w[6]) },
			         { "fingerprint", unb64(w[7]) } };
		emit promptChanged();
	}
	else if (cmd == "auth" && w.size() >= 4)
	{
		m_prompt = { { "kind", "auth" },
			         { "reason", QString::fromLatin1(w[1]) },
			         { "user", unb64(w[2]) },
			         { "domain", unb64(w[3]) } };
		emit promptChanged();
	}
	else if (cmd == "prompt-done")
	{
		m_prompt.clear();
		emit promptChanged();
	}
}

void RdpView::setState(const QString& state, int code)
{
	if (state == m_state && code == m_exitCode)
		return;
	m_state = state;
	m_exitCode = code;
	emit stateChanged();
}

// ---------------------------------------------------------------- framebuffer

namespace {
struct Mapping
{
	void* addr;
	size_t size;
};

void releaseMapping(void* info)
{
	auto* m = static_cast<Mapping*>(info);
	munmap(m->addr, m->size);
	delete m;
}
}

void RdpView::mapFrame(int fd, int w, int h, int stride)
{
	unmapFrame();
	const size_t size = static_cast<size_t>(stride) * static_cast<size_t>(h);
	void* p = mmap(nullptr, size, PROT_READ, MAP_SHARED, fd, 0);
	close(fd);
	if (p == MAP_FAILED)
		return;
	if (w <= 0 || h <= 0)
	{
		munmap(p, size);
		return;
	}
	// BGRX in memory is 0xffRRGGBB as a little-endian word: Qt's RGB32. The mapping lives as long
	// as any copy of the image: the render thread uploads from a copy after sync, so unmapping
	// here when the session resizes would pull the pixels out from under that upload.
	m_image = QImage(static_cast<const uchar*>(p), w, h, stride, QImage::Format_RGB32, releaseMapping,
	                 new Mapping { p, size });
	m_dirty = true;
	emit remoteSizeChanged();
	update();
}

void RdpView::unmapFrame()
{
	m_image = QImage();
}

QRectF RdpView::imageRect() const
{
	if (m_image.isNull() || width() <= 0 || height() <= 0)
		return {};
	// Logical size the remote desktop would have at our pixel ratio.
	const qreal dpr = devicePixelRatio();
	QSizeF natural(m_image.width() / dpr, m_image.height() / dpr);
	QSizeF fit = natural;
	// Shrink to fit always; grow only when the desktop is not following the item (fixed size).
	if (fit.width() > width() || fit.height() > height() || !m_followSize)
		fit = natural.scaled(size(), Qt::KeepAspectRatio);
	return QRectF(QPointF((width() - fit.width()) / 2, (height() - fit.height()) / 2), fit);
}

QSGNode* RdpView::updatePaintNode(QSGNode* old, UpdatePaintNodeData*)
{
	auto* node = static_cast<QSGImageNode*>(old);
	if (m_image.isNull())
	{
		delete node;
		return nullptr;
	}
	if (!node)
	{
		node = window()->createImageNode();
		node->setOwnsTexture(true);
		m_dirty = true;
	}
	if (m_dirty)
	{
		// The image wraps the shared mapping; the upload is the copy.
		QSGTexture* texture = window()->createTextureFromImage(m_image);
		node->setTexture(texture);
		m_dirty = false;
	}
	const QRectF r = imageRect();
	node->setRect(r);
	// Pixel for pixel when not scaled; smooth when the picture is resized to fit.
	const qreal dpr = devicePixelRatio();
	const bool exact = qFuzzyCompare(r.width() * dpr, qreal(m_image.width()));
	node->setFiltering(exact ? QSGTexture::Nearest : QSGTexture::Linear);
	return node;
}

qreal RdpView::devicePixelRatio() const
{
	return window() ? window()->effectiveDevicePixelRatio() : 1.0;
}

// ---------------------------------------------------------------- size

void RdpView::geometryChange(const QRectF& newGeometry, const QRectF& oldGeometry)
{
	QQuickItem::geometryChange(newGeometry, oldGeometry);
	if (newGeometry.size() != oldGeometry.size())
	{
		scheduleSize();
		update();
	}
}

void RdpView::itemChange(ItemChange change, const ItemChangeData& value)
{
	QQuickItem::itemChange(change, value);
	if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange)
		scheduleSize();
	// A hidden tab sends no size, so one resized meanwhile (the list pinned or the window
	// resized) catches up when shown; the session ignores a size it already has.
	if (change == ItemVisibleHasChanged && value.boolValue)
	{
		scheduleSize();
		if (m_dirty)
			update();
	}
}

void RdpView::scheduleSize()
{
	m_sizeTimer.start();
}

void RdpView::sendSize()
{
	if (m_fd < 0 || !m_followSize || width() < 50 || height() < 50 || !isVisible())
		return;
	const qreal dpr = devicePixelRatio();
	const int w = qRound(width() * dpr), h = qRound(height() * dpr);
	const int scale = m_desktopScale > 0 ? m_desktopScale : qRound(dpr * 100);
	send(QByteArray("size ") + QByteArray::number(w) + ' ' + QByteArray::number(h) + ' ' + QByteArray::number(scale));
}

// ---------------------------------------------------------------- input

QPoint RdpView::toRemote(const QPointF& p) const
{
	const QRectF r = imageRect();
	if (r.isEmpty())
		return {};
	const qreal x = (p.x() - r.x()) * m_image.width() / r.width();
	const qreal y = (p.y() - r.y()) * m_image.height() / r.height();
	return QPoint(qBound(0, qRound(x), m_image.width() - 1), qBound(0, qRound(y), m_image.height() - 1));
}

static int buttonNumber(Qt::MouseButton b)
{
	switch (b)
	{
		case Qt::LeftButton: return 1;
		case Qt::RightButton: return 2;
		case Qt::MiddleButton: return 3;
		case Qt::BackButton: return 4;
		case Qt::ForwardButton: return 5;
		default: return 0;
	}
}

void RdpView::mousePressEvent(QMouseEvent* e)
{
	forceActiveFocus(Qt::MouseFocusReason);
	const int b = buttonNumber(e->button());
	const QPoint p = toRemote(e->position());
	if (b)
		send("button " + QByteArray::number(b) + " 1 " + QByteArray::number(p.x()) + ' ' + QByteArray::number(p.y()));
	e->accept();
}

void RdpView::mouseReleaseEvent(QMouseEvent* e)
{
	const int b = buttonNumber(e->button());
	const QPoint p = toRemote(e->position());
	if (b)
		send("button " + QByteArray::number(b) + " 0 " + QByteArray::number(p.x()) + ' ' + QByteArray::number(p.y()));
	e->accept();
}

void RdpView::mouseMoveEvent(QMouseEvent* e)
{
	const QPoint p = toRemote(e->position());
	send("mouse " + QByteArray::number(p.x()) + ' ' + QByteArray::number(p.y()));
	e->accept();
}

void RdpView::hoverMoveEvent(QHoverEvent* e)
{
	const QPoint p = toRemote(e->position());
	send("mouse " + QByteArray::number(p.x()) + ' ' + QByteArray::number(p.y()));
	e->accept();
}

void RdpView::wheelEvent(QWheelEvent* e)
{
	const QPoint p = toRemote(e->position());
	const QPoint d = e->angleDelta();
	if (!d.isNull())
		send("wheel " + QByteArray::number(d.y()) + ' ' + QByteArray::number(d.x()) + ' ' + QByteArray::number(p.x()) +
		     ' ' + QByteArray::number(p.y()));
	e->accept();
}

void RdpView::keyPressEvent(QKeyEvent* e)
{
	// On Wayland (and X11) the native scan code is the XKB keycode: evdev + 8.
	const quint32 code = e->nativeScanCode();
	if (code < 8)
	{
		e->ignore();
		return;
	}
	const quint32 evdev = code - 8;
	m_pressed.insert(evdev);
	// RDP sends the scancode; VNC needs the keysym, which on Wayland and X11 is the native virtual key.
	send("key 1 " + QByteArray::number(evdev) + ' ' + QByteArray::number(e->nativeVirtualKey()));
	e->accept();
}

void RdpView::keyReleaseEvent(QKeyEvent* e)
{
	if (e->isAutoRepeat())
	{
		e->accept();
		return;
	}
	const quint32 code = e->nativeScanCode();
	if (code < 8)
	{
		e->ignore();
		return;
	}
	const quint32 evdev = code - 8;
	m_pressed.remove(evdev);
	send("key 0 " + QByteArray::number(evdev));
	e->accept();
}

void RdpView::releaseAllKeys()
{
	for (quint32 evdev : std::as_const(m_pressed))
		send("key 0 " + QByteArray::number(evdev));
	m_pressed.clear();
}

void RdpView::focusInEvent(QFocusEvent* e)
{
	QQuickItem::focusInEvent(e);
	// Bring the remote toggle keys in line with ours; Qt has no lock-state query, so Num Lock on
	// and the rest off is the common case, and the keys themselves still toggle normally.
	send("focus " + QByteArray::number(kSyncNum));
	(void)kSyncScroll;
	(void)kSyncCaps;
	sendClipboard();
}

void RdpView::focusOutEvent(QFocusEvent* e)
{
	QQuickItem::focusOutEvent(e);
	releaseAllKeys();
}

void RdpView::sendClipboard()
{
	const QString text = QGuiApplication::clipboard()->text();
	if (text.isEmpty() || text == m_lastClip)
		return;
	m_lastClip = text;
	send("clip " + text.toUtf8().toBase64());
}

// ---------------------------------------------------------------- prompts and actions

void RdpView::answerCertificate(int answer)
{
	send("cert-answer " + QByteArray::number(answer));
}

void RdpView::answerCredentials(const QString& user, const QString& domain, const QString& password)
{
	auto enc = [](const QString& s) { return s.isEmpty() ? QByteArray("-") : s.toUtf8().toBase64(); };
	send("auth-answer " + enc(user) + ' ' + enc(domain) + ' ' + enc(password));
}

void RdpView::cancelPrompt()
{
	send("cancel");
}

void RdpView::sendCtrlAltDel()
{
	send("cad");
}

void RdpView::disconnectSession()
{
	send("disconnect");
}
