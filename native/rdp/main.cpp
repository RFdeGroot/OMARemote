// omaremote-rdp: one RDP session, rendered for a tab in the omaremote window.
//
// libfreerdp draws into a shared-memory framebuffer (memfd). The UI connects to a Unix socket,
// receives the framebuffer as a file descriptor plus damage rectangles, and sends input back.
// The session outlives the UI: a new connection to the socket reattaches it.
//
// Arguments arrive one per line on stdin, exactly as for `sdl-freerdp3 /args-from:stdin`, so the
// supervisor (bin/omaremote-session) builds them the same way for both. The socket path comes
// from OMAREMOTE_SOCKET.
//
// Protocol: newline-terminated text lines, binary fields base64. See native/PROTOCOL.md.

#include "../common/link.hpp"

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/disp.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/channels/disp.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/graphics.h>
#include <freerdp/codec/color.h>
#include <freerdp/crypto/crypto.h>
#include <freerdp/event.h>
#include <freerdp/input.h>
#include <freerdp/error.h>
#include <freerdp/utils/signal.h>
#include <winpr/synch.h>
#include <winpr/wlog.h>
#include <winpr/string.h>
#include <winpr/sysinfo.h>

#include <fcntl.h>
#include <poll.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#define TAG "com.omaremote"

static constexpr UINT32 kFormat = PIXEL_FORMAT_BGRX32;

// ---------------------------------------------------------------- state

struct State
{
	oma::Link link;
	HANDLE listenEvent = nullptr;
	HANDLE clientEvent = nullptr;

	// Current framebuffer. Old ones are unmapped by gdi through oma::fb_release.
	oma::Framebuffer frame;
	BYTE* fb = nullptr;
	UINT32 width = 0;
	UINT32 height = 0;
	bool connected = false;

	DispClientContext* disp = nullptr;
	bool dispReady = false;
	UINT32 wantW = 0, wantH = 0, wantScale = 0; // last size asked for by the UI
	UINT32 sentW = 0, sentH = 0, sentScale = 0;
	UINT64 lastLayoutAt = 0;

	CliprdrClientContext* clip = nullptr;
	bool clipReady = false;
	std::string localClip;  // UTF-8 text the UI last copied
	std::string remoteClip; // UTF-8 text last received from the server

	// Cursor definitions by id, replayed when a UI attaches.
	std::map<UINT32, std::string> cursors;
	UINT32 nextCursor = 1;
	std::string cursorState = "cursor-default";

	bool quit = false;
};

struct OmaContext
{
	rdpClientContext common;
	State* st;
};

struct OmaPointer
{
	rdpPointer pointer;
	UINT32 id;
};

static State* state_of(rdpContext* ctx)
{
	return reinterpret_cast<OmaContext*>(ctx)->st;
}

using oma::b64;
using oma::now_ms;
using oma::split;
using oma::unb64;

// ---------------------------------------------------------------- link to the UI

static void send_line(State* st, const std::string& text, int fd = -1)
{
	st->link.send(text, fd);
}

static void send_frame(State* st)
{
	st->link.sendFrame(st->frame);
}

// What a UI that attaches mid-session needs to catch up.
static void replay(State* st)
{
	send_line(st, st->connected ? "state connected" : "state connecting");
	if (st->connected)
	{
		send_frame(st);
		for (const auto& [id, def] : st->cursors)
			send_line(st, def);
		send_line(st, st->cursorState);
	}
}

static bool open_socket(State* st)
{
	if (!st->link.listen(getenv("OMAREMOTE_SOCKET")))
		return false;
	st->listenEvent = CreateFileDescriptorEventW(nullptr, FALSE, FALSE, st->link.listenFd(), WINPR_FD_READ);
	st->link.onAttach = [st] { replay(st); };
	// The main loop waits on the client's descriptor through a winpr event; keep it current.
	st->link.onClientChanged = [st] {
		if (st->clientEvent)
			CloseHandle(st->clientEvent);
		st->clientEvent = st->link.attached()
		                      ? CreateFileDescriptorEventW(nullptr, FALSE, FALSE, st->link.clientFd(), WINPR_FD_READ)
		                      : nullptr;
	};
	return true;
}

// ---------------------------------------------------------------- framebuffer

static void fb_free(void* p)
{
	oma::fb_release(p);
}

static BYTE* fb_alloc(State* st, UINT32 w, UINT32 h)
{
	oma::Framebuffer fb = oma::fb_alloc(w, h);
	if (!fb.data)
		return nullptr;
	st->frame = fb;
	st->fb = fb.data;
	st->width = w;
	st->height = h;
	return st->fb;
}

