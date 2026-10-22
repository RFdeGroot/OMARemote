#include "rdpview.h"

#include "clipread.h"

#include <QClipboard>
#include <QCursor>
#include <QDateTime>
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
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <utility>

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
		// Copied elsewhere since: that wins over what the session sent.
		m_hasHeldClip = false;
		m_heldClip.clear();
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
	// Gliff pictures straight from the decoder's surfaces, when the scene graph draws with OpenGL
	// (EGL takes the dmabufs); other sessions ignore the line.
	if (!m_gpuFailed && QQuickWindow::graphicsApi() == QSGRendererInterface::OpenGL &&
	    qEnvironmentVariableIsEmpty("OMAREMOTE_NO_DMABUF"))
		send("gpu 1");
	if (hasActiveFocus())
		sendClipboard(true);
}

void RdpView::detach()
{
	m_attachTimer.stop();
	if (m_fd < 0)
		return;
	// A failed send detaches on its own: then there is nothing left to do here.
	releaseAllKeys();
	if (m_fd < 0)
		return;
	delete m_notifier;
	m_notifier = nullptr;
	close(m_fd);
	m_fd = -1;
	for (int fd : m_fds)
		close(fd);
	m_fds.clear();
	m_inbuf.clear();
	m_skipLine = false;
	// The picture drawn stays up (its textures hold the buffers); the session forgets the rest.
	forgetSurfaces();
	m_showTaken = true;
	m_drawnSeq = 0;
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
		if (m_skipLine)
			m_skipLine = false; // the rest of a line too long to keep
		else
			handleLine(line);
	}
	// No session line comes near this (a cursor is the largest); a longer one is dropped whole.
	if (m_inbuf.size() > MaxLineBytes)
	{
		qWarning("omaremote: the session sent a line longer than %lld bytes; dropped",
		         static_cast<long long>(MaxLineBytes));
		m_inbuf.clear();
		m_skipLine = true;
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
		m_gpu = false; // the session draws into the framebuffer (again)
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
	else if (cmd == "surface")
		addSurface(w);
	else if (cmd == "surfaces-reset")
		forgetSurfaces();
	else if (cmd == "show" && w.size() >= 6)
		showSurfaces(w);
	else if (cmd == "state" && w.size() >= 2)
		setState(QString::fromLatin1(w[1]), num(2));
	else if (cmd == "cursor" && w.size() >= 7)
	{
		const int width = num(4), height = num(5);
		if (width <= 0 || height <= 0 || width > MaxCursorSide || height > MaxCursorSide)
			return;
		QByteArray pixels = QByteArray::fromBase64(w[6]);
		if (pixels.size() >= qsizetype(width) * height * 4)
		{
			QImage img(reinterpret_cast<const uchar*>(pixels.constData()), width, height, width * 4,
			           QImage::Format_ARGB32);
			QPixmap pm = QPixmap::fromImage(img.copy());
			// The server drew it for its own scale, which matches ours: show it pixel for pixel.
			pm.setDevicePixelRatio(devicePixelRatio());
			const qreal dpr = devicePixelRatio();
			const quint32 id = static_cast<quint32>(num(1));
			if (!m_cursors.contains(id) && m_cursors.size() >= MaxCursors)
			{
				auto oldest = m_cursors.begin();
				for (auto it = m_cursors.begin(); it != m_cursors.end(); ++it)
					if (it->used < oldest->used)
						oldest = it;
				m_cursors.erase(oldest);
			}
			m_cursors.insert(id, { QCursor(pm, static_cast<int>(num(2) / dpr), static_cast<int>(num(3) / dpr)),
			                       ++m_cursorClock });
		}
	}
	else if (cmd == "cursor-set" && w.size() >= 2)
	{
		const auto it = m_cursors.find(static_cast<quint32>(num(1)));
		if (it != m_cursors.end())
		{
			it->used = ++m_cursorClock;
			setCursor(it->cursor);
		}
	}
	else if (cmd == "cursor-hide")
		setCursor(Qt::BlankCursor);
	else if (cmd == "cursor-default")
		setCursor(Qt::ArrowCursor);
	else if (cmd == "cursor-text")
		setCursor(Qt::IBeamCursor);
	else if (cmd == "clip-progress" && w.size() >= 5)
		emit pasteProgress(int(num(1)), w[2].toDouble(), w[3].toDouble(), unb64(w[4]));
	else if (cmd == "clip-done" && w.size() >= 2)
		emit pasteDone(int(num(1)));
	else if (cmd == "stats" && w.size() >= 2)
		emit statsChanged(unb64(w[1]));
	else if (cmd == "reconnect" && w.size() >= 2 && (w[1] == "wait" || w[1] == "trying" || w[1] == "off"))
		emit reconnectChanged(QString::fromLatin1(w[1]), int(num(2)), int(num(3)));
	else if (cmd == "clip" && w.size() >= 2)
	{
		// At most MaxClipBytes: the session processes keep to it, this is the backstop.
		if (!m_shareClipboard || w[1].size() > (MaxClipBytes + 2) / 3 * 4)
			return;
		const QByteArray text = w[1] == "-" ? QByteArray() : QByteArray::fromBase64(w[1]);
		if (text.size() > MaxClipBytes)
			return;
		if (hasActiveFocus())
		{
			m_lastClip = QString::fromUtf8(text);
			QGuiApplication::clipboard()->setText(m_lastClip);
		}
		else
		{
			m_heldClip = QString::fromUtf8(text);
			m_hasHeldClip = true;
		}
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
	else if (cmd == "hostkey" && w.size() >= 3)
	{
		// Gliff's ssh meets a host for the first time (gliff/askpass.hpp); answered with answerCertificate.
		m_prompt = { { "kind", "hostkey" },
			         { "host", unb64(w[1]) },
			         { "key", unb64(w[2]) },
			         { "details", w.size() >= 4 ? unb64(w[3]) : unb64(w[2]) },
			         { "changed", w.size() >= 5 && num(4) != 0 } }; // other key types known: a warning
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
	// The session's numbers, checked before anything is mapped: a side past MaxFrameSide would
	// take this window (and every tab in it) down, and a memfd shorter than stride * h would
	// SIGBUS on the first read past its end.
	struct stat st {};
	const bool sane = w > 0 && h > 0 && w <= MaxFrameSide && h <= MaxFrameSide &&
	                  stride >= w * 4 && stride <= MaxFrameSide * 4 && fstat(fd, &st) == 0 &&
	                  S_ISREG(st.st_mode) &&
	                  st.st_size >= static_cast<off_t>(static_cast<size_t>(stride) * static_cast<size_t>(h));
	if (!sane)
	{
		qWarning("omaremote: a %dx%d frame (stride %d) from the session was not shown", w, h, stride);
		close(fd);
		return;
	}
	const size_t size = static_cast<size_t>(stride) * static_cast<size_t>(h);
	void* p = mmap(nullptr, size, PROT_READ, MAP_SHARED, fd, 0);
	close(fd);
	if (p == MAP_FAILED)
		return;
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
	const QSize picture = remoteSize();
	if (picture.isEmpty() || width() <= 0 || height() <= 0)
		return {};
	// Logical size the remote desktop would have at our pixel ratio.
	const qreal dpr = devicePixelRatio();
	QSizeF natural(picture.width() / dpr, picture.height() / dpr);
	QSizeF fit = natural;
	// Shrink to fit always; grow only when the desktop is not following the item (fixed size).
	if (fit.width() > width() || fit.height() > height() || !m_followSize)
		fit = natural.scaled(size(), Qt::KeepAspectRatio);
	return QRectF(QPointF((width() - fit.width()) / 2, (height() - fit.height()) / 2), fit);
}

// ---------------------------------------------------------------- pictures as dmabufs

// "surface <id> <width> <height> <objects> <modifier>... <layers> (<fourcc> <object> <offset>
// <pitch>)...", with one descriptor per object.
void RdpView::addSurface(const QList<QByteArray>& w)
{
	const int objects = w.size() > 4 ? w[4].toInt() : 0;
	if (objects < 1 || objects > 4 || int(m_fds.size()) < objects)
		return;
	DmabufSurface s;
	s.objects = objects;
	for (int i = 0; i < objects; i++)
	{
		s.fds[i] = m_fds.front();
		m_fds.pop_front();
	}
	const int layerAt = 5 + objects;
	bool ok = w.size() >= layerAt + 1 + 8 && w[layerAt].toInt() == 2;
	if (ok)
	{
		s.id = w[1].toUInt();
		s.width = w[2].toInt();
		s.height = w[3].toInt();
		for (int i = 0; i < objects; i++)
			s.modifiers[i] = w[5 + i].toULongLong();
		for (int i = 0; i < 2; i++)
		{
			const int at = layerAt + 1 + i * 4;
			s.layers[i] = { w[at].toUInt(), w[at + 1].toInt(), w[at + 2].toUInt(), w[at + 3].toUInt() };
		}
		ok = s.width > 0 && s.height > 0 && s.width <= MaxFrameSide && s.height <= MaxFrameSide;
	}
	if (!ok)
	{
		for (int fd : s.fds)
			if (fd >= 0)
				close(fd);
		return;
	}
	const auto old = m_surfaces.constFind(s.id);
	if (old != m_surfaces.constEnd())
		for (int fd : old->fds)
			if (fd >= 0)
				close(fd);
	m_surfaces.insert(s.id, s);
}

void RdpView::forgetSurfaces()
{
	for (const DmabufSurface& s : std::as_const(m_surfaces))
		for (int fd : s.fds)
			if (fd >= 0)
				close(fd);
	m_surfaces.clear();
	m_surfaceGeneration++;
}

// "show <seq> <main> <aux or -> <width> <height>": the newest picture. One the render thread never
// took is released at once; the newest is drawn at the next frame.
void RdpView::showSurfaces(const QList<QByteArray>& w)
{
	if (!m_showTaken && m_show.seq != m_drawnSeq)
		send("release " + QByteArray::number(m_show.seq));
	const QSize before = remoteSize();
	m_show.seq = w[1].toULongLong();
	m_show.main = w[2].toUInt();
	m_show.dual = w[3] != "-";
	m_show.aux = m_show.dual ? w[3].toUInt() : 0;
	m_show.size = QSize(w[4].toInt(), w[5].toInt());
	m_showTaken = false;
	m_gpu = true;
	if (remoteSize() != before)
		emit remoteSizeChanged();
	if (isVisible())
		update();
}

// From the render thread: the line goes out on the item's own thread.
void RdpView::sendLater(const QByteArray& line)
{
	QMetaObject::invokeMethod(this, [this, line] { send(line); }, Qt::QueuedConnection);
}

QSGNode* RdpView::updatePaintNode(QSGNode* old, UpdatePaintNodeData*)
{
	// Runs on the render thread with the item's thread blocked: the members are safe to read.
	if (old && m_nodeGpu != m_gpu)
	{
		delete old;
		old = nullptr;
	}
	m_nodeGpu = m_gpu;
	if (m_gpu)
	{
		auto* node = static_cast<YuvNode*>(old);
		// A new node (another window, or the scene graph rebuilt) imports the picture again.
		const bool fresh = !node;
		if (!node)
			node = new YuvNode(window());
		const auto main = m_surfaces.constFind(m_show.main);
		const auto aux = m_show.dual ? m_surfaces.constFind(m_show.aux) : m_surfaces.constEnd();
		if ((!m_showTaken || fresh) && main != m_surfaces.constEnd() &&
		    (!m_show.dual || aux != m_surfaces.constEnd()))
		{
			if (!node->setPicture(*main, m_show.dual ? &*aux : nullptr, m_show.size, m_surfaceGeneration))
			{
				// This GPU cannot draw them: the session converts from here on.
				qWarning("omaremote: Gliff pictures are converted on the CPU from here on");
				delete node;
				m_gpuFailed = true;
				m_gpu = m_nodeGpu = false;
				sendLater("gpu 0");
				return nullptr;
			}
			if (m_drawnSeq && m_drawnSeq != m_show.seq)
				sendLater("release " + QByteArray::number(m_drawnSeq));
			m_drawnSeq = m_show.seq;
			m_showTaken = true;
		}
		if (!node->hasPicture())
		{
			delete node;
			return nullptr;
		}
		const QRectF r = imageRect();
		node->setRect(r, !qFuzzyCompare(r.width() * devicePixelRatio(), qreal(m_show.size.width())));
		return node;
	}
	if (m_drawnSeq)
	{
		sendLater("release " + QByteArray::number(m_drawnSeq));
		m_drawnSeq = 0;
	}

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
	if (change == ItemSceneChange)
	{
		m_inhibit.release(); // held for the old window
		if (value.window)
			connect(value.window, &QWindow::activeChanged, this, &RdpView::updateCapture, Qt::UniqueConnection);
	}
	if (change == ItemVisibleHasChanged || change == ItemSceneChange)
		updateCapture();
	// A hidden tab sends no size, so one resized meanwhile (the list pinned or the window
	// resized) catches up when shown; the session ignores a size it already has.
	if (change == ItemVisibleHasChanged && value.boolValue)
	{
		scheduleSize();
		if (m_dirty || !m_showTaken)
			update();
	}
}

// Holds the compositor's shortcuts while this view has the keyboard and is meant to; lets go
// otherwise. Focus moves between OMARemote's own items (the sidebar, another tab) release them.
void RdpView::updateCapture()
{
	const bool want = m_captureShortcuts && !m_released && m_pointerInside && hasActiveFocus() && isVisible() &&
	                  window() && window()->isActive();
	const bool before = m_inhibit.held();
	if (want)
		m_inhibit.inhibit(window());
	else
		m_inhibit.release();
	if (m_inhibit.held() != before)
		emit shortcutsCapturedChanged();
}

void RdpView::releaseShortcuts()
{
	if (!m_inhibit.held())
		return;
	m_released = true;
	updateCapture();
}

void RdpView::setCaptureShortcuts(bool capture)
{
	if (capture == m_captureShortcuts)
		return;
	m_captureShortcuts = capture;
	emit captureShortcutsChanged();
	updateCapture();
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
	const QSize picture = remoteSize();
	const qreal x = (p.x() - r.x()) * picture.width() / r.width();
	const qreal y = (p.y() - r.y()) * picture.height() / r.height();
	return QPoint(qBound(0, qRound(x), picture.width() - 1), qBound(0, qRound(y), picture.height() - 1));
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
	if (m_released)
	{
		m_released = false;
		updateCapture();
	}
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

// The shortcuts follow the pointer, as in Gliff's own client: taken when it comes onto the picture,
// given back (and the keys held on the remote let go) when it leaves; a release by key lasts until
// then.
void RdpView::hoverEnterEvent(QHoverEvent* e)
{
	QQuickItem::hoverEnterEvent(e);
	m_pointerInside = true;
	updateCapture();
}

void RdpView::hoverLeaveEvent(QHoverEvent* e)
{
	QQuickItem::hoverLeaveEvent(e);
	m_pointerInside = false;
	m_released = false;
	const bool held = m_inhibit.held();
	updateCapture();
	if (held)
		releaseAllKeys();
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

namespace {
// The modifiers a key event can carry without its key having been pressed here: evdev codes of
// the left and right key, and the left one's keysym. Only Shift and Ctrl are ever added (what a
// sent shortcut needs); Super is only lifted when it was passed on: without the connection's
// Super key setting the session never gets Super, and a key typed while Super is held must not
// bring it in. Alt is not among them: AltGr (right Alt) types characters without Qt reporting
// Alt, and must never be taken away.
struct ModifierKey
{
	Qt::KeyboardModifier mod;
	quint32 left, right, keysym;
	bool add;
};
constexpr ModifierKey kModifierKeys[] = {
	{Qt::ShiftModifier, 42, 54, 0xffe1, true},
	{Qt::ControlModifier, 29, 97, 0xffe3, true},
	{Qt::MetaModifier, 125, 126, 0xffeb, false},
};

bool isModifierKey(quint32 evdev)
{
	switch (evdev)
	{
		case 42: case 54: case 29: case 97: case 56: case 100: case 125: case 126:
			return true;
		default:
			return false;
	}
}
}

void RdpView::keyPressEvent(QKeyEvent* e)
{
	// On Wayland (and X11) the native scan code is the XKB keycode: evdev + 8.
	const quint32 code = e->nativeScanCode();
	if (code < 8)
	{
		// Text without a key (an input method's or compose's result): SSH types it.
		if (!e->text().isEmpty())
		{
			send("text " + e->text().toUtf8().toBase64());
			e->accept();
			return;
		}
		e->ignore();
		return;
	}
	const quint32 evdev = code - 8;
	// The release key while the shortcuts are held: they go back to Hyprland. The key itself stays
	// here; its modifiers already went to the session and go up with their releases. Double Esc:
	// the first reaches the session, a second within 400 ms releases. (The session keys + Esc
	// release too: SessionView's chord, through releaseShortcuts.)
	if (m_inhibit.held() && !e->isAutoRepeat())
	{
		const Qt::KeyboardModifiers mods = e->modifiers() & ~Qt::KeypadModifier;
		bool release = false;
		if (m_releaseKey == QLatin1String("shift+escape"))
			release = e->key() == Qt::Key_Escape && mods == Qt::ShiftModifier;
		else if (m_releaseKey == QLatin1String("double-escape") && e->key() == Qt::Key_Escape && mods == Qt::NoModifier)
		{
			const qint64 now = QDateTime::currentMSecsSinceEpoch();
			release = now - m_lastEscape < 400;
			m_lastEscape = release ? 0 : now;
		}
		if (release)
		{
			m_released = true;
			updateCapture();
			e->accept();
			return;
		}
	}
	// Hyprland's sendshortcut (Omarchy's Super+V: Shift+Insert in a terminal, Ctrl+V elsewhere) sets
	// the modifier state without pressing the modifier keys, and Super stays physically held. The
	// session sees keys, not states: press the missing modifiers around this key, and lift a held
	// Super it was not sent with, so SSH gets Shift+Insert and Windows Ctrl+V, not Win+Ctrl+V.
	if (!isModifierKey(evdev) && !e->isAutoRepeat())
	{
		Chord chord;
		const Qt::KeyboardModifiers mods = e->modifiers();
		// The missing Shift and Ctrl first, then a held Super lifted: Windows then sees Win with
		// another key down, never a lone Win press and release, which opens its Start menu.
		for (const ModifierKey& m : kModifierKeys)
		{
			const bool held = m_pressed.contains(m.left) || m_pressed.contains(m.right);
			if ((mods & m.mod) && !held && m.add)
			{
				send("key 1 " + QByteArray::number(m.left) + ' ' + QByteArray::number(m.keysym));
				chord.added.append({m.left, m.keysym});
			}
		}
		for (const ModifierKey& m : kModifierKeys)
		{
			const bool held = m_pressed.contains(m.left) || m_pressed.contains(m.right);
			if (!(mods & m.mod) && held && m.mod == Qt::MetaModifier)
				for (quint32 k : {m.left, m.right})
					if (m_pressed.contains(k))
					{
						send("key 0 " + QByteArray::number(k));
						chord.lifted.append({k, k == m.left ? m.keysym : m.keysym + 1});
					}
		}
		if (!chord.added.isEmpty() || !chord.lifted.isEmpty())
			m_chords.insert(evdev, chord);
	}
	m_pressed.insert(evdev);
	// RDP sends the scancode; VNC needs the keysym, which on Wayland and X11 is the native virtual key;
	// SSH types the text the layout made of it (dead keys included).
	QByteArray line = "key 1 " + QByteArray::number(evdev) + ' ' + QByteArray::number(e->nativeVirtualKey());
	if (!e->text().isEmpty())
		line += ' ' + e->text().toUtf8().toBase64();
	send(line);
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
	// Undo what was done around it: the added modifiers go up.
	const auto chord = m_chords.find(evdev);
	if (chord != m_chords.end())
	{
		for (const auto& [k, sym] : chord->added)
			send("key 0 " + QByteArray::number(k));
		// A lifted Super is not pressed again: the session would see a lone Win press and release
		// when the user lets go. Its release (sent again then) is harmless.
		m_chords.erase(chord);
	}
	e->accept();
}

void RdpView::releaseAllKeys()
{
	// Taken off the list first: a send to a session that just ended detaches, and detaching
	// releases the keys again (the Enter of an SSH "exit" is still held when the session ends).
	const QSet<quint32> keys = std::exchange(m_pressed, {});
	const auto chords = std::exchange(m_chords, {});
	for (quint32 evdev : keys)
		send("key 0 " + QByteArray::number(evdev));
	for (const Chord& chord : chords)
		for (const auto& [k, sym] : chord.added)
			send("key 0 " + QByteArray::number(k));
}

void RdpView::focusInEvent(QFocusEvent* e)
{
	QQuickItem::focusInEvent(e);
	updateCapture();
	// Bring the remote toggle keys in line with ours; Qt has no lock-state query, so Num Lock on
	// and the rest off is the common case, and the keys themselves still toggle normally.
	send("focus " + QByteArray::number(kSyncNum));
	(void)kSyncScroll;
	(void)kSyncCaps;
	// Held text is set a moment later: on Wayland the desktop's newer selection reaches us around
	// the keyboard's arrival, and must get the chance to drop it first.
	if (m_hasHeldClip)
		QTimer::singleShot(150, this, [this] {
			if (hasActiveFocus())
				applyHeldClip();
		});
	else
		sendClipboard();
}

void RdpView::applyHeldClip()
{
	if (!m_hasHeldClip)
		return;
	m_hasHeldClip = false;
	m_lastClip = m_heldClip;
	m_heldClip.clear();
	if (m_shareClipboard)
		QGuiApplication::clipboard()->setText(m_lastClip);
}

void RdpView::cancelPaste(int job)
{
	send("clip-cancel " + QByteArray::number(job));
}

void RdpView::reconnectNow()
{
	send("reconnect now");
}

void RdpView::cancelReconnect()
{
	send("reconnect cancel");
}

void RdpView::focusOutEvent(QFocusEvent* e)
{
	QQuickItem::focusOutEvent(e);
	send("blur");
	releaseAllKeys();
	updateCapture();
}

// Offers our clipboard to the session. Before it is attached there is no one to tell, so nothing is
// marked as sent; attaching offers it again (force: a new session has not seen it yet).
// Read with wl-paste (clipread.h), never QClipboard::text(); our own clipboard is read the same way,
// which Qt serves from the event loop while the read waits in its own process.
void RdpView::sendClipboard(bool force)
{
	if (m_fd < 0 || !m_shareClipboard)
		return;
	if (m_clipReading) {
		m_clipAgain = true;
		m_clipAgainForce = m_clipAgainForce || force;
		return;
	}
	m_clipReading = true;
	oma::readClipboard(this, MaxClipBytes, ClipTimeoutMs, false, [this, force](bool ok, const QByteArray& data) {
		m_clipReading = false;
		if (ok)
			offerClipboard(QString::fromUtf8(data), force);
		if (m_clipAgain) {
			const bool again = m_clipAgainForce;
			m_clipAgain = m_clipAgainForce = false;
			sendClipboard(again);
		}
	});
}

// The text read, to the session: only while still attached, sharing and focused, as when asked.
void RdpView::offerClipboard(const QString& text, bool force)
{
	if (m_fd < 0 || !m_shareClipboard || !hasActiveFocus())
		return;
	if (text.isEmpty() || (text == m_lastClip && !force))
		return;
	m_lastClip = text;
	send("clip " + text.toUtf8().toBase64());
}

void RdpView::setShareClipboard(bool share)
{
	if (share == m_shareClipboard)
		return;
	m_shareClipboard = share;
	m_hasHeldClip = false;
	m_heldClip.clear();
	emit shareClipboardChanged();
	if (share && hasActiveFocus())
		sendClipboard(true);
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
