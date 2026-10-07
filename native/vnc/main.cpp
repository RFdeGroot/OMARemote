// omaremote-vnc: one VNC session, rendered for a tab in the OMARemote window.
//
// libvncclient decodes into a shared-memory framebuffer the UI maps; the UI attaches over the
// same Unix socket protocol omaremote-rdp speaks (native/common/link.hpp), so one view draws both.
//
// Settings arrive as key=value lines on stdin, so the password never shows in the process list:
//   host, port, username, password, viewOnly (0/1), quality (auto|high|low),
//   scaling (fit|native|resize: resize asks the server to follow the tab's size)

#include "../common/link.hpp"

#include <rfb/rfbclient.h>

#include <poll.h>

#include <algorithm>
#include <cerrno>
#include <csignal>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <map>
#include <string>

using oma::b64;
using oma::log;
using oma::split;
using oma::unb64;

// ---------------------------------------------------------------- state

struct Session
{
	std::map<std::string, std::string> cfg;
	oma::Link link;
	rfbClient* client = nullptr;
	oma::Framebuffer frame;
	bool connected = false;
	volatile sig_atomic_t quit = 0;

	// Damage collected over one framebuffer update, sent once it completes.
	int dx0 = 0, dy0 = 0, dx1 = 0, dy1 = 0;
	bool dirty = false;

	int buttons = 0;                      // RFB button mask
	std::map<uint32_t, uint32_t> pressed; // evdev code -> keysym sent at press, released the same
	std::string remoteClip;
	std::string localClip;

	uint32_t cursorId = 0;
	std::string cursorDef;
	std::string cursorState = "cursor-default";

	uint32_t wantW = 0, wantH = 0, sentW = 0, sentH = 0;
	uint64_t lastResizeAt = 0;

	bool authFailed = false;
	std::string lastError;

	bool flag(const char* key) const
	{
		auto it = cfg.find(key);
		return it != cfg.end() && it->second == "1";
	}
	std::string get(const char* key, const char* fallback = "") const
	{
		auto it = cfg.find(key);
		return it == cfg.end() || it->second.empty() ? fallback : it->second;
	}
};

static Session g;

static std::string format_line(const char* fmt, va_list ap)
{
	char buf[1024];
	vsnprintf(buf, sizeof(buf), fmt, ap);
	std::string line(buf);
	while (!line.empty() && (line.back() == '\n' || line.back() == '\r'))
		line.pop_back();
	return line;
}

// libvncclient's log hooks carry no context; there is one session per process.
// libvncclient reports some failures (a wrong password among them) on its ordinary log, so both
// hooks watch for them.
static void note_failure(const std::string& line)
{
	std::string lower = line;
	for (auto& c : lower)
		c = char(tolower(static_cast<unsigned char>(c)));
	const bool failure = lower.find("fail") != std::string::npos || lower.find("unable") != std::string::npos ||
	                     lower.find("error") != std::string::npos;
	if (!failure)
		return;
	g.lastError = line;
	if (lower.find("authentication") != std::string::npos || lower.find("password") != std::string::npos)
		g.authFailed = true;
}

static void client_log(const char* fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	const std::string line = format_line(fmt, ap);
	va_end(ap);
	log("vnc: %s", line.c_str());
	note_failure(line);
}

static void client_err(const char* fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	const std::string line = format_line(fmt, ap);
	va_end(ap);
	log("vnc error: %s", line.c_str());
	g.lastError = line;
	note_failure(line);
}

// ---------------------------------------------------------------- framebuffer and screen

static rfbBool malloc_framebuffer(rfbClient* client)
{
	oma::Framebuffer old = g.frame;
	oma::Framebuffer fb = oma::fb_alloc(uint32_t(client->width), uint32_t(client->height));
	if (!fb.data)
		return FALSE;
	g.frame = fb;
	client->frameBuffer = fb.data;
	log("desktop is %dx%d", client->width, client->height);
	if (g.connected)
		g.link.sendFrame(g.frame);
	// The UI keeps its own mapping of the old one until it maps the new.
	if (old.data)
		oma::fb_release(old.data);
	return TRUE;
}

static void got_update(rfbClient*, int x, int y, int w, int h)
{
	if (!g.dirty)
	{
		g.dx0 = x;
		g.dy0 = y;
		g.dx1 = x + w;
		g.dy1 = y + h;
		g.dirty = true;
		return;
	}
	g.dx0 = std::min(g.dx0, x);
	g.dy0 = std::min(g.dy0, y);
	g.dx1 = std::max(g.dx1, x + w);
	g.dy1 = std::max(g.dy1, y + h);
}

