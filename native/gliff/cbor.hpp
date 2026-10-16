#pragma once

// The little CBOR Gliff's protocol needs (crates/gliff-proto/src/msg.rs), written by hand: messages
// are `[variant, [field 0, field 1, ...]]` with integers, booleans, floats, text, bytes, null and
// arrays. Encoding follows minicbor's choices (shortest integers, f64 always eight bytes, f32 four),
// so the bytes equal gliff-proto's fixtures (tests/test_gliff.py checks them).

#include <cstdint>
#include <cstring>
#include <string>

namespace cbor
{

// ---------------------------------------------------------------- writing

inline void head(std::string& out, uint8_t major, uint64_t v)
{
	const uint8_t m = uint8_t(major << 5);
	if (v < 24)
		out += char(m | v);
	else if (v <= 0xFF)
	{
		out += char(m | 24);
		out += char(v);
	}
	else if (v <= 0xFFFF)
	{
		out += char(m | 25);
		for (int s = 8; s >= 0; s -= 8)
			out += char(v >> s);
	}
	else if (v <= 0xFFFFFFFFull)
	{
		out += char(m | 26);
		for (int s = 24; s >= 0; s -= 8)
			out += char(v >> s);
	}
	else
	{
		out += char(m | 27);
		for (int s = 56; s >= 0; s -= 8)
			out += char(v >> s);
	}
}

inline void uint(std::string& out, uint64_t v) { head(out, 0, v); }
inline void sint(std::string& out, int64_t v)
{
	if (v >= 0)
		head(out, 0, uint64_t(v));
	else
		head(out, 1, uint64_t(-1 - v));
}
inline void boolean(std::string& out, bool v) { out += char(v ? 0xF5 : 0xF4); }
inline void null(std::string& out) { out += char(0xF6); }
inline void array(std::string& out, uint64_t n) { head(out, 4, n); }
inline void text(std::string& out, const std::string& s)
{
	head(out, 3, s.size());
	out += s;
}
inline void f32(std::string& out, float v)
{
	uint32_t bits;
	memcpy(&bits, &v, 4);
	out += char(0xFA);
	for (int s = 24; s >= 0; s -= 8)
		out += char(bits >> s);
}
inline void f64(std::string& out, double v)
{
	uint64_t bits;
	memcpy(&bits, &v, 8);
	out += char(0xFB);
	for (int s = 56; s >= 0; s -= 8)
		out += char(bits >> s);
}

// ---------------------------------------------------------------- reading

// A cursor over one message. Every read checks the bounds and the type; the first mismatch sets
// `bad`, after which reads return zero values, so a decoder checks `bad` once at the end.
struct Reader
{
	const uint8_t* p;
	const uint8_t* end;
	bool bad = false;

	Reader(const void* data, size_t len) : p(static_cast<const uint8_t*>(data)), end(p + len) {}

	int peek() const { return p < end ? *p : -1; }
	bool isNull() const { return peek() == 0xF6; }

	// The head of the next item: its major type and argument. Indefinite lengths are refused:
	// minicbor writes definite ones.
	bool readHead(uint8_t& major, uint64_t& v)
	{
		if (bad || p >= end)
			return fail();
		const uint8_t b = *p++;
		major = b >> 5;
		const uint8_t info = b & 31;
		if (info < 24)
		{
			v = info;
			return true;
		}
		if (major == 7)
		{
			v = info; // simple values and floats: the caller reads what follows
			return true;
		}
		const int n = info == 24 ? 1 : info == 25 ? 2 : info == 26 ? 4 : info == 27 ? 8 : 0;
		if (n == 0 || end - p < n)
			return fail();
		v = 0;
		for (int i = 0; i < n; i++)
			v = (v << 8) | *p++;
		return true;
	}

	bool fail()
	{
		bad = true;
		p = end;
		return false;
	}

	uint64_t u64()
	{
		uint8_t m;
		uint64_t v;
		if (!readHead(m, v) || m != 0)
			return fail(), 0;
		return v;
	}
	int64_t i64()
	{
		uint8_t m;
		uint64_t v;
		if (!readHead(m, v) || (m != 0 && m != 1) || v > uint64_t(INT64_MAX))
			return fail(), 0;
		return m == 0 ? int64_t(v) : -1 - int64_t(v);
	}
	bool boolean()
	{
		const int b = peek();
		if (b != 0xF4 && b != 0xF5)
			return fail();
		p++;
		return b == 0xF5;
	}
	double number()
	{
		const int b = peek();
		if (b == 0xFA && end - p >= 5)
		{
			uint32_t bits = 0;
			for (int i = 1; i <= 4; i++)
				bits = (bits << 8) | p[i];
			p += 5;
			float f;
			memcpy(&f, &bits, 4);
			return f;
		}
		if (b == 0xFB && end - p >= 9)
		{
			uint64_t bits = 0;
			for (int i = 1; i <= 8; i++)
				bits = (bits << 8) | p[i];
			p += 9;
			double d;
			memcpy(&d, &bits, 8);
			return d;
		}
		if (b >= 0 && (b >> 5) <= 1)
			return double(i64());
		return fail(), 0.0;
	}
	// The length of an array, or -1 (and bad) when the next item is not one.
	int64_t array()
	{
		uint8_t m;
		uint64_t v;
		if (!readHead(m, v) || m != 4 || v > uint64_t(end - p))
			return fail(), -1;
		return int64_t(v);
	}
	std::string string(uint8_t want) // 2: bytes, 3: text
	{
		uint8_t m;
		uint64_t v;
		if (!readHead(m, v) || m != want || v > uint64_t(end - p))
			return fail(), std::string();
		std::string s(reinterpret_cast<const char*>(p), size_t(v));
		p += v;
		return s;
	}
	std::string text() { return string(3); }
	std::string bytes() { return string(2); }

	// Skips one item whatever it is: unknown fields of a newer peer.
	void skip(int depth = 0)
	{
		if (depth > 32)
		{
			fail();
			return;
		}
		uint8_t m;
		uint64_t v;
		if (!readHead(m, v))
			return;
		switch (m)
		{
			case 0:
			case 1: return;
			case 2:
			case 3:
				if (v > uint64_t(end - p))
					fail();
				else
					p += v;
				return;
			case 4:
				for (uint64_t i = 0; i < v && !bad; i++)
					skip(depth + 1);
				return;
			case 5:
				for (uint64_t i = 0; i < v * 2 && !bad; i++)
					skip(depth + 1);
				return;
			case 6: skip(depth + 1); return;
			default:
			{
				const int n = v == 25 ? 2 : v == 26 ? 4 : v == 27 ? 8 : v == 24 ? 1 : 0;
				if (end - p < n)
					fail();
				else
					p += n;
			}
		}
	}
};

} // namespace cbor
