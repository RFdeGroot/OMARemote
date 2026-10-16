// gliff-proto-test: checks native/gliff/msg.hpp against the bytes gliff-proto's own test
// (encodings_are_stable in crates/gliff-proto/src/msg.rs) says are the protocol. Prints one line
// per failure and exits 1; tests/test_gliff.py runs it.

#include "clipboard.hpp"
#include "msg.hpp"
#include "video.hpp"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static int failures = 0;

static std::string hex(const std::string& s)
{
	static const char* digits = "0123456789abcdef";
	std::string out;
	for (unsigned char c : s)
	{
		out += digits[c >> 4];
		out += digits[c & 15];
	}
	return out;
}

static std::string unhex(const std::string& h)
{
	std::string out;
	for (size_t i = 0; i + 1 < h.size(); i += 2)
		out += char(std::stoi(h.substr(i, 2), nullptr, 16));
	return out;
}

static void expect(bool ok, const char* what)
{
	if (!ok)
	{
		printf("FAIL %s\n", what);
		failures++;
	}
}

static void encodes(const std::string& got, const char* want, const char* what)
{
	if (hex(got) != want)
	{
		printf("FAIL %s: %s, want %s\n", what, hex(got).c_str(), want);
		failures++;
	}
}

// gliff-proto's split_yuv444 (chroma.rs), into planar main and aux pictures, and NV12 copies.
struct Picture
{
	int w, h;
	std::vector<uint8_t> y, u, v, uv; // u, v: planar (w/2 x h/2); uv: the same, interleaved
	gliff::Planes planar() const { return { y.data(), w, u.data(), v.data(), w / 2, 1 }; }
	gliff::Planes nv12() const { return { y.data(), w, uv.data(), uv.data() + 1, w, 2 }; }
};

static void split(int w, int h, const std::vector<uint8_t>& Y, const std::vector<uint8_t>& U,
                  const std::vector<uint8_t>& V, Picture& main, Picture& aux)
{
	for (Picture* p : { &main, &aux })
	{
		p->w = w;
		p->h = h;
		p->y.assign(size_t(w * h), 0);
		p->u.assign(size_t(w * h / 4), 0);
		p->v.assign(size_t(w * h / 4), 0);
		p->uv.assign(size_t(w * h / 2), 0);
	}
	main.y = Y;
	for (int by = 0; by < h / 2; by++)
		for (int bx = 0; bx < w / 2; bx++)
		{
			const int c = by * (w / 2) + bx;
			main.u[c] = U[2 * by * w + 2 * bx];
			main.v[c] = V[2 * by * w + 2 * bx];
			aux.u[c] = U[2 * by * w + 2 * bx + 1];
			aux.v[c] = V[2 * by * w + 2 * bx + 1];
		}
	for (int y = 0; y < h / 2; y++)
		for (int x = 0; x < w; x++)
		{
			aux.y[y * w + x] = U[(2 * y + 1) * w + x];
			aux.y[(h / 2 + y) * w + x] = V[(2 * y + 1) * w + x];
		}
	for (Picture* p : { &main, &aux })
		for (int i = 0; i < w * h / 4; i++)
		{
			p->uv[2 * i] = p->u[i];
			p->uv[2 * i + 1] = p->v[i];
		}
}

