#pragma once

// Decoded Gliff video to the BGRX framebuffer, one damaged rectangle at a time.
//
// Single420: one 4:2:0 picture. Dual420 (4:4:4 from two 4:2:0 pictures, crates/gliff-proto/src/
// chroma.rs): the main picture carries Y and the chroma of even rows and columns; the auxiliary
// one carries the rest, recombined here on the fly with no 4:4:4 buffer in between:
//   aux.Y  top half:    U of the odd rows      aux.Y bottom half: V of the odd rows
//   aux.UV:             U and V of even rows, odd columns
// Colour: BT.709, limited range (crates/gliff-proto/src/color.rs, yuv444_to_bgra).
//
// A picture is planar (FFmpeg's software decoder, YUV420P) or NV12 (VA-API, downloaded): Planes
// covers both with a chroma step of 1 or 2.

#include <algorithm>
#include <cstdint>

namespace gliff
{

struct Planes
{
	const uint8_t* y = nullptr;
	int yStride = 0;
	const uint8_t* u = nullptr; // NV12: the UV plane
	const uint8_t* v = nullptr; // NV12: the UV plane + 1
	int cStride = 0;
	int cStep = 1; // 1 planar, 2 interleaved
};

struct Rgb
{
	int32_t y[256], rv[256], gu[256], gv[256], bu[256];

	Rgb()
	{
		for (int i = 0; i < 256; i++)
		{
			y[i] = int32_t(1.1644 * (i - 16) * 65536.0 + 32768.0); // rounding folded in
			rv[i] = int32_t(1.7927 * (i - 128) * 65536.0);
			gu[i] = int32_t(-0.2132 * (i - 128) * 65536.0);
			gv[i] = int32_t(-0.5329 * (i - 128) * 65536.0);
			bu[i] = int32_t(2.1124 * (i - 128) * 65536.0);
		}
	}

	static uint8_t clamp(int32_t v) { return uint8_t(std::clamp(v >> 16, 0, 255)); }

	void put(uint8_t* px, uint8_t yy, uint8_t u, uint8_t v) const
	{
		const int32_t l = y[yy];
		px[0] = clamp(l + bu[u]);
		px[1] = clamp(l + gu[u] + gv[v]);
		px[2] = clamp(l + rv[v]);
		px[3] = 0xFF;
	}
};

inline const Rgb& rgb()
{
	static const Rgb table;
	return table;
}

// The rectangle grown to whole 2x2 blocks and kept inside w x h (both even).
inline void even_rect(int& x0, int& y0, int& x1, int& y1, int w, int h)
{
	x0 = std::clamp(x0 & ~1, 0, w);
	y0 = std::clamp(y0 & ~1, 0, h);
	x1 = std::clamp((x1 + 1) & ~1, 0, w);
	y1 = std::clamp((y1 + 1) & ~1, 0, h);
}

// Single420: each chroma sample covers its 2x2 block.
inline void convert420(const Planes& m, int x0, int y0, int x1, int y1, uint8_t* out, int outStride)
{
	const Rgb& t = rgb();
#pragma omp parallel for schedule(static) if ((x1 - x0) * (y1 - y0) > 65536)
	for (int y = y0; y < y1; y += 2)
	{
		const uint8_t* cu = m.u + (y / 2) * m.cStride;
		const uint8_t* cv = m.v + (y / 2) * m.cStride;
		for (int row = 0; row < 2; row++)
		{
			const uint8_t* ly = m.y + (y + row) * m.yStride;
			uint8_t* o = out + (y + row) * outStride;
			for (int x = x0; x < x1; x += 2)
			{
				const int c = (x / 2) * m.cStep;
				t.put(o + x * 4, ly[x], cu[c], cv[c]);
				t.put(o + (x + 1) * 4, ly[x + 1], cu[c], cv[c]);
			}
		}
	}
}

// Dual420: the main and auxiliary pictures (both w x h) recombined into full chroma.
inline void convert444(const Planes& m, const Planes& a, int h, int x0, int y0, int x1, int y1, uint8_t* out,
                       int outStride)
{
	const Rgb& t = rgb();
	const int half = h / 2;
	// Row pairs are independent: spread over the cores for anything bigger than a small change.
#pragma omp parallel for schedule(static) if ((x1 - x0) * (y1 - y0) > 65536)
	for (int y = y0; y < y1; y += 2)
	{
		const int by = y / 2;
		// Even row: U and V from main (even column) and aux's chroma (odd column).
		const uint8_t* ly = m.y + y * m.yStride;
		const uint8_t* mu = m.u + by * m.cStride;
		const uint8_t* mv = m.v + by * m.cStride;
		const uint8_t* au = a.u + by * a.cStride;
		const uint8_t* av = a.v + by * a.cStride;
		uint8_t* o = out + y * outStride;
		for (int x = x0; x < x1; x += 2)
		{
			const int mc = (x / 2) * m.cStep, ac = (x / 2) * a.cStep;
			t.put(o + x * 4, ly[x], mu[mc], mv[mc]);
			t.put(o + (x + 1) * 4, ly[x + 1], au[ac], av[ac]);
		}
		// Odd row: full-width U from aux.Y's top half, V from its bottom half.
		const uint8_t* ly1 = m.y + (y + 1) * m.yStride;
		const uint8_t* ou = a.y + by * a.yStride;
		const uint8_t* ov = a.y + (half + by) * a.yStride;
		uint8_t* o1 = out + (y + 1) * outStride;
		for (int x = x0; x < x1; x++)
			t.put(o1 + x * 4, ly1[x], ou[x], ov[x]);
	}
}

} // namespace gliff