// ---------------------------------------------------------------- display control

// Asks the server for a new desktop size and scale. Windows dislikes bursts, so changes are
// spaced at least a second apart; the main loop retries what is still pending.
static void flush_layout(State* st)
{
	if (!st->disp || !st->dispReady || !st->connected || st->wantW == 0)
		return;
	UINT32 w = std::min<UINT32>(8192, std::max<UINT32>(200, st->wantW)) & ~1u;
	UINT32 h = std::min<UINT32>(8192, std::max<UINT32>(200, st->wantH));
	UINT32 scale = std::min<UINT32>(500, std::max<UINT32>(100, st->wantScale));
	if (w == st->sentW && h == st->sentH && scale == st->sentScale)
		return;
	if (now_ms() - st->lastLayoutAt < 1000)
		return;
	DISPLAY_CONTROL_MONITOR_LAYOUT layout = {};
	layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
	layout.Width = w;
	layout.Height = h;
	layout.Orientation = ORIENTATION_LANDSCAPE;
	layout.DesktopScaleFactor = scale;
	layout.DeviceScaleFactor = scale < 120 ? 100 : (scale < 160 ? 140 : 180);
	// Physical size consistent with the scale: Windows derives DPI from it on some versions.
	layout.PhysicalWidth = static_cast<UINT32>(w * 25.4 / (96.0 * scale / 100.0));
	layout.PhysicalHeight = static_cast<UINT32>(h * 25.4 / (96.0 * scale / 100.0));
	const UINT rc = st->disp->SendMonitorLayout(st->disp, 1, &layout);
	st->lastLayoutAt = now_ms();
	if (rc == CHANNEL_RC_OK)
	{
		st->sentW = w;
		st->sentH = h;
		st->sentScale = scale;
		WLog_INFO(TAG, "requested desktop %" PRIu32 "x%" PRIu32 " at %" PRIu32 "%%", w, h, scale);
	}
}

static UINT disp_caps(DispClientContext* disp, UINT32, UINT32, UINT32)
{
	State* st = state_of(static_cast<rdpContext*>(disp->custom));
	st->dispReady = true;
	return CHANNEL_RC_OK;
}

// ---------------------------------------------------------------- clipboard (text)

static UINT clip_send_format_list(State* st)
{
	CLIPRDR_FORMAT format = { CF_UNICODETEXT, nullptr };
	CLIPRDR_FORMAT_LIST list = {};
	list.common.msgType = CB_FORMAT_LIST;
	list.numFormats = st->localClip.empty() ? 0 : 1;
	list.formats = &format;
	return st->clip->ClientFormatList(st->clip, &list);
}

static UINT clip_monitor_ready(CliprdrClientContext* clip, const CLIPRDR_MONITOR_READY*)
{
	State* st = state_of(static_cast<rdpContext*>(clip->custom));
	CLIPRDR_GENERAL_CAPABILITY_SET general = {};
	general.capabilitySetType = CB_CAPSTYPE_GENERAL;
	general.capabilitySetLength = 12;
	general.version = CB_CAPS_VERSION_2;
	general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
	CLIPRDR_CAPABILITIES caps = {};
	caps.cCapabilitiesSets = 1;
	caps.capabilitySets = reinterpret_cast<CLIPRDR_CAPABILITY_SET*>(&general);
	UINT rc = clip->ClientCapabilities(clip, &caps);
	if (rc != CHANNEL_RC_OK)
		return rc;
	st->clipReady = true;
	return clip_send_format_list(st);
}

static UINT clip_server_caps(CliprdrClientContext*, const CLIPRDR_CAPABILITIES*)
{
	return CHANNEL_RC_OK;
}

static UINT clip_server_format_list(CliprdrClientContext* clip, const CLIPRDR_FORMAT_LIST* list)
{
	CLIPRDR_FORMAT_LIST_RESPONSE response = {};
	response.common.msgType = CB_FORMAT_LIST_RESPONSE;
	response.common.msgFlags = CB_RESPONSE_OK;
	UINT rc = clip->ClientFormatListResponse(clip, &response);
	for (UINT32 i = 0; rc == CHANNEL_RC_OK && i < list->numFormats; i++)
	{
		if (list->formats[i].formatId == CF_UNICODETEXT)
		{
			CLIPRDR_FORMAT_DATA_REQUEST request = {};
			request.common.msgType = CB_FORMAT_DATA_REQUEST;
			request.requestedFormatId = CF_UNICODETEXT;
			return clip->ClientFormatDataRequest(clip, &request);
		}
	}
	return rc;
}