static void clipboard_tests()
{
	using V = std::vector<std::string>;
	// gliff-proto's forwardable_drops_atoms_and_file_lists_and_collapses_text.
	V got = gliff::forwardable_mimes({ "TARGETS", "text/plain", "image/png", "text/uri-list", "image/png", "UTF8_STRING",
	                                   "x-special/gnome-copied-files", "text/html" });
	V want(std::begin(gliff::TEXT_MIMES), std::end(gliff::TEXT_MIMES));
	want.push_back("image/png");
	want.push_back("text/html");
	expect(got == want, "forwardable mimes");
	expect(gliff::forwardable_mimes({ "x-kde-passwordManagerHint" }) == V{ "x-kde-passwordManagerHint" },
	       "the password hint is a mime like any other here; the offer checks it");
	// resolve_prefers_exact_then_any_text.
	expect(gliff::resolve_mime("image/png", { "image/png", "STRING" }) == "image/png", "resolve exact");
	expect(gliff::resolve_mime("text/plain;charset=utf-8", { "image/png", "STRING" }) == "STRING", "resolve any text");
	expect(gliff::resolve_mime("image/jpeg", { "image/png" }).empty(), "resolve nothing");
	// local_mimes_add_file_lists_only_with_files.
	expect(gliff::local_mimes_for_offer({ "text/plain", "text/uri-list" }, true) ==
	           V{ "text/plain", "text/uri-list", "x-special/gnome-copied-files" },
	       "file lists only with files");
	expect(gliff::local_mimes_for_offer({ "text/plain", "text/uri-list" }, false) == V{ "text/plain" },
	       "no file lists without files");
	// uri_list_round_trips_with_escapes.
	const V paths = { "/home/k/My Docs/a#1.txt", "/tmp/\xc3\xbc.png" };
	expect(gliff::uri_list(paths) == "file:///home/k/My%20Docs/a%231.txt\r\nfile:///tmp/%C3%BC.png\r\n", "uri list");
	expect(gliff::parse_uri_list(gliff::uri_list(paths)) == paths, "uri list round trip");
	expect(gliff::parse_uri_list("# c\nfile://other/x\nhttp://a/b\nfile://localhost/ok\nfile:///bad%zz\nfile:///n%00\n") ==
	           V{ "/ok" },
	       "uri list skips other hosts, schemes, comments and bad escapes");
	expect(gliff::gnome_copied_files({ "/a b" }) == "copy\nfile:///a%20b", "gnome copied files");
	// safe_relative_path.
	for (const char* bad : { "", "/etc/passwd", "../x", "a/../b", "a//b", "./a", "a/", "a/." })
		expect(!gliff::safe_relative_path(bad), bad);
	for (const char* good : { "a", "a/b.txt", "dir/sub/f", "..a", "a..b" })
		expect(gliff::safe_relative_path(good), good);
	// validate_files: duplicates, a directory with a size, too much.
	expect(gliff::validate_files({ { "a", 1, false }, { "d", 0, true }, { "d/b", 2, false } }), "a valid list");
	expect(!gliff::validate_files({ { "a", 1, false }, { "a", 1, false } }), "duplicates refused");
	expect(!gliff::validate_files({ { "d", 5, true } }), "a directory with a size refused");
	expect(!gliff::validate_files({ { "a", 3ull << 30, false }, { "b", 3ull << 30, false } }), "over 4 GiB refused");
	expect(!gliff::validate_files({ { "a", UINT64_MAX, false }, { "b", 2, false } }), "a size that wraps refused");

	// Encodings: [variant, [fields]], the item as [0, [mime]] or [1, [index]].
	encodes(gliff::clipboardRequest(1, 2, "t"), "8209830102820081" "6174", "ClipboardRequest mime");
	encodes(gliff::clipboardRequest(3, 2, "", 5), "820983030282018105", "ClipboardRequest file");
	encodes(gliff::clipboardOffer(7, { "t" }, { { "a", 1, false } }), "8208830781617481836161" "01f4", "ClipboardOffer");
	encodes(gliff::clipboardData(1, 0, 3, true), "820a84010003f5", "ClipboardData");
	encodes(gliff::clipboardAck(1, 300), "820d820119012c", "ClipboardAck");
	encodes(gliff::clipboardAbort(1), "820e8101", "ClipboardAbort");
	{
		// The server's Request for a file, and its Offer, decoded.
		const std::string b = unhex("820683050282018102");
		cbor::Reader r(b.data(), b.size());
		int64_t n = 0;
		gliff::ClipRequest m;
		expect(gliff::open(r, n) == gliff::S_CLIP_REQUEST && gliff::decode(r, n, m) && m.id == 5 && m.serial == 2 &&
		           m.isFile && m.file == 2,
		       "server ClipboardRequest");
		const std::string o = unhex("8205830782617461688183616101f4");
		cbor::Reader r2(o.data(), o.size());
		gliff::ClipOffer off;
		expect(gliff::open(r2, n) == gliff::S_CLIP_OFFER && gliff::decode(r2, n, off) && off.serial == 7 &&
		           off.mimes == V{ "t", "h" } && off.files.size() == 1 && off.files[0].path == "a" && off.files[0].size == 1,
		       "server ClipboardOffer");
	}
}