static void finished_update(rfbClient*)
{
	if (!g.dirty)
		return;
	g.dirty = false;
	g.link.send("damage " + std::to_string(g.dx0) + " " + std::to_string(g.dy0) + " " + std::to_string(g.dx1 - g.dx0) +
	            " " + std::to_string(g.dy1 - g.dy0));
}

// The server's cursor, drawn locally so it moves without a round trip.
static void got_cursor(rfbClient* client, int xhot, int yhot, int width, int height, int bytesPerPixel)
{
	if (width <= 0 || height <= 0 || !client->rcSource || bytesPerPixel != 4)
		return;
	std::string pixels(size_t(width) * size_t(height) * 4, '\0');
	for (int i = 0; i < width * height; i++)
	{
		const uint8_t* src = client->rcSource + i * 4; // our pixel format: B G R X
		const bool shown = client->rcMask ? client->rcMask[i] != 0 : true;
		pixels[size_t(i) * 4 + 0] = char(src[0]);
		pixels[size_t(i) * 4 + 1] = char(src[1]);
		pixels[size_t(i) * 4 + 2] = char(src[2]);
		pixels[size_t(i) * 4 + 3] = char(shown ? 0xFF : 0x00);
	}
	g.cursorId++;
	g.cursorDef = "cursor " + std::to_string(g.cursorId) + " " + std::to_string(xhot) + " " + std::to_string(yhot) +
	              " " + std::to_string(width) + " " + std::to_string(height) + " " + b64(pixels);
	g.cursorState = "cursor-set " + std::to_string(g.cursorId);
	g.link.send(g.cursorDef);
	g.link.send(g.cursorState);
}

// ---------------------------------------------------------------- clipboard

static void got_cut_text_utf8(rfbClient*, const char* text, int len)
{
	g.remoteClip.assign(text, size_t(len));
	g.link.send("clip " + b64(g.remoteClip));
}

static void got_cut_text(rfbClient*, const char* text, int len)
{
	// Latin-1 from older servers: widen to UTF-8.
	std::string utf8;
	for (int i = 0; i < len; i++)
	{
		const unsigned char c = static_cast<unsigned char>(text[i]);
		if (c < 0x80)
			utf8 += char(c);
		else
		{
			utf8 += char(0xC0 | (c >> 6));
			utf8 += char(0x80 | (c & 0x3F));
		}
	}
	g.remoteClip = utf8;
	g.link.send("clip " + b64(utf8));
}

static void send_clipboard(const std::string& text)
{
	if (!g.client || g.flag("viewOnly") || text == g.remoteClip || text == g.localClip)
		return;
	g.localClip = text;
	std::string copy = text;
	if (!SendClientCutTextUTF8(g.client, copy.data(), int(copy.size())))
	{
		// Latin-1 for servers without the extended clipboard; what does not fit is dropped.
		std::string latin;
		for (size_t i = 0; i < text.size(); i++)
		{
			const unsigned char c = static_cast<unsigned char>(text[i]);
			if (c < 0x80)
				latin += char(c);
			else if ((c & 0xE0) == 0xC0 && i + 1 < text.size())
			{
				const unsigned v = ((c & 0x1F) << 6) | (static_cast<unsigned char>(text[i + 1]) & 0x3F);
				if (v < 0x100)
					latin += char(v);
				i++;
			}
		}
		SendClientCutText(g.client, latin.data(), int(latin.size()));
	}
}

// ---------------------------------------------------------------- resize

// With scaling=resize, asks the server to make its desktop the tab's size (ExtendedDesktopSize).
// Spaced a second apart; servers that do not support it ignore the request.
static void flush_resize()
{
	if (!g.connected || g.get("scaling") != "resize" || g.wantW == 0)
		return;
	const uint32_t w = std::max<uint32_t>(320, std::min<uint32_t>(8192, g.wantW));
	const uint32_t h = std::max<uint32_t>(200, std::min<uint32_t>(8192, g.wantH));
	if ((w == g.sentW && h == g.sentH) || oma::now_ms() - g.lastResizeAt < 1000)
		return;
	g.lastResizeAt = oma::now_ms();
	g.sentW = w;
	g.sentH = h;
	if (SendExtDesktopSize(g.client, uint16_t(w), uint16_t(h)))
		log("requested desktop %ux%u", w, h);
}

// ---------------------------------------------------------------- input

