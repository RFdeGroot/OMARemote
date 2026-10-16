// omaremote-gliff: one Gliff session (an Omarchy/Hyprland desktop over ssh), rendered for a tab in
// the OMARemote window.
//
// Gliff's own client runs `ssh ... host gliff-server --stdio` and speaks Gliff's protocol over the
// pipe (native/gliff/msg.hpp). This process does the same: H.264 from the server is decoded with
// libavcodec and converted (BT.709, limited range) into the shared-memory framebuffer the UI maps,
// over the socket protocol every session process speaks (native/common/link.hpp).
//
// With VA-API and a UI that says "gpu 1", no pixel passes through here: each decoded surface goes
// to the UI once as a dmabuf ("surface"), every picture after that is one "show" line naming its
// surfaces, and the UI converts on its GPU (plugin/yuvnode.cpp), as Gliff's own client does. The
// pictures shown stay referenced (so the decoder leaves their surfaces alone) until the UI sends
// "release".
//
// Settings arrive as key=value lines on stdin: arg (repeated: the whole ssh command line, built by
// omaremote-session), host, and headless (1: the server draws the cursor into the picture).

#include "../common/link.hpp"
#include "clipboard.hpp"
#include "msg.hpp"
#include "seat.hpp"
#include "video.hpp"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_vaapi.h>
}

#include <drm_fourcc.h>
#include <va/va_drmcommon.h>

#include <fcntl.h>
#include <poll.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <iostream>
#include <map>
#include <memory>
#include <set>
#include <thread>
#include <string>
#include <vector>

using oma::b64;
using oma::log;
using oma::split;

// ---------------------------------------------------------------- state

// One H.264 stream's decoder: pic is the newest picture (on the GPU with VA-API, then sw holds
// its download), tmp takes the next.
struct Stream
{
	AVCodecContext* ctx = nullptr;
	AVFrame* pic = nullptr;
	AVFrame* tmp = nullptr;
	AVFrame* sw = nullptr;
	bool got = false;
};

struct Session
{
	std::map<std::string, std::string> cfg;
	std::vector<std::string> args;
	oma::Link link;
	volatile sig_atomic_t quit = 0;

	pid_t child = -1;
	int toServer = -1, fromServer = -1, serverErr = -1;
	std::string inbuf;  // read from the server, not yet a whole frame
	std::string outbuf; // to the server, not yet written
	std::string errTail; // ssh's and gliff-server's last words, for a failure

	bool welcomed = false; // HelloAck arrived
	bool connected = false; // the first picture is drawn
	bool headless = false;
	gliff::StreamConfig stream;
	bool haveStream = false;

	AVBufferRef* hw = nullptr; // the VA-API device, when there is one
	bool hwBroken = false;
	int hwErrors = 0;
	Stream main, aux; // aux: Dual420's second picture
	AVPacket* pkt = nullptr;
	oma::Framebuffer frame;
	bool shmStale = false; // pictures went to the UI as dmabufs: the framebuffer is behind
	bool needKeyframe = false;

	// Pictures as dmabufs (the UI said "gpu 1"): the surfaces it has, and the pictures it may be
	// drawing (by "show" number: main and aux, referenced until "release").
	bool gpuView = false;
	std::set<VASurfaceID> exported;
	const void* exportedPools[2] = {}; // the decoders' surface pools those belong to (main, aux)
	std::map<uint64_t, std::pair<AVFrame*, AVFrame*>> held;
	uint64_t showSeq = 0;
	bool fullRedraw = false;

	uint32_t wantW = 0, wantH = 0, wantScale = 100;
	uint32_t sentW = 0, sentH = 0, sentScale = 0;
	uint64_t lastResizeAt = 0;

	gliff::Seat seat; // this machine's keymap and clipboard
	std::unique_ptr<gliff::Clipboard> clip;
	std::set<uint32_t> keysDown;
	std::string cursorDef; // the last "cursor ..." line
	std::string cursorState = "cursor-default";

	std::string failure;
	bool focused = false; // the view has the keyboard (for a clipboard made anew on reconnecting)

	// Reconnecting after a dropped link, as Gliff's client does: up to five tries, further apart.
	int retries = 0;
	uint64_t retryAt = 0;   // when the next try starts; 0: none waiting
	uint64_t attemptAt = 0; // when this connection was started

	// Per second, for the stats line (as Gliff's client shows in its header).
	uint64_t statFrames = 0, statBytes = 0, statDecodeUs = 0, statAt = 0;
	uint64_t statXferUs = 0, statConvUs = 0; // of statDecodeUs: GPU download, colour conversion

	// The link's health for the bar's dot: a Ping a second (works on a still screen, where the frame
	// rate drops by design), the round trip smoothed as TCP does, and the server's own congestion
	// verdict (its fps cap). A warning shows after 5 s and clears after 5 s fine, so it never flickers.
	uint64_t pingAt = 0, pongAt = 0;
	double srtt = -1, rttDev = 0;
	std::string warn;               // the warning shown: "congested", "latency" or ""
	uint64_t warnSince = 0, okSince = 0;

	std::string get(const char* key, const char* fallback = "") const
	{
		auto it = cfg.find(key);
		return it == cfg.end() || it->second.empty() ? fallback : it->second;
	}
};

static Session g;

// ---------------------------------------------------------------- the server pipe

static void send_msg(const std::string& body, const std::string& payload = {})
{
	if (g.toServer >= 0)
		g.outbuf += gliff::frame(body, payload);
}

static void flush_out()
{
	while (!g.outbuf.empty() && g.toServer >= 0)
	{
		const ssize_t n = write(g.toServer, g.outbuf.data(), g.outbuf.size());
		if (n > 0)
			g.outbuf.erase(0, size_t(n));
		else if (n < 0 && errno == EINTR)
			continue;
		else
			break; // EAGAIN: poll says when there is room again
	}
}

static bool spawn()
{
	int in[2], out[2], err[2];
	if (pipe2(in, O_CLOEXEC) || pipe2(out, O_CLOEXEC) || pipe2(err, O_CLOEXEC))
		return false;
	g.child = fork();
	if (g.child < 0)
		return false;
	if (g.child == 0)
	{
		dup2(in[0], 0);
		dup2(out[1], 1);
		dup2(err[1], 2);
		setsid(); // no controlling terminal: ssh never prompts, it fails with a message
		std::vector<char*> argv;
		for (auto& a : g.args)
			argv.push_back(a.data());
		argv.push_back(nullptr);
		execvp(argv[0], argv.data());
		_exit(127);
	}
	close(in[0]);
	close(out[1]);
	close(err[1]);
	g.toServer = in[1];
	g.fromServer = out[0];
	g.serverErr = err[0];
	for (int fd : { g.toServer, g.fromServer, g.serverErr })
		fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
	return true;
}