static UINT clip_server_format_list_response(CliprdrClientContext*, const CLIPRDR_FORMAT_LIST_RESPONSE*)
{
	return CHANNEL_RC_OK;
}

static UINT clip_server_data_request(CliprdrClientContext* clip, const CLIPRDR_FORMAT_DATA_REQUEST* request)
{
	State* st = state_of(static_cast<rdpContext*>(clip->custom));
	CLIPRDR_FORMAT_DATA_RESPONSE response = {};
	response.common.msgType = CB_FORMAT_DATA_RESPONSE;
	WCHAR* wide = nullptr;
	size_t chars = 0;
	if (request->requestedFormatId == CF_UNICODETEXT && !st->localClip.empty())
		wide = ConvertUtf8NToWCharAlloc(st->localClip.data(), st->localClip.size(), &chars);
	if (wide)
	{
		response.common.msgFlags = CB_RESPONSE_OK;
		response.common.dataLen = static_cast<UINT32>((chars + 1) * sizeof(WCHAR));
		response.requestedFormatData = reinterpret_cast<const BYTE*>(wide);
	}
	else
		response.common.msgFlags = CB_RESPONSE_FAIL;
	const UINT rc = clip->ClientFormatDataResponse(clip, &response);
	free(wide);
	return rc;
}

static UINT clip_server_data_response(CliprdrClientContext* clip, const CLIPRDR_FORMAT_DATA_RESPONSE* response)
{
	State* st = state_of(static_cast<rdpContext*>(clip->custom));
	if (response->common.msgFlags != CB_RESPONSE_OK || response->common.dataLen < 2)
		return CHANNEL_RC_OK;
	size_t len = 0;
	char* utf8 = ConvertWCharNToUtf8Alloc(reinterpret_cast<const WCHAR*>(response->requestedFormatData),
	                                      response->common.dataLen / sizeof(WCHAR), &len);
	if (!utf8)
		return CHANNEL_RC_OK;
	std::string text(utf8, strnlen(utf8, len));
	free(utf8);
	// Windows line endings stay as they are: Linux apps cope, and a round trip stays exact.
	// The remote now holds the clipboard: copying the last local text again must reach it.
	st->remoteClip = text;
	st->localClip.clear();
	send_line(st, "clip " + b64(text));
	return CHANNEL_RC_OK;
}

// ---------------------------------------------------------------- channels

static void on_channel_connected(void* context, const ChannelConnectedEventArgs* e)
{
	auto* ctx = static_cast<rdpContext*>(context);
	State* st = state_of(ctx);
	if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0)
	{
		st->disp = static_cast<DispClientContext*>(e->pInterface);
		st->disp->custom = ctx;
		st->disp->DisplayControlCaps = disp_caps;
	}
	else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
	{
		st->clip = static_cast<CliprdrClientContext*>(e->pInterface);
		st->clip->custom = ctx;
		st->clip->MonitorReady = clip_monitor_ready;
		st->clip->ServerCapabilities = clip_server_caps;
		st->clip->ServerFormatList = clip_server_format_list;
		st->clip->ServerFormatListResponse = clip_server_format_list_response;
		st->clip->ServerFormatDataRequest = clip_server_data_request;
		st->clip->ServerFormatDataResponse = clip_server_data_response;
	}
	else
		freerdp_client_OnChannelConnectedEventHandler(context, e);
}

static void on_channel_disconnected(void* context, const ChannelDisconnectedEventArgs* e)
{
	State* st = state_of(static_cast<rdpContext*>(context));
	if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0)
	{
		st->disp = nullptr;
		st->dispReady = false;
	}
	else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
	{
		st->clip = nullptr;
		st->clipReady = false;
	}
	else
		freerdp_client_OnChannelDisconnectedEventHandler(context, e);
}

// ---------------------------------------------------------------- input

