#pragma once

// Gliff's protocol (version 1), the parts OMARemote's client uses: crates/gliff-proto/src/msg.rs and
// frame.rs in github.com/omacom/gliff. A message is `[variant, [fields...]]`; on the wire it goes
// as `u32 body_len | u32 payload_len` (little-endian), the CBOR body, then the payload bytes (video,
// cursor pixels). Fields a newer server appends are skipped; messages this client does not know
// are skipped by their lengths.

#include "cbor.hpp"

#include <cstdint>
#include <string>
#include <vector>

namespace gliff
{

constexpr uint16_t PROTOCOL_VERSION = 1;
constexpr size_t HEADER_LEN = 8;
constexpr uint32_t MAX_FRAME_BODY = 1 << 20;
constexpr uint32_t MAX_FRAME_PAYLOAD = 128u * 1024 * 1024;

enum Codec : uint8_t { CODEC_RAW_BGRA = 0, CODEC_H264 = 1 };
enum Chroma : uint8_t { CHROMA_NATIVE444 = 0, CHROMA_DUAL420 = 1, CHROMA_SINGLE420 = 2 };

// Evdev pointer buttons.
constexpr uint32_t BTN_LEFT = 0x110, BTN_RIGHT = 0x111, BTN_MIDDLE = 0x112, BTN_SIDE = 0x113, BTN_EXTRA = 0x114;

// ---------------------------------------------------------------- client messages

inline std::string variant(unsigned n, unsigned fields)
{
	std::string out;
	cbor::array(out, 2);
	cbor::uint(out, n);
	cbor::array(out, fields);
	return out;
}

inline std::string hello(const std::string& keymap, uint32_t maxW, uint32_t maxH, const std::vector<uint8_t>& chroma,
                         const std::vector<std::string>& features = {})
{
	std::string out = variant(0, 3);
	cbor::uint(out, PROTOCOL_VERSION);
	cbor::text(out, keymap);
	cbor::array(out, 5);
	cbor::array(out, 1);
	cbor::uint(out, CODEC_H264);
	cbor::uint(out, maxW);
	cbor::uint(out, maxH);
	cbor::array(out, chroma.size());
	for (uint8_t c : chroma)
		cbor::uint(out, c);
	cbor::array(out, features.size());
	for (const auto& f : features)
		cbor::text(out, f);
	return out;
}

inline std::string resize(uint32_t w, uint32_t h, float scale)
{
	std::string out = variant(1, 3);
	cbor::uint(out, w);
	cbor::uint(out, h);
	cbor::f32(out, scale);
	return out;
}

inline std::string key(uint32_t keycode, bool pressed)
{
	std::string out = variant(2, 2);
	cbor::uint(out, keycode);
	cbor::boolean(out, pressed);
	return out;
}

inline std::string pointerMotion(double x, double y)
{
	std::string out = variant(3, 2);
	cbor::f64(out, x);
	cbor::f64(out, y);
	return out;
}

inline std::string pointerButton(uint32_t button, bool pressed)
{
	std::string out = variant(4, 2);
	cbor::uint(out, button);
	cbor::boolean(out, pressed);
	return out;
}

// axis 0: vertical, 1: horizontal; value in Wayland's units (positive: down or right).
inline std::string pointerAxis(unsigned axis, double value, int discrete)
{
	std::string out = variant(5, 4);
	cbor::uint(out, axis);
	cbor::f64(out, value);
	cbor::sint(out, discrete);
	cbor::boolean(out, false);
	return out;
}

inline std::string frameAck(uint64_t frameId, uint64_t decodedAtMs)
{
	std::string out = variant(6, 2);
	cbor::uint(out, frameId);
	cbor::uint(out, decodedAtMs);
	return out;
}

inline std::string requestKeyframe() { return variant(7, 0); }

// Answered by the server's Pong with the same t: our round trip, on a still screen too.
inline std::string ping(uint64_t t)
{
	std::string out = variant(11, 1);
	cbor::uint(out, t);
	return out;
}
inline std::string bye() { return variant(12, 0); }

// The local keymap changed since Hello; XKB text as there.
inline std::string keymap(const std::string& text)
{
	std::string out = variant(15, 1);
	cbor::text(out, text);
	return out;
}

inline std::string pong(uint64_t t)
{
	std::string out = variant(16, 1);
	cbor::uint(out, t);
	return out;
}

// ---- clipboard (crates/gliff-proto/src/clipboard.rs), the same shapes both ways

struct ClipboardFile
{
	std::string path; // relative, '/'-separated; a top-level entry is its own name
	uint64_t size = 0;
	bool dir = false;
};

inline void clipboardFiles(std::string& out, const std::vector<ClipboardFile>& files)
{
	cbor::array(out, files.size());
	for (const auto& f : files)
	{
		cbor::array(out, 3);
		cbor::text(out, f.path);
		cbor::uint(out, f.size);
		cbor::boolean(out, f.dir);
	}
}

inline std::string clipboardOffer(uint32_t serial, const std::vector<std::string>& mimes,
                                  const std::vector<ClipboardFile>& files)
{
	std::string out = variant(8, 3);
	cbor::uint(out, serial);
	cbor::array(out, mimes.size());
	for (const auto& m : mimes)
		cbor::text(out, m);
	clipboardFiles(out, files);
	return out;
}

// item: a mime type, or (file >= 0) an index into the offer's files.
inline std::string clipboardRequest(uint32_t id, uint32_t serial, const std::string& mime, int64_t file = -1)
{
	std::string out = variant(9, 3);
	cbor::uint(out, id);
	cbor::uint(out, serial);
	cbor::array(out, 2);
	cbor::uint(out, file >= 0 ? 1 : 0);
	cbor::array(out, 1);
	if (file >= 0)
		cbor::uint(out, uint64_t(file));
	else
		cbor::text(out, mime);
	return out;
}

// data_len payload bytes follow the body.
inline std::string clipboardData(uint32_t id, uint64_t offset, uint32_t len, bool done)
{
	std::string out = variant(10, 4);
	cbor::uint(out, id);
	cbor::uint(out, offset);
	cbor::uint(out, len);
	cbor::boolean(out, done);
	return out;
}

inline std::string clipboardAck(uint32_t id, uint64_t received)
{
	std::string out = variant(13, 2);
	cbor::uint(out, id);
	cbor::uint(out, received);
	return out;
}

inline std::string clipboardAbort(uint32_t id)
{
	std::string out = variant(14, 1);
	cbor::uint(out, id);
	return out;
}

// The frame around a body and its payload.
inline std::string frame(const std::string& body, const std::string& payload = {})
{
	std::string out;
	const uint32_t lens[2] = { uint32_t(body.size()), uint32_t(payload.size()) };
	for (uint32_t v : lens)
		for (int i = 0; i < 4; i++)
			out += char(v >> (8 * i));
	return out + body + payload;
}

// ---------------------------------------------------------------- server messages

struct OutputInfo
{
	std::string name;
	uint32_t width = 0, height = 0, scaleMilli = 1000;
};

struct HelloAck
{
	uint16_t version = 0;
	bool headless = false;
	std::string output;
	std::vector<OutputInfo> outputs;
};

struct StreamConfig
{
	uint32_t codec = 0, chroma = 0;
	int pipeline = -1; // 0 gpu, 1 cpu, -1 not said
	uint32_t width = 0, height = 0, scaleMilli = 1000;
	std::string extradata, auxExtradata;
	uint32_t viewWidth = 0, viewHeight = 0, fpsCap = 0;
};

struct Rect
{
	int32_t x = 0, y = 0, width = 0, height = 0;
};

struct VideoFrame
{
	uint64_t frameId = 0, ptsUs = 0;
	bool keyframe = false;
	std::vector<Rect> damage;
	uint32_t dataLen = 0, auxLen = 0;
};

struct CursorShape
{
	uint32_t id = 0, width = 0, height = 0;
	int32_t hotX = 0, hotY = 0;
	uint32_t argbLen = 0;
};

struct CursorPos
{
	double x = 0, y = 0;
	uint32_t shapeId = 0;
	bool visible = false;
};

struct Error
{
	uint32_t code = 0;
	std::string message;
	int version = -1;
};

// Reads `[variant, [fields...]]`: the variant number and the field count; -1 when malformed.
inline int64_t open(cbor::Reader& r, int64_t& fields)
{
	if (r.array() != 2)
		return -1;
	const int64_t v = int64_t(r.u64());
	fields = r.array();
	return r.bad ? -1 : v;
}

// Each decoder reads the fields it knows, in order, and skips the rest. A field missing at the end
// keeps its default (minicbor leaves out trailing absent options).
inline void rest(cbor::Reader& r, int64_t fields, int64_t read)
{
	for (int64_t i = read; i < fields && !r.bad; i++)
		r.skip();
}

inline bool decode(cbor::Reader& r, int64_t n, HelloAck& m)
{
	if (n < 4)
		return false;
	m.version = uint16_t(r.u64());
	const int64_t s = r.array();
	if (s < 2)
		return false;
	m.headless = r.boolean();
	m.output = r.text();
	rest(r, s, 2);
	const int64_t outs = r.array();
	for (int64_t i = 0; i < outs && !r.bad; i++)
	{
		const int64_t f = r.array();
		if (f < 4)
			return false;
		OutputInfo o;
		o.name = r.text();
		o.width = uint32_t(r.u64());
		o.height = uint32_t(r.u64());
		o.scaleMilli = uint32_t(r.u64());
		rest(r, f, 4);
		m.outputs.push_back(o);
	}
	r.skip(); // features
	rest(r, n, 4);
	return !r.bad;
}

inline bool decode(cbor::Reader& r, int64_t n, StreamConfig& m)
{
	if (n < 10)
		return false;
	m.codec = uint32_t(r.u64());
	m.chroma = uint32_t(r.u64());
	if (r.isNull())
		r.skip();
	else
	{
		const uint64_t p = r.u64(); // a value this build does not know is "not said"
		m.pipeline = p <= 1 ? int(p) : -1;
	}
	m.width = uint32_t(r.u64());
	m.height = uint32_t(r.u64());
	m.scaleMilli = uint32_t(r.u64());
	m.extradata = r.bytes();
	if (r.isNull())
		r.skip();
	else
		m.auxExtradata = r.bytes();
	m.viewWidth = uint32_t(r.u64());
	m.viewHeight = uint32_t(r.u64());
	if (n > 10)
		m.fpsCap = uint32_t(r.u64());
	rest(r, n, 11);
	return !r.bad;
}

inline bool decode(cbor::Reader& r, int64_t n, VideoFrame& m)
{
	if (n < 6)
		return false;
	m.frameId = r.u64();
	m.ptsUs = r.u64();
	m.keyframe = r.boolean();
	const int64_t rects = r.array();
	for (int64_t i = 0; i < rects && !r.bad; i++)
	{
		const int64_t f = r.array();
		if (f < 4)
			return false;
		Rect d;
		d.x = int32_t(r.i64());
		d.y = int32_t(r.i64());
		d.width = int32_t(r.i64());
		d.height = int32_t(r.i64());
		rest(r, f, 4);
		m.damage.push_back(d);
	}
	m.dataLen = uint32_t(r.u64());
	m.auxLen = uint32_t(r.u64());
	rest(r, n, 6);
	return !r.bad;
}

inline bool decode(cbor::Reader& r, int64_t n, CursorShape& m)
{
	if (n < 6)
		return false;
	m.id = uint32_t(r.u64());
	m.width = uint32_t(r.u64());
	m.height = uint32_t(r.u64());
	m.hotX = int32_t(r.i64());
	m.hotY = int32_t(r.i64());
	m.argbLen = uint32_t(r.u64());
	rest(r, n, 6);
	return !r.bad;
}

inline bool decode(cbor::Reader& r, int64_t n, CursorPos& m)
{
	if (n < 4)
		return false;
	m.x = r.number();
	m.y = r.number();
	m.shapeId = uint32_t(r.u64());
	m.visible = r.boolean();
	rest(r, n, 4);
	return !r.bad;
}

inline bool decode(cbor::Reader& r, int64_t n, Error& m)
{
	if (n < 2)
		return false;
	m.code = uint32_t(r.u64());
	m.message = r.text();
	if (n > 2)
	{
		if (r.isNull())
			r.skip();
		else
			m.version = int(r.u64());
	}
	rest(r, n, 3);
	return !r.bad;
}

struct ClipOffer
{
	uint32_t serial = 0;
	std::vector<std::string> mimes;
	std::vector<ClipboardFile> files;
};

struct ClipRequest
{
	uint32_t id = 0, serial = 0;
	bool isFile = false;
	std::string mime;
	uint64_t file = 0;
};

struct ClipData
{
	uint32_t id = 0;
	uint64_t offset = 0;
	uint32_t len = 0;
	bool done = false;
};

// Limits on what a peer's offer may hold before it is refused whole.
constexpr size_t CLIP_MAX_MIMES = 64;
constexpr size_t CLIP_MAX_ENTRIES = 10000;

inline bool decode(cbor::Reader& r, int64_t n, ClipOffer& m)
{
	if (n < 3)
		return false;
	m.serial = uint32_t(r.u64());
	const int64_t mimes = r.array();
	if (mimes < 0 || size_t(mimes) > CLIP_MAX_MIMES)
		return false;
	for (int64_t i = 0; i < mimes && !r.bad; i++)
		m.mimes.push_back(r.text());
	const int64_t files = r.array();
	if (files < 0 || size_t(files) > CLIP_MAX_ENTRIES)
		return false;
	for (int64_t i = 0; i < files && !r.bad; i++)
	{
		const int64_t f = r.array();
		if (f < 3)
			return false;
		ClipboardFile cf;
		cf.path = r.text();
		cf.size = r.u64();
		cf.dir = r.boolean();
		rest(r, f, 3);
		m.files.push_back(cf);
	}
	rest(r, n, 3);
	return !r.bad;
}

inline bool decode(cbor::Reader& r, int64_t n, ClipRequest& m)
{
	if (n < 3)
		return false;
	m.id = uint32_t(r.u64());
	m.serial = uint32_t(r.u64());
	int64_t fields = 0;
	const int64_t kind = open(r, fields);
	if (kind < 0 || fields < 1)
		return false;
	if (kind == 0)
		m.mime = r.text();
	else if (kind == 1)
	{
		m.isFile = true;
		m.file = r.u64();
	}
	else
		return false;
	rest(r, fields, 1);
	rest(r, n, 3);
	return !r.bad;
}

inline bool decode(cbor::Reader& r, int64_t n, ClipData& m)
{
	if (n < 4)
		return false;
	m.id = uint32_t(r.u64());
	m.offset = r.u64();
	m.len = uint32_t(r.u64());
	m.done = r.boolean();
	rest(r, n, 4);
	return !r.bad;
}

// Ack and Abort: the id first, then (Ack) the bytes received.
inline bool decodeIdAndCount(cbor::Reader& r, int64_t n, uint32_t& id, uint64_t& count)
{
	if (n < 1)
		return false;
	id = uint32_t(r.u64());
	count = n >= 2 ? r.u64() : 0;
	rest(r, n, n >= 2 ? 2 : 1);
	return !r.bad;
}

// The server's message numbers.
enum ServerVariant : int64_t
{
	S_HELLO_ACK = 0,
	S_STREAM_CONFIG = 1,
	S_VIDEO_FRAME = 2,
	S_CURSOR_SHAPE = 3,
	S_CURSOR_POS = 4,
	S_CLIP_OFFER = 5,
	S_CLIP_REQUEST = 6,
	S_CLIP_DATA = 7,
	S_CLIP_ACK = 10,
	S_CLIP_ABORT = 11,
	S_PONG = 8,
	S_ERROR = 9,
	S_PING = 12,
};

// Codes 1 to 255 mean the two ends cannot work together.
inline bool incompatible(uint32_t code) { return code >= 1 && code < 256; }

} // namespace gliff