static void read_stderr()
{
	char buf[4096];
	ssize_t n;
	while ((n = read(g.serverErr, buf, sizeof(buf))) > 0)
	{
		std::string text(buf, size_t(n));
		g.errTail += text;
		if (g.errTail.size() > 8192)
			g.errTail.erase(0, g.errTail.size() - 8192);
		// Into the session log, a line at a time.
		size_t start = 0, nl;
		while ((nl = text.find('\n', start)) != std::string::npos)
		{
			if (nl > start)
				log("server: %s", text.substr(start, nl - start).c_str());
			start = nl + 1;
		}
		if (start < text.size())
			log("server: %s", text.substr(start).c_str());
	}
	if (n == 0)
	{
		close(g.serverErr);
		g.serverErr = -1;
	}
}

// The last line ssh or the server wrote that says something, without gliff-server's log decoration.
static std::string last_words()
{
	std::string tail = g.errTail;
	while (!tail.empty() && (tail.back() == '\n' || tail.back() == '\r' || tail.back() == ' '))
		tail.pop_back();
	const size_t nl = tail.rfind('\n');
	std::string line = nl == std::string::npos ? tail : tail.substr(nl + 1);
	if (line.find("command not found") != std::string::npos || line.find("gliff-server: not found") != std::string::npos)
		return "No gliff-server on " + g.get("host") + ": install it there with omarchy pkg add gliff";
	return line.substr(0, 300);
}

// ---------------------------------------------------------------- video

static uint64_t now_us()
{
	timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return uint64_t(ts.tv_sec) * 1000000 + uint64_t(ts.tv_nsec) / 1000;
}


// VA-API for the decoders when it works, as Gliff's own client prefers its GPU path; it is also
// what makes asking for 4:4:4 (Dual420) worth it, as there. Settings: video=auto|gpu|cpu.
static void open_hw()
{
	if (g.get("video", "auto") == "cpu")
		return;
	if (av_hwdevice_ctx_create(&g.hw, AV_HWDEVICE_TYPE_VAAPI, nullptr, nullptr, 0) < 0)
	{
		g.hw = nullptr;
		log("no VA-API decoder here: decoding on the CPU");
		return;
	}
	log("decoding with VA-API");
}

static AVPixelFormat pick_format(AVCodecContext* ctx, const AVPixelFormat* fmts)
{
	for (const AVPixelFormat* f = fmts; *f != AV_PIX_FMT_NONE; f++)
		if (*f == AV_PIX_FMT_VAAPI && ctx->hw_device_ctx)
			return *f;
	return avcodec_default_get_format(ctx, fmts);
}

static void free_stream(Stream& s)
{
	avcodec_free_context(&s.ctx);
	av_frame_free(&s.pic);
	av_frame_free(&s.tmp);
	av_frame_free(&s.sw);
}

static void reset_surfaces();

static void free_decoder()
{
	reset_surfaces();
	free_stream(g.main);
	free_stream(g.aux);
}

static bool open_stream(Stream& s, const std::string& extradata)
{
	free_stream(s);
	const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_H264);
	if (!codec)
	{
		g.failure = "FFmpeg has no H.264 decoder";
		return false;
	}
	s.ctx = avcodec_alloc_context3(codec);
	s.ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
	s.ctx->thread_count = 1; // frame threads would hold frames back
	if (g.hw && !g.hwBroken)
	{
		s.ctx->hw_device_ctx = av_buffer_ref(g.hw);
		s.ctx->get_format = pick_format;
		s.ctx->extra_hw_frames = 4; // the pictures the UI holds, beyond the decoder's own references
	}
	if (!extradata.empty())
	{
		s.ctx->extradata = static_cast<uint8_t*>(av_mallocz(extradata.size() + AV_INPUT_BUFFER_PADDING_SIZE));
		memcpy(s.ctx->extradata, extradata.data(), extradata.size());
		s.ctx->extradata_size = int(extradata.size());
	}
	if (avcodec_open2(s.ctx, codec, nullptr) < 0)
	{
		g.failure = "Could not open the H.264 decoder";
		avcodec_free_context(&s.ctx);
		return false;
	}
	s.pic = av_frame_alloc();
	s.tmp = av_frame_alloc();
	s.sw = av_frame_alloc();
	s.got = false;
	return true;
}

static bool open_decoder(const gliff::StreamConfig& c)
{
	if (!g.pkt)
		g.pkt = av_packet_alloc();
	if (!open_stream(g.main, c.extradata))
		return false;
	if (c.chroma == gliff::CHROMA_DUAL420 && !open_stream(g.aux, c.auxExtradata))
		return false;
	if (c.chroma != gliff::CHROMA_DUAL420)
		free_stream(g.aux);
	return true;
}

// Feeds one access unit; afterwards s.got says whether s holds a picture (the newest one).
// False on a decoder error.
static bool decode_stream(Stream& s, const uint8_t* data, uint32_t len, bool keyframe)
{
	s.got = false;
	if (!s.ctx || len == 0)
		return s.ctx != nullptr;
	av_packet_unref(g.pkt);
	if (av_new_packet(g.pkt, int(len)) < 0)
		return false;
	memcpy(g.pkt->data, data, len);
	if (keyframe)
		g.pkt->flags |= AV_PKT_FLAG_KEY;
	if (avcodec_send_packet(s.ctx, g.pkt) < 0)
		return false;
	int rc;
	while ((rc = avcodec_receive_frame(s.ctx, s.tmp)) >= 0)
	{
		av_frame_unref(s.pic);
		av_frame_move_ref(s.pic, s.tmp);
		s.got = true;
	}
	if (rc != AVERROR(EAGAIN) && rc != AVERROR_EOF)
		return false;
	return true;
}

// A VA-API picture copied out of the GPU into s.sw (NV12); nothing to do for a software one.
static bool download(Stream& s)
{
	if (!s.got || s.pic->format != AV_PIX_FMT_VAAPI)
		return true;
	av_frame_unref(s.sw);
	if (av_hwframe_transfer_data(s.sw, s.pic, 0) < 0)
		return false;
	s.sw->width = s.pic->width;
	s.sw->height = s.pic->height;
	return true;
}