// Linux evdev keycodes match PC/AT set 1 scancodes below 89; above that, and for the keys that
// need the E0 prefix, this table says what to send.
static UINT32 rdp_scancode(UINT32 evdev)
{
	switch (evdev)
	{
		case 96: return 0x1C | KBD_FLAGS_EXTENDED;  // KP Enter
		case 97: return 0x1D | KBD_FLAGS_EXTENDED;  // Right Ctrl
		case 98: return 0x35 | KBD_FLAGS_EXTENDED;  // KP /
		case 99: return 0x37 | KBD_FLAGS_EXTENDED;  // Print Screen
		case 100: return 0x38 | KBD_FLAGS_EXTENDED; // Right Alt
		case 102: return 0x47 | KBD_FLAGS_EXTENDED; // Home
		case 103: return 0x48 | KBD_FLAGS_EXTENDED; // Up
		case 104: return 0x49 | KBD_FLAGS_EXTENDED; // Page Up
		case 105: return 0x4B | KBD_FLAGS_EXTENDED; // Left
		case 106: return 0x4D | KBD_FLAGS_EXTENDED; // Right
		case 107: return 0x4F | KBD_FLAGS_EXTENDED; // End
		case 108: return 0x50 | KBD_FLAGS_EXTENDED; // Down
		case 109: return 0x51 | KBD_FLAGS_EXTENDED; // Page Down
		case 110: return 0x52 | KBD_FLAGS_EXTENDED; // Insert
		case 111: return 0x53 | KBD_FLAGS_EXTENDED; // Delete
		case 113: return 0x20 | KBD_FLAGS_EXTENDED; // Mute
		case 114: return 0x2E | KBD_FLAGS_EXTENDED; // Volume Down
		case 115: return 0x30 | KBD_FLAGS_EXTENDED; // Volume Up
		case 117: return 0x59;                      // KP =
		case 119: return 0x45;                      // Pause (approximation)
		case 121: return 0x7E;                      // KP ,
		case 122: return 0x72;                      // Hangeul
		case 123: return 0x71;                      // Hanja
		case 124: return 0x7D;                      // Yen
		case 125: return 0x5B | KBD_FLAGS_EXTENDED; // Left Super
		case 126: return 0x5C | KBD_FLAGS_EXTENDED; // Right Super
		case 127: return 0x5D | KBD_FLAGS_EXTENDED; // Menu
		case 89: return 0x73;                       // RO
		case 92: return 0x79;                       // Henkan
		case 93: return 0x70;                       // Katakana/Hiragana
		case 94: return 0x7B;                       // Muhenkan
		default: return evdev < 89 ? evdev : 0;
	}
}

static void send_wheel(rdpInput* input, UINT16 axisFlag, int delta, UINT16 x, UINT16 y)
{
	while (delta != 0)
	{
		const int step = std::max(-255, std::min(255, delta));
		UINT16 flags = axisFlag;
		if (step < 0)
			flags |= PTR_FLAGS_WHEEL_NEGATIVE | static_cast<UINT16>((0x100 + step) & 0xFF);
		else
			flags |= static_cast<UINT16>(step & 0xFF);
		freerdp_input_send_mouse_event(input, flags, x, y);
		delta -= step;
	}
}

static void handle_line(rdpContext* ctx, const std::string& line)
{
	State* st = state_of(ctx);
	const auto w = split(line);
	if (w.empty())
		return;
	const std::string& cmd = w[0];
	auto num = [&](size_t i) -> long { return i < w.size() ? strtol(w[i].c_str(), nullptr, 10) : 0; };
	rdpInput* input = ctx->input;
	const bool live = st->connected && input;

	if (cmd == "size" && w.size() >= 4)
	{
		st->wantW = static_cast<UINT32>(num(1));
		st->wantH = static_cast<UINT32>(num(2));
		st->wantScale = static_cast<UINT32>(num(3));
		flush_layout(st);
	}
	else if (cmd == "mouse" && live)
		freerdp_input_send_mouse_event(input, PTR_FLAGS_MOVE, static_cast<UINT16>(num(1)), static_cast<UINT16>(num(2)));
	else if (cmd == "button" && live && w.size() >= 5)
	{
		const long b = num(1);
		const bool down = num(2) != 0;
		const auto x = static_cast<UINT16>(num(3)), y = static_cast<UINT16>(num(4));
		if (b >= 1 && b <= 3)
		{
			const UINT16 flag = b == 1 ? PTR_FLAGS_BUTTON1 : b == 2 ? PTR_FLAGS_BUTTON2 : PTR_FLAGS_BUTTON3;
			freerdp_input_send_mouse_event(input, flag | (down ? PTR_FLAGS_DOWN : 0), x, y);
		}
		else if (b == 4 || b == 5)
			freerdp_input_send_extended_mouse_event(
			    input, (b == 4 ? PTR_XFLAGS_BUTTON1 : PTR_XFLAGS_BUTTON2) | (down ? PTR_XFLAGS_DOWN : 0), x, y);
	}
	else if (cmd == "wheel" && live && w.size() >= 5)
	{
		const auto x = static_cast<UINT16>(num(3)), y = static_cast<UINT16>(num(4));
		send_wheel(input, PTR_FLAGS_WHEEL, static_cast<int>(num(1)), x, y);
		send_wheel(input, PTR_FLAGS_HWHEEL, -static_cast<int>(num(2)), x, y);
	}
	else if (cmd == "key" && live && w.size() >= 3)
	{
		const UINT32 code = rdp_scancode(static_cast<UINT32>(num(2)));
		if (code)
			freerdp_input_send_keyboard_event_ex(input, num(1) != 0, FALSE, code);
	}
	else if (cmd == "focus" && live && w.size() >= 2)
		freerdp_input_send_focus_in_event(input, static_cast<UINT16>(num(1)));
	else if (cmd == "cad" && live)
	{
		const UINT32 keys[] = { 0x1D, 0x38, 0x53 | KBD_FLAGS_EXTENDED };
		for (UINT32 k : keys)
			freerdp_input_send_keyboard_event_ex(input, TRUE, FALSE, k);
		for (int i = 2; i >= 0; i--)
			freerdp_input_send_keyboard_event_ex(input, FALSE, FALSE, keys[i]);
	}
	else if (cmd == "clip" && w.size() >= 2)
	{
		std::string text = unb64(w[1]);
		if (text == st->localClip || text == st->remoteClip)
			return; // our own echo, or nothing new
		st->localClip = text;
		st->remoteClip.clear();
		if (st->clip && st->clipReady)
			clip_send_format_list(st);
	}
	else if (cmd == "disconnect")
	{
		st->quit = true;
		freerdp_abort_connect_context(ctx);
	}
}