static void video_tests()
{
	const int w = 64, h = 32;
	std::vector<uint8_t> Y(w * h), U(w * h), V(w * h);
	uint32_t seed = 1;
	auto rnd = [&]() { return uint8_t((seed = seed * 1103515245 + 12345) >> 16); };
	for (int i = 0; i < w * h; i++)
	{
		Y[i] = rnd();
		U[i] = rnd();
		V[i] = rnd();
	}
	std::vector<uint8_t> want(w * h * 4), got(w * h * 4);
	for (int i = 0; i < w * h; i++)
		gliff::rgb().put(&want[i * 4], Y[i], U[i], V[i]);
	Picture main, aux;
	split(w, h, Y, U, V, main, aux);
	gliff::convert444(main.planar(), aux.planar(), h, 0, 0, w, h, got.data(), w * 4);
	expect(got == want, "Dual420 planar recombines to the 4:4:4 picture");
	std::fill(got.begin(), got.end(), 0);
	gliff::convert444(main.nv12(), aux.nv12(), h, 0, 0, w, h, got.data(), w * 4);
	expect(got == want, "Dual420 NV12 recombines to the 4:4:4 picture");

	// A damaged rectangle: only its 2x2 blocks change.
	std::fill(got.begin(), got.end(), 0);
	int x0 = 5, y0 = 3, x1 = 20, y1 = 9;
	gliff::even_rect(x0, y0, x1, y1, w, h);
	expect(x0 == 4 && y0 == 2 && x1 == 20 && y1 == 10, "damage grows to whole blocks");
	gliff::convert444(main.planar(), aux.planar(), h, x0, y0, x1, y1, got.data(), w * 4);
	bool inside = true, outside = true;
	for (int y = 0; y < h; y++)
		for (int x = 0; x < w; x++)
		{
			const bool in = x >= x0 && x < x1 && y >= y0 && y < y1;
			const bool same = memcmp(&got[(y * w + x) * 4], &want[(y * w + x) * 4], 4) == 0;
			const bool zero = got[(y * w + x) * 4 + 3] == 0;
			inside &= !in || same;
			outside &= in || zero;
		}
	expect(inside && outside, "a damaged rectangle converts that rectangle only");

	// Single420: every pixel of a block takes the block's chroma (the even sample).
	for (int y = 0; y < h; y++)
		for (int x = 0; x < w; x++)
		{
			const int c = (y / 2) * (w / 2) + x / 2;
			gliff::rgb().put(&want[(y * w + x) * 4], Y[y * w + x], main.u[c], main.v[c]);
		}
	gliff::convert420(main.planar(), 0, 0, w, h, got.data(), w * 4);
	expect(got == want, "Single420 planar");
	gliff::convert420(main.nv12(), 0, 0, w, h, got.data(), w * 4);
	expect(got == want, "Single420 NV12");

	// BT.709 limited range: black, white, and a saturated red.
	uint8_t px[4];
	gliff::rgb().put(px, 16, 128, 128);
	expect(px[0] == 0 && px[1] == 0 && px[2] == 0, "Y=16 is black");
	gliff::rgb().put(px, 235, 128, 128);
	expect(px[0] == 255 && px[1] == 255 && px[2] == 255, "Y=235 is white");
	gliff::rgb().put(px, 63, 102, 240); // BT.709 limited red
	expect(px[2] >= 253 && px[1] <= 2 && px[0] <= 2, "BT.709 red");
}