// The picture's planes, from the software decoder (YUV420P) or VA-API (NV12).
static bool planes_of(Stream& s, gliff::Planes& p)
{
	const AVFrame* f = s.pic->format == AV_PIX_FMT_VAAPI ? s.sw : s.pic;
	if (f->format == AV_PIX_FMT_NV12)
		p = { f->data[0], f->linesize[0], f->data[1], f->data[1] + 1, f->linesize[1], 2 };
	else if (f->format == AV_PIX_FMT_YUV420P || f->format == AV_PIX_FMT_YUVJ420P)
		p = { f->data[0], f->linesize[0], f->data[1], f->data[2], f->linesize[1], 1 };
	else
		return false;
	return true;
}

static void ensure_framebuffer(uint32_t w, uint32_t h)
{
	if (g.frame.data && g.frame.width == w && g.frame.height == h)
		return;
	oma::Framebuffer old = g.frame;
	oma::Framebuffer fb = oma::fb_alloc(w, h);
	if (!fb.data)
		return;
	g.frame = fb;
	log("desktop is %ux%u", w, h);
	g.link.sendFrame(g.frame);
	if (old.data)
		oma::fb_release(old.data); // the UI keeps its own mapping until it maps the new one
}

static void on_connected();

// ---------------------------------------------------------------- pictures as dmabufs

static void release_held(uint64_t upTo = UINT64_MAX)
{
	for (auto it = g.held.begin(); it != g.held.end() && it->first <= upTo;)
	{
		av_frame_free(&it->second.first);
		av_frame_free(&it->second.second);
		it = g.held.erase(it);
	}
}

// The UI forgets every surface it has (a new UI, or a new decoder pool).
static void reset_surfaces()
{
	release_held();
	if (!g.exported.empty() && g.link.attached())
		g.link.send("surfaces-reset");
	g.exported.clear();
	g.exportedPools[0] = g.exportedPools[1] = nullptr;
}

// Whether this picture can go to the UI as it is: VA-API, NV12 (8 bits).
static bool on_gpu(const Stream& s)
{
	if (!s.got || s.pic->format != AV_PIX_FMT_VAAPI || !s.pic->hw_frames_ctx)
		return false;
	const auto* fc = reinterpret_cast<const AVHWFramesContext*>(s.pic->hw_frames_ctx->data);
	return fc->sw_format == AV_PIX_FMT_NV12;
}

// The picture's surface, finished decoding and known to the UI: sends it as a dmabuf the first
// time. "surface <id> <width> <height> <objects> <modifier>... <layers>" then per layer "<fourcc>
// <object> <offset> <pitch>", with one descriptor per object.
static bool export_surface(const Stream& s, VASurfaceID& id)
{
	const auto* fc = reinterpret_cast<const AVHWFramesContext*>(s.pic->hw_frames_ctx->data);
	const auto* dc = static_cast<const AVVAAPIDeviceContext*>(fc->device_ctx->hwctx);
	id = VASurfaceID(uintptr_t(s.pic->data[3]));
	if (vaSyncSurface(dc->display, id) != VA_STATUS_SUCCESS)
		return false;
	if (g.exported.count(id))
		return true;
	VADRMPRIMESurfaceDescriptor d = {};
	if (vaExportSurfaceHandle(dc->display, id, VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
	                          VA_EXPORT_SURFACE_READ_ONLY | VA_EXPORT_SURFACE_SEPARATE_LAYERS, &d) != VA_STATUS_SUCCESS)
		return false;
	std::vector<int> fds;
	for (uint32_t i = 0; i < d.num_objects; i++)
		fds.push_back(d.objects[i].fd);
	const bool ok = d.num_objects >= 1 && d.num_objects <= 4 && d.num_layers == 2 && d.layers[0].num_planes == 1 &&
	                d.layers[1].num_planes == 1 && d.layers[0].drm_format == DRM_FORMAT_R8 &&
	                d.layers[1].drm_format == DRM_FORMAT_GR88;
	if (ok)
	{
		std::string line = "surface " + std::to_string(id) + " " + std::to_string(d.width) + " " +
		                   std::to_string(d.height) + " " + std::to_string(d.num_objects);
		for (uint32_t i = 0; i < d.num_objects; i++)
			line += " " + std::to_string(d.objects[i].drm_format_modifier);
		line += " 2";
		for (uint32_t i = 0; i < 2; i++)
			line += " " + std::to_string(d.layers[i].drm_format) + " " + std::to_string(d.layers[i].object_index[0]) +
			        " " + std::to_string(d.layers[i].offset[0]) + " " + std::to_string(d.layers[i].pitch[0]);
		g.link.send(line, fds);
		g.exported.insert(id);
	}
	else
		log("VA-API exported a surface the UI cannot take (%u objects, %u layers): drawing here", d.num_objects,
		    d.num_layers);
	for (int fd : fds)
		close(fd);
	return ok;
}

static void ensure_framebuffer(uint32_t w, uint32_t h);

// The newest picture to the UI as dmabufs. False when it cannot go that way (then the caller
// converts it here, and keeps doing so).
static bool show_gpu(bool dual)
{
	if (!g.gpuView || !on_gpu(g.main) || (dual && !on_gpu(g.aux)))
		return false;
	const int w = std::min(g.main.pic->width, int(g.stream.width)) & ~1;
	const int h = std::min(g.main.pic->height, int(g.stream.height)) & ~1;
	if (dual && (g.aux.pic->width < w || g.aux.pic->height < h))
		return true; // a picture to skip, as show() does
	// A new pool (a new stream, or the decoder's own reinit) may hand out ids the UI already has
	// for other surfaces: start its list again.
	const void* pools[2] = { g.main.pic->hw_frames_ctx->data, dual ? g.aux.pic->hw_frames_ctx->data : nullptr };
	if (g.exportedPools[0] != pools[0] || g.exportedPools[1] != pools[1])
	{
		reset_surfaces();
		g.exportedPools[0] = pools[0];
		g.exportedPools[1] = pools[1];
	}
	VASurfaceID mainId = VA_INVALID_SURFACE, auxId = VA_INVALID_SURFACE;
	if (!export_surface(g.main, mainId) || (dual && !export_surface(g.aux, auxId)))
	{
		g.gpuView = false;
		return false;
	}
	// The framebuffer keeps the size (the UI's geometry and a later fallback), not the pixels.
	ensure_framebuffer(uint32_t(w), uint32_t(h));
	g.shmStale = true;
	const uint64_t seq = ++g.showSeq;
	g.held[seq] = { av_frame_clone(g.main.pic), dual ? av_frame_clone(g.aux.pic) : nullptr };
	// A UI that stops releasing (stuck, or gone without a word) cannot starve the decoder.
	while (g.held.size() > 6)
		release_held(g.held.begin()->first);
	g.link.send("show " + std::to_string(seq) + " " + std::to_string(mainId) + " " +
	            (dual ? std::to_string(auxId) : std::string("-")) + " " + std::to_string(w) + " " +
	            std::to_string(h));
	if (!g.connected)
		on_connected();
	return true;
}