static std::vector<std::string> read_lines(State* st)
{
	return st->link.poll();
}

// Blocks the session until the UI answers a question, still serving everything else it sends.
// Returns the answering line, or "" when the wait was given up (5 minutes, or disconnect).
static std::string ask(rdpContext* ctx, const std::string& question, const std::string& answerPrefix)
{
	State* st = state_of(ctx);
	return st->link.ask(question, answerPrefix, [ctx](const std::string& line) { handle_line(ctx, line); },
	                    [st] { return st->quit; });
}

// ---------------------------------------------------------------- callbacks

static BOOL begin_paint(rdpContext* ctx)
{
	ctx->gdi->primary->hdc->hwnd->invalid->null = TRUE;
	return TRUE;
}

static BOOL end_paint(rdpContext* ctx)
{
	State* st = state_of(ctx);
	HGDI_RGN invalid = ctx->gdi->primary->hdc->hwnd->invalid;
	if (invalid->null)
		return TRUE;
	send_line(st, "damage " + std::to_string(invalid->x) + " " + std::to_string(invalid->y) + " " +
	                  std::to_string(invalid->w) + " " + std::to_string(invalid->h));
	return TRUE;
}

static BOOL desktop_resize(rdpContext* ctx)
{
	State* st = state_of(ctx);
	const UINT32 w = freerdp_settings_get_uint32(ctx->settings, FreeRDP_DesktopWidth);
	const UINT32 h = freerdp_settings_get_uint32(ctx->settings, FreeRDP_DesktopHeight);
	if (w == st->width && h == st->height)
		return TRUE;
	BYTE* buffer = fb_alloc(st, w, h);
	if (!buffer || !gdi_resize_ex(ctx->gdi, w, h, w * 4, kFormat, buffer, fb_free))
		return FALSE;
	WLog_INFO(TAG, "desktop is now %" PRIu32 "x%" PRIu32, w, h);
	send_frame(st);
	return TRUE;
}

static BOOL pointer_new(rdpContext* ctx, rdpPointer* pointer)
{
	State* st = state_of(ctx);
	auto* p = reinterpret_cast<OmaPointer*>(pointer);
	p->id = st->nextCursor++;
	const UINT32 w = pointer->width, h = pointer->height;
	std::string pixels(static_cast<size_t>(w) * h * 4, '\0');
	if (w && h &&
	    !freerdp_image_copy_from_pointer_data(reinterpret_cast<BYTE*>(pixels.data()), PIXEL_FORMAT_BGRA32, w * 4, 0,
	                                          0, w, h, pointer->xorMaskData, pointer->lengthXorMask,
	                                          pointer->andMaskData, pointer->lengthAndMask, pointer->xorBpp,
	                                          &ctx->gdi->palette))
		return FALSE;
	std::string def = "cursor " + std::to_string(p->id) + " " + std::to_string(pointer->xPos) + " " +
	                  std::to_string(pointer->yPos) + " " + std::to_string(w) + " " + std::to_string(h) + " " +
	                  b64(pixels);
	st->cursors[p->id] = def;
	send_line(st, def);
	return TRUE;
}