static void send_pointer(int x, int y)
{
	SendPointerEvent(g.client, std::max(0, x), std::max(0, y), g.buttons);
}

static void click(int mask, int x, int y)
{
	SendPointerEvent(g.client, x, y, g.buttons | mask);
	SendPointerEvent(g.client, x, y, g.buttons);
}

static void handle_line(const std::string& line)
{
	const auto w = split(line);
	if (w.empty())
		return;
	const std::string& cmd = w[0];
	auto num = [&](size_t i) -> long { return i < w.size() ? strtol(w[i].c_str(), nullptr, 10) : 0; };
	const bool input = g.connected && g.client && !g.flag("viewOnly");

	if (cmd == "size" && w.size() >= 3)
	{
		g.wantW = uint32_t(num(1));
		g.wantH = uint32_t(num(2));
		flush_resize();
	}
	else if (cmd == "mouse" && input)
		send_pointer(int(num(1)), int(num(2)));
	else if (cmd == "button" && input && w.size() >= 5)
	{
		// UI numbering: 1 left, 2 right, 3 middle, 4 back, 5 forward. RFB bits 0 1 2: left middle right.
		static const int masks[] = { 0, 1, 4, 2, 128, 256 };
		const long b = num(1);
		if (b >= 1 && b <= 5)
		{
			if (num(2))
				g.buttons |= masks[b];
			else
				g.buttons &= ~masks[b];
			send_pointer(int(num(3)), int(num(4)));
		}
	}
	else if (cmd == "wheel" && input && w.size() >= 5)
	{
		const int x = int(num(3)), y = int(num(4));
		// One button press per notch (120): 4 up, 5 down, 6 left, 7 right.
		for (long dy = num(1); dy >= 120 || dy <= -120; dy += dy > 0 ? -120 : 120)
			click(dy > 0 ? 8 : 16, x, y);
		for (long dx = num(2); dx >= 120 || dx <= -120; dx += dx > 0 ? -120 : 120)
			click(dx > 0 ? 32 : 64, x, y);
	}
	else if (cmd == "key" && input && w.size() >= 3)
	{
		const bool down = num(1) != 0;
		const uint32_t evdev = uint32_t(num(2));
		if (down)
		{
			const uint32_t keysym = w.size() >= 4 ? uint32_t(strtoul(w[3].c_str(), nullptr, 10)) : 0;
			if (keysym == 0)
				return;
			g.pressed[evdev] = keysym;
			SendKeyEvent(g.client, keysym, TRUE);
		}
		else
		{
			auto it = g.pressed.find(evdev);
			if (it == g.pressed.end())
				return;
			SendKeyEvent(g.client, it->second, FALSE);
			g.pressed.erase(it);
		}
	}
	else if (cmd == "cad" && input)
	{
		const uint32_t keys[] = { 0xffe3, 0xffe9, 0xffff }; // Control_L, Alt_L, Delete
		for (uint32_t k : keys)
			SendKeyEvent(g.client, k, TRUE);
		for (int i = 2; i >= 0; i--)
			SendKeyEvent(g.client, keys[i], FALSE);
	}
	else if (cmd == "clip" && w.size() >= 2)
		send_clipboard(unb64(w[1]));
	else if (cmd == "disconnect")
		g.quit = 1;
}

// ---------------------------------------------------------------- credentials

static bool stop_asking()
{
	return g.quit != 0;
}

// "auth <kind> <user> -"; the answer is "auth-answer <user> <domain> <password>".
static bool ask_credentials(const char* kind, std::string& user, std::string& password)
{
	const auto answer = split(
	    g.link.ask(std::string("auth ") + kind + " " + b64(user) + " -", "auth-answer", handle_line, stop_asking));
	if (answer.size() < 4)
		return false;
	user = unb64(answer[1]);
	password = unb64(answer[3]);
	return true;
}

static char* get_password(rfbClient*)
{
	std::string user = g.get("username");
	std::string password = g.get("password");
	if (password.empty() && !ask_credentials("vnc-password", user, password))
		return nullptr;
	g.cfg["password"] = password;
	return strdup(password.c_str());
}

static rfbCredential* get_credential(rfbClient*, int type)
{
	if (type != rfbCredentialTypeUser)
	{
		log("the server asks for an X.509 client certificate, which is not supported");
		return nullptr;
	}
	std::string user = g.get("username");
	std::string password = g.get("password");
	if ((user.empty() || password.empty()) && !ask_credentials("vnc-user", user, password))
		return nullptr;
	auto* cred = static_cast<rfbCredential*>(calloc(1, sizeof(rfbCredential)));
	cred->userCredential.username = strdup(user.c_str());
	cred->userCredential.password = strdup(password.c_str());
	return cred;
}