// Converts what changed into the framebuffer and tells the UI.
static void show(const gliff::VideoFrame& vf, bool dual)
{
	gliff::Planes m, a;
	if (!planes_of(g.main, m) || (dual && !planes_of(g.aux, a)))
	{
		log("unexpected picture format %d", g.main.pic->format);
		return;
	}
	const int w = std::min(g.main.pic->width, int(g.stream.width)) & ~1;
	const int h = std::min(g.main.pic->height, int(g.stream.height)) & ~1;
	if (dual && (g.aux.pic->width < w || g.aux.pic->height < h))
		return;
	ensure_framebuffer(uint32_t(w), uint32_t(h));
	if (!g.frame.data)
		return;
	std::vector<gliff::Rect> rects;
	if (vf.keyframe || vf.damage.empty() || !g.connected || g.fullRedraw || g.shmStale)
		rects.push_back({ 0, 0, w, h });
	else
		rects = vf.damage;
	g.fullRedraw = false;
	g.shmStale = false;
	const uint64_t tc = now_us();
	for (const auto& d : rects)
	{
		int x0 = d.x, y0 = d.y, x1 = d.x + d.width, y1 = d.y + d.height;
		gliff::even_rect(x0, y0, x1, y1, w, h);
		if (x1 <= x0 || y1 <= y0)
			continue;
		if (dual)
			gliff::convert444(m, a, h, x0, y0, x1, y1, g.frame.data, int(g.frame.stride));
		else
			gliff::convert420(m, x0, y0, x1, y1, g.frame.data, int(g.frame.stride));
		g.link.send("damage " + std::to_string(x0) + " " + std::to_string(y0) + " " + std::to_string(x1 - x0) + " " +
		            std::to_string(y1 - y0));
	}
	g.statConvUs += now_us() - tc;
	if (!g.connected)
		on_connected();
}

// The newest picture again, after the UI changed how it takes them: as dmabufs, or converted into
// the framebuffer (which then is behind on everything since the last conversion).
static void redraw()
{
	const bool dual = g.stream.chroma == gliff::CHROMA_DUAL420;
	if (!g.main.got || (dual && !g.aux.got) || show_gpu(dual))
		return;
	if (!download(g.main) || (dual && !download(g.aux)))
		return;
	gliff::VideoFrame vf;
	vf.keyframe = true;
	show(vf, dual);
}

// Below this fps cap the server's ladder has given up more than its first step (30 fps), which it
// also starts on and may hold for minutes after a blip: only from here on is the link "congested".
constexpr uint32_t CONGESTED_FPS = 15;
// A smoothed round trip, or its variation, beyond which the link is "slow".
constexpr double SLOW_RTT_MS = 150, SLOW_DEV_MS = 50;
// No Pong for this long: the server does not answer.
constexpr uint64_t NO_REPLY_MS = 3000;
constexpr uint64_t WARN_AFTER_MS = 5000;

static void on_pong(uint64_t t)
{
	const uint64_t now = oma::now_ms();
	if (t > now || t < g.attemptAt)
		return; // not one of this connection's
	const double rtt = double(now - t);
	g.pongAt = now;
	if (g.srtt < 0)
	{
		g.srtt = rtt;
		g.rttDev = rtt / 2;
	}
	else
	{
		g.rttDev = 0.75 * g.rttDev + 0.25 * std::abs(rtt - g.srtt);
		g.srtt = 0.875 * g.srtt + 0.125 * rtt;
	}
}

// The health a stats line carries: ok, warn or bad, and why ("" when ok).
static std::pair<const char*, std::string> health(uint64_t now)
{
	if (g.pingAt > g.pongAt && now - g.pongAt > NO_REPLY_MS)
		return { "bad", "noreply" };
	const bool congested = g.stream.fpsCap > 0 && g.stream.fpsCap <= CONGESTED_FPS;
	const bool slow = g.srtt >= 0 && (g.srtt > SLOW_RTT_MS || g.rttDev > SLOW_DEV_MS);
	const std::string now_warn = congested ? "congested" : slow ? "latency" : "";
	if (!now_warn.empty())
	{
		g.okSince = 0;
		if (!g.warnSince)
			g.warnSince = now;
		if (now - g.warnSince >= WARN_AFTER_MS || !g.warn.empty())
			g.warn = now_warn;
	}
	else
	{
		g.warnSince = 0;
		if (!g.okSince)
			g.okSince = now;
		if (now - g.okSince >= WARN_AFTER_MS)
			g.warn.clear();
	}
	return { g.warn.empty() ? "ok" : "warn", g.warn };
}

// A stats line: words "key=value" (no spaces in a value) the bar fits to its width; see
// Format.parseStats. Base64 on the link as before.
static void send_stats_line(const std::string& text) { g.link.send("stats " + b64(text)); }