static void pointer_free(rdpContext* ctx, rdpPointer* pointer)
{
	State* st = state_of(ctx);
	auto* p = reinterpret_cast<OmaPointer*>(pointer);
	st->cursors.erase(p->id);
}

static BOOL pointer_set(rdpContext* ctx, rdpPointer* pointer)
{
	State* st = state_of(ctx);
	st->cursorState = "cursor-set " + std::to_string(reinterpret_cast<OmaPointer*>(pointer)->id);
	send_line(st, st->cursorState);
	return TRUE;
}

static BOOL pointer_set_null(rdpContext* ctx)
{
	State* st = state_of(ctx);
	st->cursorState = "cursor-hide";
	send_line(st, st->cursorState);
	return TRUE;
}

static BOOL pointer_set_default(rdpContext* ctx)
{
	State* st = state_of(ctx);
	st->cursorState = "cursor-default";
	send_line(st, st->cursorState);
	return TRUE;
}

static BOOL pointer_set_position(rdpContext*, UINT32, UINT32)
{
	return TRUE;
}

static DWORD verify_certificate(freerdp* instance, const char* host, UINT16 port, const char* commonName,
                                const char* subject, const char* issuer, const char* fingerprint, DWORD flags)
{
	// FreeRDP reports a certificate that differs from the stored one here too, flagged CHANGED.
	const char* changed = (flags & VERIFY_CERT_FLAG_CHANGED) ? "1 " : "0 ";
	const std::string q = std::string("cert ") + changed + b64(host ? host : "") + " " + std::to_string(port) + " " +
	                      b64(commonName ? commonName : "") + " " + b64(subject ? subject : "") + " " +
	                      b64(issuer ? issuer : "") + " " + b64(fingerprint ? fingerprint : "");
	const auto answer = split(ask(instance->context, q, "cert-answer"));
	return answer.size() >= 2 ? static_cast<DWORD>(strtoul(answer[1].c_str(), nullptr, 10)) : 0;
}

static DWORD verify_changed_certificate(freerdp* instance, const char* host, UINT16 port, const char* commonName,
                                        const char* subject, const char* issuer, const char* fingerprint,
                                        const char*, const char*, const char*, DWORD)
{
	const std::string q = "cert 1 " + b64(host ? host : "") + " " + std::to_string(port) + " " +
	                      b64(commonName ? commonName : "") + " " + b64(subject ? subject : "") + " " +
	                      b64(issuer ? issuer : "") + " " + b64(fingerprint ? fingerprint : "");
	const auto answer = split(ask(instance->context, q, "cert-answer"));
	return answer.size() >= 2 ? static_cast<DWORD>(strtoul(answer[1].c_str(), nullptr, 10)) : 0;
}

static void replace(char** field, const std::string& value)
{
	free(*field);
	*field = value.empty() ? nullptr : _strdup(value.c_str());
}

static BOOL authenticate(freerdp* instance, char** username, char** password, char** domain,
                         rdp_auth_reason reason)
{
	const bool gateway = reason == GW_AUTH_HTTP || reason == GW_AUTH_RDG || reason == GW_AUTH_RPC;
	if (!gateway && reason != AUTH_NLA && reason != AUTH_RDSTLS && *username && *password)
		return TRUE;
	if (*username && *password && **password)
		return TRUE;
	const std::string kind = gateway ? "gateway" : reason == AUTH_SMARTCARD_PIN ? "pin" : "server";
	const std::string q = "auth " + kind + " " + b64(*username ? *username : "") + " " + b64(*domain ? *domain : "");
	const auto answer = split(ask(instance->context, q, "auth-answer"));
	if (answer.size() < 4)
	{
		freerdp_set_last_error_if_not(instance->context, FREERDP_ERROR_CONNECT_CANCELLED);
		return FALSE;
	}
	replace(username, unb64(answer[1]));
	replace(domain, unb64(answer[2]));
	replace(password, unb64(answer[3]));
	return TRUE;
}

static int logon_error_info(freerdp* instance, UINT32 data, UINT32 type)
{
	WLog_INFO(TAG, "logon error info %s [%s]", freerdp_get_logon_error_info_data(data),
	          freerdp_get_logon_error_info_type(type));
	(void)instance;
	return 1;
}