int main()
{
	// Client messages: gliff-proto's fixtures (Hello with keymap "k" and feature "f").
	encodes(gliff::hello("k", 3840, 2160, { gliff::CHROMA_DUAL420, gliff::CHROMA_SINGLE420 }, { "f" }),
	        "82008301616b858101190f00190870820102816166", "Hello");
	encodes(gliff::key(30, true), "820282181ef5", "Key");
	encodes(gliff::pointerMotion(12.5, 7.25), "820382fb4029000000000000fb401d000000000000", "PointerMotion");
	encodes(gliff::frameAck(42, 1000), "820682182a1903e8", "FrameAck");
	encodes(gliff::requestKeyframe(), "820780", "RequestKeyframe");
	// Not in the fixtures; the same rules: f32 as four bytes, negative integers as major type 1.
	encodes(gliff::resize(1920, 1080, 1.5f), "820183190780190438fa3fc00000", "Resize");
	encodes(gliff::pointerAxis(0, -15.0, -1), "82058400fbc02e00000000000020f4", "PointerAxis");
	encodes(gliff::pong(7), "82108107", "Pong");
	encodes(gliff::ping(7), "820b8107", "Ping (ClientMsg 11)");
	encodes(gliff::frame("ab", "c"), "02000000010000006162" "63", "frame");

	// Server messages: gliff-proto's fixtures, decoded.
	{
		const std::string b = unhex("8200840182f5616f8184616f1907801904381903e880");
		cbor::Reader r(b.data(), b.size());
		int64_t n = 0;
		gliff::HelloAck m;
		expect(gliff::open(r, n) == gliff::S_HELLO_ACK && gliff::decode(r, n, m), "HelloAck decodes");
		expect(m.version == 1 && m.headless && m.output == "o" && m.outputs.size() == 1 &&
		           m.outputs[0].width == 1920 && m.outputs[0].height == 1080 && m.outputs[0].scaleMilli == 1000,
		       "HelloAck fields");
		expect(r.p == r.end, "HelloAck read to the end");
	}
	{
		const std::string b = unhex("82018b0101001907801904381903e840f6190780190438183c");
		cbor::Reader r(b.data(), b.size());
		int64_t n = 0;
		gliff::StreamConfig m;
		expect(gliff::open(r, n) == gliff::S_STREAM_CONFIG && gliff::decode(r, n, m), "StreamConfig decodes");
		expect(m.codec == gliff::CODEC_H264 && m.chroma == gliff::CHROMA_DUAL420 && m.pipeline == 0 &&
		           m.width == 1920 && m.height == 1080 && m.scaleMilli == 1000 && m.extradata.empty() &&
		           m.auxExtradata.empty() && m.viewWidth == 1920 && m.viewHeight == 1080 && m.fpsCap == 60,
		       "StreamConfig fields");
		expect(r.p == r.end, "StreamConfig read to the end");
	}
	{
		const std::string b = unhex("8202860102f5818400000a0a18641832");
		cbor::Reader r(b.data(), b.size());
		int64_t n = 0;
		gliff::VideoFrame m;
		expect(gliff::open(r, n) == gliff::S_VIDEO_FRAME && gliff::decode(r, n, m), "VideoFrame decodes");
		expect(m.frameId == 1 && m.ptsUs == 2 && m.keyframe && m.damage.size() == 1 && m.damage[0].width == 10 &&
		           m.damage[0].height == 10 && m.dataLen == 100 && m.auxLen == 50,
		       "VideoFrame fields");
	}
	{
		const std::string b = unhex("82098301616d01");
		cbor::Reader r(b.data(), b.size());
		int64_t n = 0;
		gliff::Error m;
		expect(gliff::open(r, n) == gliff::S_ERROR && gliff::decode(r, n, m), "Error decodes");
		expect(m.code == 1 && m.message == "m" && m.version == 1 && gliff::incompatible(m.code), "Error fields");
	}
	{
		// A newer server: StreamConfig with one more field (a map) and an unknown pipeline value.
		const std::string b = unhex("82018c0101051907801904381903e840f6190780190438183ca1616101");
		cbor::Reader r(b.data(), b.size());
		int64_t n = 0;
		gliff::StreamConfig m;
		expect(gliff::open(r, n) == gliff::S_STREAM_CONFIG && gliff::decode(r, n, m), "newer StreamConfig decodes");
		expect(m.pipeline == -1 && m.fpsCap == 60 && r.p == r.end, "newer StreamConfig skips what it does not know");
	}
	{
		// Truncated or hostile bodies never read past the end.
		const char* bad[] = { "", "82", "8201", "82018b01", "5bffffffffffffffff", "9bffffffffffffffff", "820183ff" };
		for (const char* h : bad)
		{
			const std::string b = unhex(h);
			cbor::Reader r(b.data(), b.size());
			int64_t n = 0;
			gliff::StreamConfig m;
			const int64_t v = gliff::open(r, n);
			expect(v < 0 || !gliff::decode(r, n, m), h);
		}
	}
	video_tests();
	clipboard_tests();
	if (failures == 0)
		printf("ok\n");
	return failures ? 1 : 0;
}