// Once a second: frames shown, bandwidth, decode time, what decodes and encodes, the link's health.
static void send_stats()
{
	const uint64_t now = oma::now_ms();
	if (!g.connected)
		return;
	if (now - g.pingAt >= 1000)
	{
		if (!g.pongAt)
			g.pongAt = now; // the clock for "no answer" starts with the first Ping
		g.pingAt = now;
		send_msg(gliff::ping(now));
	}
	if (!g.statAt)
		g.statAt = now;
	if (now - g.statAt < 1000)
		return;
	const double secs = double(now - g.statAt) / 1000.0;
	const double f = g.statFrames ? double(g.statFrames) : 1.0;
	if (getenv("OMAREMOTE_GLIFF_TIMING"))
		log("timing: decode %.1f ms, of which download %.1f, convert %.1f", g.statDecodeUs / 1000.0 / f,
		    g.statXferUs / 1000.0 / f, g.statConvUs / 1000.0 / f);
	g.statXferUs = g.statConvUs = 0;
	const auto [state, why] = health(now);
	char text[320];
	snprintf(text, sizeof(text),
	         "fps=%.0f mbit=%.1f decode=%.1f decoder=%s size=%ux%u chroma=%s server=%s cap=%u rtt=%.0f dev=%.0f "
	         "health=%s why=%s",
	         g.statFrames / secs, g.statBytes * 8.0 / secs / 1e6, g.statDecodeUs / 1000.0 / f,
	         g.hw && !g.hwBroken ? "VA-API" : "CPU", g.stream.width, g.stream.height,
	         g.stream.chroma == gliff::CHROMA_DUAL420 ? "4:4:4" : "4:2:0",
	         g.stream.pipeline == 0 ? "GPU" : g.stream.pipeline == 1 ? "CPU" : "?", g.stream.fpsCap,
	         g.srtt, g.rttDev, state, why.c_str());
	send_stats_line(text);
	g.statAt = now;
	g.statFrames = g.statBytes = g.statDecodeUs = 0;
}

static void decode(const gliff::VideoFrame& vf, const uint8_t* data)
{
	if (!g.main.ctx)
		return;
	const bool dual = g.stream.chroma == gliff::CHROMA_DUAL420;
	if (g.needKeyframe && !vf.keyframe)
	{
		send_msg(gliff::frameAck(vf.frameId, oma::now_ms()));
		return;
	}
	g.needKeyframe = false;
	const uint64_t t0 = now_us();
	g.statBytes += uint64_t(vf.dataLen) + vf.auxLen;
	bool ok = decode_stream(g.main, data, vf.dataLen, vf.keyframe);
	if (ok && dual)
		ok = decode_stream(g.aux, data + vf.dataLen, vf.auxLen, vf.keyframe);
	// Acked whatever happened, so the server keeps pacing; a broken stream asks for a fresh start.
	send_msg(gliff::frameAck(vf.frameId, oma::now_ms()));
	if (ok && g.main.got && (!dual || g.aux.got) && show_gpu(dual))
	{
		g.hwErrors = 0;
		g.statFrames++;
		g.statDecodeUs += now_us() - t0;
		return;
	}
	if (ok && g.main.got && (!dual || g.aux.got))
	{
		// Both pictures out of the GPU at once: the copies take about as long as the conversion.
		const uint64_t tx = now_us();
		bool auxOk = true;
		std::thread auxCopy;
		if (dual)
			auxCopy = std::thread([&] { auxOk = download(g.aux); });
		ok = download(g.main);
		if (auxCopy.joinable())
			auxCopy.join();
		ok = ok && auxOk;
		g.statXferUs += now_us() - tx;
	}
	if (ok && g.main.got && (!dual || g.aux.got))
	{
		show(vf, dual);
		g.hwErrors = 0;
		g.statFrames++;
		g.statDecodeUs += now_us() - t0;
		return;
	}
	if (ok)
		return; // nothing out yet
	log("decode error on frame %llu: asking for a keyframe", (unsigned long long)vf.frameId);
	// VA-API that keeps failing (a driver that cannot take this stream): the CPU from here on.
	if (g.hw && !g.hwBroken && ++g.hwErrors >= 3)
	{
		log("VA-API keeps failing: decoding on the CPU");
		g.hwBroken = true;
		open_decoder(g.stream);
	}
	g.needKeyframe = true;
	g.fullRedraw = true;
	send_msg(gliff::requestKeyframe());
}

// ---------------------------------------------------------------- size and pointer

// Asks a private screen to follow the tab: physical pixels and the tab's scale. Spaced half a
// second apart while the tab is being dragged.
static void flush_resize()
{
	if (!g.welcomed || g.wantW < 320 || g.wantH < 240)
		return;
	const uint32_t w = g.wantW & ~1u, h = g.wantH & ~1u;
	if ((w == g.sentW && h == g.sentH && g.wantScale == g.sentScale) || oma::now_ms() - g.lastResizeAt < 500)
		return;
	g.lastResizeAt = oma::now_ms();
	g.sentW = w;
	g.sentH = h;
	g.sentScale = g.wantScale;
	send_msg(gliff::resize(w, h, float(g.wantScale) / 100.0f));
	log("requested %ux%u at %u%%", w, h, g.wantScale);
}

// The UI gives framebuffer (stream) pixels; the server wants its logical coordinates.
static void pointer_to(long x, long y)
{
	const double s = g.stream.scaleMilli ? g.stream.scaleMilli / 1000.0 : 1.0;
	send_msg(gliff::pointerMotion(std::max(0L, x) / s, std::max(0L, y) / s));
}

// ---------------------------------------------------------------- cursor

// A mirrored screen's cursor, drawn locally: each new shape is the cursor from then on, as in
// Gliff's own client. CursorPos is not followed: the local pointer is where the user puts it, and
// its "visible" flag hid the cursor for good on a mirrored 4K screen. A shape without a single
// visible pixel (a server that draws the pointer into the picture, such as one on NVIDIA) leaves
// the ordinary arrow, as Gliff's client does: the remote one then trails it in the picture.
static void cursor_shape(const gliff::CursorShape& c, const uint8_t* argb)
{
	if (g.headless || c.width == 0 || c.height == 0 || c.width > 1024 || c.height > 1024 ||
	    c.argbLen != c.width * c.height * 4)
		return;
	bool visible = false;
	for (uint32_t i = 3; i < c.argbLen && !visible; i += 4)
		visible = argb[i] != 0;
	if (!visible)
	{
		g.cursorDef.clear();
		g.cursorState = "cursor-default";
		g.link.send(g.cursorState);
		return;
	}
	// Little-endian ARGB8888 is B G R A in memory: the UI's cursor format.
	g.cursorDef = "cursor " + std::to_string(c.id) + " " + std::to_string(c.hotX) + " " + std::to_string(c.hotY) +
	              " " + std::to_string(c.width) + " " + std::to_string(c.height) + " " +
	              b64(std::string(reinterpret_cast<const char*>(argb), c.argbLen));
	g.cursorState = "cursor-set " + std::to_string(c.id);
	g.link.send(g.cursorDef);
	g.link.send(g.cursorState);
}

// ---------------------------------------------------------------- server messages