static BOOL pre_connect(freerdp* instance)
{
	rdpSettings* settings = instance->context->settings;
	if (!freerdp_settings_set_uint32(settings, FreeRDP_OsMajorType, OSMAJORTYPE_UNIX) ||
	    !freerdp_settings_set_uint32(settings, FreeRDP_OsMinorType, OSMINORTYPE_NATIVE_WAYLAND))
		return FALSE;
	PubSub_SubscribeChannelConnected(instance->context->pubSub, on_channel_connected);
	PubSub_SubscribeChannelDisconnected(instance->context->pubSub, on_channel_disconnected);
	return TRUE;
}

static BOOL post_connect(freerdp* instance)
{
	rdpContext* ctx = instance->context;
	State* st = state_of(ctx);
	const UINT32 w = freerdp_settings_get_uint32(ctx->settings, FreeRDP_DesktopWidth);
	const UINT32 h = freerdp_settings_get_uint32(ctx->settings, FreeRDP_DesktopHeight);
	BYTE* buffer = fb_alloc(st, w, h);
	if (!buffer || !gdi_init_ex(instance, kFormat, w * 4, buffer, fb_free))
		return FALSE;

	rdpPointer pointer = {};
	pointer.size = sizeof(OmaPointer);
	pointer.New = pointer_new;
	pointer.Free = pointer_free;
	pointer.Set = pointer_set;
	pointer.SetNull = pointer_set_null;
	pointer.SetDefault = pointer_set_default;
	pointer.SetPosition = pointer_set_position;
	graphics_register_pointer(ctx->graphics, &pointer);

	ctx->update->BeginPaint = begin_paint;
	ctx->update->EndPaint = end_paint;
	ctx->update->DesktopResize = desktop_resize;

	st->connected = true;
	send_line(st, "state connected");
	send_frame(st);
	return TRUE;
}

static void post_disconnect(freerdp* instance)
{
	PubSub_UnsubscribeChannelConnected(instance->context->pubSub, on_channel_connected);
	PubSub_UnsubscribeChannelDisconnected(instance->context->pubSub, on_channel_disconnected);
	gdi_free(instance);
}

static BOOL client_new(freerdp* instance, rdpContext* context)
{
	reinterpret_cast<OmaContext*>(context)->st = new State();
	instance->PreConnect = pre_connect;
	instance->PostConnect = post_connect;
	instance->PostDisconnect = post_disconnect;
	instance->AuthenticateEx = authenticate;
	instance->VerifyCertificateEx = verify_certificate;
	instance->VerifyChangedCertificateEx = verify_changed_certificate;
	instance->LogonErrorInfo = logon_error_info;
	return TRUE;
}

static void client_free(freerdp*, rdpContext* context)
{
	delete reinterpret_cast<OmaContext*>(context)->st;
}

static int entry_points(RDP_CLIENT_ENTRY_POINTS* ep)
{
	ZeroMemory(ep, sizeof(RDP_CLIENT_ENTRY_POINTS));
	ep->Version = RDP_CLIENT_INTERFACE_VERSION;
	ep->Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
	ep->ContextSize = sizeof(OmaContext);
	ep->ClientNew = client_new;
	ep->ClientFree = client_free;
	return 0;
}

// ---------------------------------------------------------------- exit codes