// ---------------------------------------------------------------- main

static void on_signal(int)
{
	g.quit = 1;
}

static void replay()
{
	g.link.send(g.connected ? "state connected" : "state connecting");
	if (g.connected)
	{
		g.link.sendFrame(g.frame);
		if (!g.cursorDef.empty())
			g.link.send(g.cursorDef);
		g.link.send(g.cursorState);
	}
}

int main()
{
	std::string line;
	while (std::getline(std::cin, line))
	{
		const size_t eq = line.find('=');
		if (eq != std::string::npos)
			g.cfg[line.substr(0, eq)] = line.substr(eq + 1);
	}
	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	signal(SIGPIPE, SIG_IGN);
	rfbClientLog = client_log;
	rfbClientErr = client_err;

	if (!g.link.listen(getenv("OMAREMOTE_SOCKET")))
		return 136;
	g.link.onAttach = replay;

	// 8 bits per sample, 3 samples, 4 bytes per pixel; the shifts make the memory order B G R X.
	rfbClient* client = rfbGetClient(8, 3, 4);
	client->format.redShift = 16;
	client->format.greenShift = 8;
	client->format.blueShift = 0;
	client->MallocFrameBuffer = malloc_framebuffer;
	client->canHandleNewFBSize = TRUE;
	client->GotFrameBufferUpdate = got_update;
	client->FinishedFrameBufferUpdate = finished_update;
	client->GotCursorShape = got_cursor;
	client->GotXCutText = got_cut_text;
	client->GotXCutTextUTF8 = got_cut_text_utf8;
	client->GetPassword = get_password;
	client->GetCredential = get_credential;
	client->appData.useRemoteCursor = TRUE;
	client->appData.shareDesktop = TRUE;
	client->connectTimeout = 15;

	const std::string quality = g.get("quality", "auto");
	if (quality == "high")
	{
		client->appData.encodingsString = "zrle hextile zlib copyrect raw";
		client->appData.compressLevel = 1;
		client->appData.enableJPEG = FALSE;
	}
	else if (quality == "low")
	{
		client->appData.encodingsString = "tight zrle copyrect hextile zlib raw";
		client->appData.compressLevel = 9;
		client->appData.qualityLevel = 3;
		client->appData.enableJPEG = TRUE;
	}
	else
	{
		client->appData.encodingsString = "tight zrle copyrect hextile zlib raw";
		client->appData.qualityLevel = 7;
		client->appData.enableJPEG = TRUE;
	}

	client->serverHost = strdup(g.get("host").c_str());
	client->serverPort = int(strtol(g.get("port", "5900").c_str(), nullptr, 10));
	log("connecting to %s:%d", client->serverHost, client->serverPort);

	// Connects and authenticates; on failure it frees the client itself.
	int argc = 0;
	if (!rfbInitClient(client, &argc, nullptr))
	{
		const int rc = g.quit ? 145 : g.authFailed ? 132 : 131;
		log("connection failed: %s", g.lastError.empty() ? "unknown error" : g.lastError.c_str());
		g.link.send("state failed " + std::to_string(rc));
		g.link.close();
		return rc;
	}
	g.client = client;
	g.connected = true;
	// The supervisor reads this line as "connected".
	log("connected to %s (%dx%d)", client->desktopName ? client->desktopName : "VNC server", client->width,
	    client->height);
	replay();

	int rc = 0;
	while (!g.quit)
	{
		// libvncclient may hold the next message already read from the socket.
		const int timeout = client->buffered > 0 ? 0 : 250;
		pollfd fds[3] = { { client->sock, POLLIN, 0 },
			              { g.link.listenFd(), POLLIN, 0 },
			              { g.link.clientFd(), POLLIN, 0 } };
		const int n = poll(fds, g.link.attached() ? 3 : 2, timeout);
		if (n < 0 && errno != EINTR)
			break;
		if (client->buffered > 0 || (fds[0].revents & (POLLIN | POLLHUP | POLLERR)))
		{
			if (!HandleRFBServerMessage(client))
			{
				rc = g.quit ? 11 : 147;
				break;
			}
		}
		for (const auto& l : g.link.poll())
			handle_line(l);
		flush_resize();
	}
	if (g.quit)
		rc = 11;
	log("session ended");
	g.link.send("state ended " + std::to_string(rc));
	rfbClientCleanup(client);
	g.link.close();
	return rc;
}