static void on_connected()
{
	g.connected = true;
	g.retries = 0;
	// The supervisor reads this line as "connected".
	log("connected to %s (%ux%u)", g.get("host").c_str(), g.frame.width, g.frame.height);
	g.link.send("state connected");
	g.link.send(g.cursorState);
}

static bool handle_message(const uint8_t* body, uint32_t bodyLen, const uint8_t* payload, uint32_t payloadLen)
{
	cbor::Reader r(body, bodyLen);
	int64_t n = 0;
	const int64_t v = gliff::open(r, n);
	if (v < 0)
	{
		g.failure = "The server sent a message this client cannot read";
		return false;
	}
	switch (v)
	{
		case gliff::S_HELLO_ACK:
		{
			gliff::HelloAck m;
			if (!gliff::decode(r, n, m))
				break;
			g.welcomed = true;
			g.headless = m.headless;
			log("session on %s%s, protocol %u", m.output.c_str(), m.headless ? " (private screen)" : "", m.version);
			if (g.headless)
				g.cursorState = "cursor-hide";
			flush_resize();
			break;
		}
		case gliff::S_STREAM_CONFIG:
		{
			gliff::StreamConfig m;
			if (!gliff::decode(r, n, m))
				break;
			if (m.codec != gliff::CODEC_H264 || (m.chroma != gliff::CHROMA_SINGLE420 && m.chroma != gliff::CHROMA_DUAL420))
			{
				g.failure = "The server chose a video format this client does not decode yet";
				return false;
			}
			log("stream %ux%u %s, scale %.2f, %s encoding, at most %u fps", m.width, m.height,
			    m.chroma == gliff::CHROMA_DUAL420 ? "4:4:4" : "4:2:0", m.scaleMilli / 1000.0,
			    m.pipeline == 0 ? "GPU" : m.pipeline == 1 ? "CPU" : "unknown", m.fpsCap);
			// A new frame-rate cap alone comes without a keyframe: the decoder keeps going.
			const bool same = g.main.ctx && m.width == g.stream.width && m.height == g.stream.height &&
			                  m.chroma == g.stream.chroma && m.extradata == g.stream.extradata &&
			                  m.auxExtradata == g.stream.auxExtradata;
			g.stream = m;
			g.haveStream = true;
			if (!same)
			{
				if (!open_decoder(m))
					return false;
				g.needKeyframe = false;
			}
			break;
		}
		case gliff::S_VIDEO_FRAME:
		{
			gliff::VideoFrame m;
			if (!gliff::decode(r, n, m) || uint64_t(m.dataLen) + m.auxLen > payloadLen)
				break;
			decode(m, payload);
			break;
		}
		case gliff::S_CURSOR_SHAPE:
		{
			gliff::CursorShape m;
			if (gliff::decode(r, n, m) && m.argbLen <= payloadLen)
				cursor_shape(m, payload);
			break;
		}
		case gliff::S_PONG:
			if (n >= 1)
			{
				const uint64_t t = r.u64();
				if (!r.bad)
					on_pong(t);
			}
			break;
		case gliff::S_PING:
			if (n >= 1)
			{
				const uint64_t t = r.u64();
				if (!r.bad)
					send_msg(gliff::pong(t));
			}
			break;
		case gliff::S_ERROR:
		{
			gliff::Error m;
			if (!gliff::decode(r, n, m))
				break;
			log("server error %u: %s", m.code, m.message.c_str());
			if (gliff::incompatible(m.code) || !g.connected)
			{
				g.failure = m.message.empty() ? "The server refused the session" : m.message;
				return false;
			}
			break;
		}
		case gliff::S_CLIP_OFFER:
		{
			gliff::ClipOffer m;
			if (gliff::decode(r, n, m))
				g.clip->onOffer(m);
			break;
		}
		case gliff::S_CLIP_REQUEST:
		{
			gliff::ClipRequest m;
			if (gliff::decode(r, n, m))
				g.clip->onRequest(m);
			break;
		}
		case gliff::S_CLIP_DATA:
		{
			gliff::ClipData m;
			if (gliff::decode(r, n, m) && m.len <= payloadLen)
				g.clip->onData(m, payload);
			break;
		}
		case gliff::S_CLIP_ACK:
		case gliff::S_CLIP_ABORT:
		{
			uint32_t id = 0;
			uint64_t count = 0;
			if (!gliff::decodeIdAndCount(r, n, id, count))
				break;
			if (v == gliff::S_CLIP_ACK)
				g.clip->onAck(id, count);
			else
				g.clip->onAbort(id);
			break;
		}
		default:
			break; // anything newer: skipped
	}
	return true;
}

// Takes every whole frame out of the read buffer. False ends the session.
static bool read_server()
{
	char buf[1 << 16];
	for (;;)
	{
		const ssize_t n = read(g.fromServer, buf, sizeof(buf));
		if (n > 0)
		{
			g.inbuf.append(buf, size_t(n));
			continue;
		}
		if (n < 0 && errno == EINTR)
			continue;
		if (n == 0)
		{
			close(g.fromServer);
			g.fromServer = -1;
		}
		break;
	}
	size_t at = 0;
	while (g.inbuf.size() - at >= gliff::HEADER_LEN)
	{
		const auto* h = reinterpret_cast<const uint8_t*>(g.inbuf.data() + at);
		const uint32_t bodyLen = uint32_t(h[0]) | uint32_t(h[1]) << 8 | uint32_t(h[2]) << 16 | uint32_t(h[3]) << 24;
		const uint32_t payloadLen = uint32_t(h[4]) | uint32_t(h[5]) << 8 | uint32_t(h[6]) << 16 | uint32_t(h[7]) << 24;
		if (bodyLen > gliff::MAX_FRAME_BODY || payloadLen > gliff::MAX_FRAME_PAYLOAD)
		{
			g.failure = "The server sent a frame larger than the protocol allows";
			return false;
		}
		const size_t total = gliff::HEADER_LEN + size_t(bodyLen) + payloadLen;
		if (g.inbuf.size() - at < total)
			break;
		if (!handle_message(h + gliff::HEADER_LEN, bodyLen, h + gliff::HEADER_LEN + bodyLen, payloadLen))
			return false;
		at += total;
	}
	g.inbuf.erase(0, at);
	return g.fromServer >= 0;
}

// ---------------------------------------------------------------- UI lines

static void release_keys()
{
	for (uint32_t k : g.keysDown)
		send_msg(gliff::key(k, false));
	g.keysDown.clear();
}