// The same numbers sdl-freerdp3 uses, so the supervisor describes both clients alike.
static int exit_code_for(rdpContext* ctx)
{
	const UINT32 error = freerdp_get_last_error(ctx);
	struct
	{
		UINT32 error;
		int code;
	} static const map[] = {
		{ FREERDP_ERROR_AUTHENTICATION_FAILED, 132 },
		{ FREERDP_ERROR_SECURITY_NEGO_CONNECT_FAILED, 133 },
		{ FREERDP_ERROR_CONNECT_LOGON_FAILURE, 134 },
		{ FREERDP_ERROR_CONNECT_ACCOUNT_LOCKED_OUT, 135 },
		{ FREERDP_ERROR_PRE_CONNECT_FAILED, 136 },
		{ FREERDP_ERROR_POST_CONNECT_FAILED, 138 },
		{ FREERDP_ERROR_DNS_ERROR, 139 },
		{ FREERDP_ERROR_DNS_NAME_NOT_FOUND, 140 },
		{ FREERDP_ERROR_CONNECT_FAILED, 141 },
		{ FREERDP_ERROR_TLS_CONNECT_FAILED, 143 },
		{ FREERDP_ERROR_INSUFFICIENT_PRIVILEGES, 144 },
		{ FREERDP_ERROR_CONNECT_CANCELLED, 145 },
		{ FREERDP_ERROR_CONNECT_TRANSPORT_FAILED, 147 },
		{ FREERDP_ERROR_CONNECT_PASSWORD_EXPIRED, 148 },
		{ FREERDP_ERROR_CONNECT_PASSWORD_MUST_CHANGE, 149 },
		{ FREERDP_ERROR_CONNECT_KDC_UNREACHABLE, 150 },
		{ FREERDP_ERROR_CONNECT_ACCOUNT_DISABLED, 151 },
		{ FREERDP_ERROR_CONNECT_WRONG_PASSWORD, 154 },
		{ FREERDP_ERROR_CONNECT_ACCESS_DENIED, 155 },
		{ FREERDP_ERROR_CONNECT_ACCOUNT_RESTRICTION, 156 },
		{ FREERDP_ERROR_CONNECT_ACCOUNT_EXPIRED, 157 },
		{ FREERDP_ERROR_CONNECT_LOGON_TYPE_NOT_GRANTED, 158 },
		{ FREERDP_ERROR_CONNECT_NO_OR_MISSING_CREDENTIALS, 159 },
	};
	if (error != FREERDP_ERROR_SUCCESS)
	{
		WLog_ERR(TAG, "%s: %s", freerdp_get_last_error_name(error), freerdp_get_last_error_string(error));
		for (const auto& m : map)
			if (m.error == error)
				return m.code;
	}
	const UINT32 info = freerdp_error_info(ctx->instance);
	if (info == ERRINFO_LOGOFF_BY_USER || info == ERRINFO_RPC_INITIATED_DISCONNECT_BY_USER)
		return 2;
	if (info != ERRINFO_SUCCESS && info != ERRINFO_NONE)
	{
		WLog_ERR(TAG, "%s: %s", freerdp_get_error_info_name(info), freerdp_get_error_info_string(info));
		return info < 0x100 ? 32 + static_cast<int>(info) : 1;
	}
	return error == FREERDP_ERROR_SUCCESS ? 0 : 131;
}

// ---------------------------------------------------------------- main

int main(int argc, char** argv)
{
	// Without arguments, FreeRDP reads them from stdin itself (one per line), so credentials
	// never appear in the process list.
	char stdinArg[] = "/args-from:stdin";
	std::vector<char*> cargs(argv, argv + argc);
	if (argc == 1)
		cargs.push_back(stdinArg);

	RDP_CLIENT_ENTRY_POINTS ep = {};
	entry_points(&ep);
	rdpContext* ctx = freerdp_client_context_new(&ep);
	if (!ctx)
		return 129;
	State* st = state_of(ctx);
	int rc = 0;

	const int status = freerdp_client_settings_parse_command_line(ctx->settings, static_cast<int>(cargs.size()),
	                                                              cargs.data(), FALSE);
	if (status != 0)
	{
		freerdp_client_context_free(ctx);
		return 128;
	}
	if (!open_socket(st) || freerdp_client_start(ctx) != 0)
	{
		freerdp_client_context_free(ctx);
		return 136;
	}

	freerdp* instance = ctx->instance;
	if (!freerdp_connect(instance))
	{
		rc = exit_code_for(ctx);
		send_line(st, "state failed " + std::to_string(rc));
	}
	else
	{
		while (!freerdp_shall_disconnect_context(ctx) && !st->quit)
		{
			HANDLE handles[MAXIMUM_WAIT_OBJECTS] = {};
			DWORD n = freerdp_get_event_handles(ctx, handles, MAXIMUM_WAIT_OBJECTS - 2);
			if (n == 0)
				break;
			handles[n++] = st->listenEvent;
			if (st->clientEvent)
				handles[n++] = st->clientEvent;
			if (WaitForMultipleObjects(n, handles, FALSE, 250) == WAIT_FAILED)
				break;
			if (!freerdp_check_event_handles(ctx))
			{
				if (client_auto_reconnect_ex(instance, nullptr))
					continue;
				break;
			}
			for (const auto& line : read_lines(st))
				handle_line(ctx, line);
			flush_layout(st);
		}
		rc = st->quit ? 11 : exit_code_for(ctx);
		send_line(st, "state ended " + std::to_string(rc));
		freerdp_disconnect(instance);
	}

	freerdp_client_stop(ctx);
	st->link.close();
	freerdp_client_context_free(ctx);
	return rc;
}