static void handle_line(const std::string& line)
{
	const auto w = split(line);
	if (w.empty())
		return;
	const std::string& cmd = w[0];
	auto num = [&](size_t i) -> long { return i < w.size() ? strtol(w[i].c_str(), nullptr, 10) : 0; };
	const bool input = g.connected;

	if (cmd == "size" && w.size() >= 3)
	{
		g.wantW = uint32_t(std::clamp(num(1), 0L, 8192L));
		g.wantH = uint32_t(std::clamp(num(2), 0L, 8192L));
		if (w.size() >= 4)
			g.wantScale = uint32_t(std::clamp(num(3), 50L, 400L));
		flush_resize();
	}
	else if (cmd == "mouse" && input)
		pointer_to(num(1), num(2));
	else if (cmd == "button" && input && w.size() >= 5)
	{
		// UI numbering: 1 left, 2 right, 3 middle, 4 back, 5 forward.
		static const uint32_t buttons[] = { 0, gliff::BTN_LEFT, gliff::BTN_RIGHT, gliff::BTN_MIDDLE, gliff::BTN_SIDE,
			                                gliff::BTN_EXTRA };
		const long b = num(1);
		if (b >= 1 && b <= 5)
		{
			pointer_to(num(3), num(4));
			send_msg(gliff::pointerButton(buttons[b], num(2) != 0));
		}
	}
	else if (cmd == "wheel" && input && w.size() >= 5)
	{
		// The UI: 120 per notch, positive up or left. Wayland: positive down or right, 15 per notch.
		pointer_to(num(3), num(4));
		const long dy = num(1), dx = num(2);
		if (dy)
			send_msg(gliff::pointerAxis(0, -dy / 120.0 * 15.0, dy > 0 ? -1 : 1));
		if (dx)
			send_msg(gliff::pointerAxis(1, -dx / 120.0 * 15.0, dx > 0 ? -1 : 1));
	}
	else if (cmd == "key" && input && w.size() >= 3)
	{
		const bool down = num(1) != 0;
		const long code = num(2);
		if (code <= 0 || code > 0x2FF)
			return;
		if (down)
			g.keysDown.insert(uint32_t(code));
		else if (!g.keysDown.erase(uint32_t(code)))
			return;
		send_msg(gliff::key(uint32_t(code), down));
	}
	else if (cmd == "cad" && input)
	{
		const uint32_t keys[] = { 29, 56, 111 }; // KEY_LEFTCTRL, KEY_LEFTALT, KEY_DELETE
		for (uint32_t k : keys)
			send_msg(gliff::key(k, true));
		for (int i = 2; i >= 0; i--)
			send_msg(gliff::key(keys[i], false));
	}
	// The view has the keyboard, or not: the clipboard is shared while it has (clipboard.hpp).
	else if (cmd == "focus" || cmd == "blur")
	{
		g.focused = cmd == "focus";
		g.clip->setFocused(g.focused);
	}
	else if (cmd == "clip-cancel" && w.size() >= 2)
		g.clip->cancel(uint32_t(num(1)));
	else if (cmd == "disconnect")
		g.quit = 1;
	// The UI draws dmabufs on its GPU ("gpu 1"), or stops doing so ("gpu 0": it could not import).
	else if (cmd == "gpu" && w.size() >= 2)
	{
		const bool want = num(1) == 1 && g.hw && !g.hwBroken && !getenv("OMAREMOTE_GLIFF_NO_DMABUF");
		if (want == g.gpuView)
			return;
		g.gpuView = want;
		log(want ? "the UI draws the pictures on its GPU" : "the UI takes converted pictures");
		if (!want)
			reset_surfaces();
		redraw();
	}
	else if (cmd == "release" && w.size() >= 2)
	{
		const auto it = g.held.find(uint64_t(strtoull(w[1].c_str(), nullptr, 10)));
		if (it != g.held.end())
		{
			av_frame_free(&it->second.first);
			av_frame_free(&it->second.second);
			g.held.erase(it);
		}
	}
}

// ---------------------------------------------------------------- main

static void on_signal(int)
{
	g.quit = 1;
}

static void replay()
{
	g.link.send(g.connected ? "state connected" : "state connecting");
	if (!g.connected)
		return;
	if (g.shmStale)
		redraw();
	g.link.sendFrame(g.frame);
	g.link.send("damage 0 0 " + std::to_string(g.frame.width) + " " + std::to_string(g.frame.height));
	if (!g.cursorDef.empty())
		g.link.send(g.cursorDef);
	g.link.send(g.cursorState);
	// A reattached UI starts with no keys down.
	release_keys();
}

static int finish(int rc)
{
	if (rc != 11 && rc != 0)
		log("connection failed: %s", g.failure.empty() ? "unknown error" : g.failure.c_str());
	g.link.send(g.connected || rc == 11 ? "state ended " + std::to_string(rc) : "state failed " + std::to_string(rc));
	g.link.close();
	free_decoder();
	av_packet_free(&g.pkt);
	av_buffer_unref(&g.hw);
	return rc;
}

// ssh and gliff-server, started (again) with everything about the last connection forgotten
// except the picture, which stays up until the new one arrives.
static bool start_server()
{
	g.inbuf.clear();
	g.outbuf.clear();
	g.errTail.clear();
	g.failure.clear();
	g.welcomed = false;
	g.stream = {};
	g.haveStream = false;
	free_decoder();
	g.needKeyframe = false;
	g.fullRedraw = true;
	g.sentW = g.sentH = g.sentScale = 0;
	g.keysDown.clear();
	g.pingAt = g.pongAt = g.warnSince = g.okSince = g.statAt = 0;
	g.srtt = -1;
	g.rttDev = 0;
	g.warn.clear();
	g.attemptAt = oma::now_ms();
	if (!spawn())
	{
		g.failure = std::string("Could not start ssh: ") + strerror(errno);
		return false;
	}
	// The clipboard's offers and transfers belong to one server: a new one starts clean.
	g.clip.reset();
	g.clip = std::make_unique<gliff::Clipboard>(
	    g.seat, [](const std::string& body, const std::string& payload) { send_msg(body, payload); },
	    [](const std::string& line) { g.link.send(line); });
	g.clip->setEnabled(g.get("clipboard", "1") == "1");
	if (g.get("clipboard", "1") == "1" && !g.clip->enabled())
		log("no clipboard access here (ext-data-control): the clipboard is not shared");
	// The largest stream this client takes. A private screen starts at its own size (at most
	// 1920x1080) and follows the tab once the first Resize arrives, right after HelloAck.
	const uint32_t maxW = 3840, maxH = 2160;
	// 4:4:4 (Dual420) only when decoding on the GPU, as Gliff's own client asks: on the CPU, two
	// streams and the recombination cost more than the sharper text is worth.
	const std::vector<uint8_t> chroma = g.hw && !g.hwBroken
	                                        ? std::vector<uint8_t>{ gliff::CHROMA_DUAL420, gliff::CHROMA_SINGLE420 }
	                                        : std::vector<uint8_t>{ gliff::CHROMA_SINGLE420 };
	send_msg(gliff::hello(g.seat.keymap(), maxW, maxH, chroma));
	g.clip->setFocused(g.focused);
	return true;
}

// Closes the pipes and waits for ssh (two seconds, then it is ended).
static void stop_server()
{
	for (int* fd : { &g.toServer, &g.fromServer, &g.serverErr })
		if (*fd >= 0)
		{
			close(*fd);
			*fd = -1;
		}
	if (g.child > 0)
	{
		for (int i = 0; i < 20 && waitpid(g.child, nullptr, WNOHANG) == 0; i++)
			usleep(100000);
		if (waitpid(g.child, nullptr, WNOHANG) == 0)
		{
			kill(-g.child, SIGTERM);
			waitpid(g.child, nullptr, 0);
		}
	}
	g.child = -1;
}

int main()
{
	std::string line;
	while (std::getline(std::cin, line))
	{
		const size_t eq = line.find('=');
		if (eq == std::string::npos)
			continue;
		if (line.compare(0, eq, "arg") == 0)
			g.args.push_back(line.substr(eq + 1));
		else
			g.cfg[line.substr(0, eq)] = line.substr(eq + 1);
	}
	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	signal(SIGPIPE, SIG_IGN);
	if (g.args.empty())
	{
		log("no command to run");
		return 136;
	}
	if (!g.link.listen(getenv("OMAREMOTE_SOCKET")))
		return 136;
	g.link.onAttach = replay;
	g.headless = g.get("headless") == "1";
	if (g.headless)
		g.cursorState = "cursor-hide";

	open_hw();
	if (!g.seat.start() || g.seat.keymap().empty())
		log("no local keymap: the remote uses its own layout");
	// A new local layout (a keyboard plugged in, the layout changed): the remote follows.
	g.seat.onKeymap = [] {
		log("local keymap changed: sending it on");
		send_msg(gliff::keymap(g.seat.keymap()));
	};
	// A UI that goes away takes the focus with it.
	g.link.onClientChanged = [] {
		// A new UI has none of the surfaces, and holds no pictures: it says "gpu 1" again.
		g.gpuView = false;
		g.exported.clear();
		g.exportedPools[0] = g.exportedPools[1] = nullptr;
		release_held();
		if (!g.link.attached() && g.clip)
		{
			g.focused = false;
			g.clip->setFocused(false);
		}
	};
	log("connecting to %s", g.get("host").c_str());
	if (!start_server())
		return finish(136);

	int rc = 0;
	while (!g.quit)
	{
		if (g.retryAt && oma::now_ms() >= g.retryAt)
		{
			g.retryAt = 0;
			log("reconnecting (try %d of 5)", g.retries);
			if (!start_server())
			{
				rc = 131;
				break;
			}
		}
		flush_out();
		g.seat.flush();
		std::vector<pollfd> fds = { { g.fromServer, POLLIN, 0 },
			                        { g.serverErr, POLLIN, 0 },
			                        { g.toServer, short(g.outbuf.empty() ? 0 : POLLOUT), 0 },
			                        { g.seat.fd(), POLLIN, 0 },
			                        { g.link.listenFd(), POLLIN, 0 },
			                        { g.link.clientFd(), POLLIN, 0 } };
		const size_t fixed = fds.size();
		g.clip->addFds(fds);
		const int n = poll(fds.data(), fds.size(), 250);
		if (n < 0 && errno != EINTR)
			break;
		if (fds[3].revents & (POLLIN | POLLHUP | POLLERR))
			g.seat.dispatch();
		g.clip->handleFds(std::vector<pollfd>(fds.begin() + long(fixed), fds.end()));
		g.clip->tick();
		send_stats();
		if (fds[1].revents & (POLLIN | POLLHUP | POLLERR))
			read_stderr();
		if (fds[0].revents & (POLLIN | POLLHUP | POLLERR))
		{
			if (!read_server())
			{
				if (g.serverErr >= 0)
					read_stderr();
				const bool protocol = !g.failure.empty(); // the server said no, or broke the rules
				int code = -1;
				if (!protocol)
				{
					int status = 0;
					waitpid(g.child, &status, 0);
					g.child = -1;
					code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
					g.failure = last_words();
					if (g.failure.empty())
						g.failure = code == 255 ? "Could not connect" : "The server ended the session";
				}
				// A link that dropped after a picture came (or while reconnecting) is tried again;
				// a refusal, a broken protocol or the remote session ending is not.
				const bool lost = !protocol && code != 0 && (g.connected || g.retries > 0);
				if (lost && g.retries < 5)
				{
					stop_server();
					const int delay = 1 << g.retries; // 1, 2, 4, 8, 16 seconds
					g.retries++;
					log("connection lost (%s): reconnecting in %d s", g.failure.c_str(), delay);
					g.retryAt = oma::now_ms() + uint64_t(delay) * 1000;
					if (g.connected)
					{
						g.connected = false;
						g.link.send("state connecting");
					}
					send_stats_line("health=bad why=reconnecting");
					continue;
				}
				rc = protocol ? (g.welcomed ? 147 : 131) : code == 0 && g.connected ? 0 : g.connected || g.retries ? 147 : 131;
				break;
			}
		}
		for (const auto& l : g.link.poll())
			handle_line(l);
		flush_resize();
		if (!g.welcomed && !g.retryAt && oma::now_ms() - g.attemptAt > 30000)
		{
			g.failure = "The server did not answer within 30 seconds";
			rc = 131;
			break;
		}
	}
	if (g.quit)
	{
		rc = 11;
		release_keys();
		send_msg(gliff::bye());
		flush_out();
	}
	stop_server(); // ssh ends once its input closes
	log("session ended");
	rc = finish(rc);
	g.clip.reset(); // its spool folders go; before the seat it uses
	return rc;
}
