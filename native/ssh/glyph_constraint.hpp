// How a symbol's glyph is sized and placed in its cell(s): Ghostty's constraint rules
// (src/font/Glyph.zig RenderOptions.Constraint and src/renderer/cell.zig constraintWidth, MIT),
// ported as they are, with the Nerd Font table generated from the same pinned libghostty-vt source
// (ghostty-vt/gen_nerd_font.py). Coordinates as Ghostty's: pixels, x from the cell's left edge, y
// from the cell's bottom edge upward, a glyph's box by its bottom-left corner.
#pragma once

#include "ghostty_nerd_font.hpp"

#include <algorithm>
#include <cstdint>

namespace glyphfit
{

using nerdfont::Constraint;

struct Box
{
	double width = 0, height = 0, x = 0, y = 0;
};

// Ghostty's grid metrics, the ones constraints read.
struct Metrics
{
	double cellWidth = 0, cellHeight = 0; // whole pixels
	double faceWidth = 0, faceHeight = 0; // the font's own advance and line height, unrounded
	double faceY = 0;                     // the face's bottom above the cell's bottom
	double iconHeight = 0, iconHeightSingle = 0;
};

// Ghostty's "symbol-like" characters (uucode is_symbol): private use, and these blocks.
inline bool is_symbol(uint32_t cp)
{
	return (cp >= 0xE000 && cp <= 0xF8FF) || (cp >= 0xF0000 && cp <= 0xFFFFD) || (cp >= 0x100000 && cp <= 0x10FFFD) ||
	       (cp >= 0x2190 && cp <= 0x21FF) ||   // arrows
	       (cp >= 0x2460 && cp <= 0x24FF) ||   // enclosed alphanumerics
	       (cp >= 0x2600 && cp <= 0x26FF) ||   // miscellaneous symbols
	       (cp >= 0x2700 && cp <= 0x27BF) ||   // dingbats
	       (cp >= 0x1F100 && cp <= 0x1F1FF) || // enclosed alphanumeric supplement
	       (cp >= 0x1F300 && cp <= 0x1F5FF) || // miscellaneous symbols and pictographs
	       (cp >= 0x1F600 && cp <= 0x1F64F) || // emoticons
	       (cp >= 0x1F680 && cp <= 0x1F6FF);   // transport and map symbols
}

// Box drawing, block elements, legacy computing and Powerline: symbols meant to join up.
inline bool is_graphics_element(uint32_t cp)
{
	return (cp >= 0x2500 && cp <= 0x259F) || (cp >= 0x1FB00 && cp <= 0x1FBFF) || (cp >= 0x1CC00 && cp <= 0x1CEBF) ||
	       (cp >= 0xE0B0 && cp <= 0xE0D7);
}

// The constraint Ghostty draws cp with: its Nerd Font rule, else a symbol fits its cell(s).
inline Constraint constraint_for(uint32_t cp)
{
	const Constraint& c = nerdfont::get(cp);
	if (c.known)
		return c;
	Constraint fit;
	if (is_symbol(cp))
	{
		fit.known = true;
		fit.size = nerdfont::Fit;
	}
	return fit;
}

// How many cells the glyph at col may use (cps: the first codepoint of each cell, 0 when empty;
// gridWidth: 2 for a wide character).
inline int constraint_width(const uint32_t* cps, int col, int cols, int gridWidth)
{
	if (gridWidth > 1)
		return gridWidth;
	if (!is_symbol(cps[col]))
		return gridWidth;
	if (col == cols - 1)
		return 1;
	// After another symbol: one cell, so a row of icons lines up (not after a graphics element).
	if (col > 0 && is_symbol(cps[col - 1]) && !is_graphics_element(cps[col - 1]))
		return 1;
	const uint32_t next = cps[col + 1];
	return next == 0 || next == 0x20 || next == 0x2002 ? 2 : 1;
}

inline bool does_anything(const Constraint& c)
{
	return c.size != nerdfont::None || c.alignH != nerdfont::AlignNone || c.alignV != nerdfont::AlignNone;
}

namespace detail
{

inline void scale_factors(const Constraint& c, const Box& group, const Metrics& m, int width, double& wf, double& hf)
{
	using namespace nerdfont;
	if (c.size == None)
	{
		wf = hf = 1;
		return;
	}
	const bool multi = width > 1;
	const double padW = double(width) - (c.padLeft + c.padRight);
	const double padH = 1 - (c.padBottom + c.padTop);
	const double targetW = padW * m.faceWidth;
	const double targetH =
	    padH * (c.height == CellHeight ? m.faceHeight : multi ? m.iconHeight : m.iconHeightSingle);
	wf = targetW / group.width;
	hf = targetH / group.height;
	switch (c.size)
	{
	case Fit:
		hf = std::min({ 1.0, wf, hf });
		wf = hf;
		break;
	case Cover:
		hf = std::min(wf, hf);
		wf = hf;
		break;
	case FitCover1:
		hf = std::min(wf, hf);
		if (multi && hf > 1)
		{
			double w1, h1;
			scale_factors(c, group, m, 1, w1, h1);
			hf = std::max(1.0, h1);
		}
		wf = hf;
		break;
	default: // Stretch
		break;
	}
	if (c.maxXYRatio > 0 && group.width * wf > group.height * hf * c.maxXYRatio)
		wf = group.height * hf * c.maxXYRatio / group.width;
}

inline double aligned_y(const Constraint& c, const Box& group, const Metrics& m)
{
	using namespace nerdfont;
	if (c.size == None && c.alignV == AlignNone)
		return group.y;
	const double startY = m.faceY + c.padBottom * m.faceHeight;
	const double endY = m.faceY + (m.faceHeight - group.height - c.padTop * m.faceHeight);
	const double centerY = (startY + endY) / 2;
	switch (c.alignV)
	{
	case Start:
		return startY;
	case End:
		return endY;
	case Center:
	case Center1:
		return centerY;
	default:
		return endY < startY ? centerY : std::max(startY, std::min(group.y, endY));
	}
}

inline double aligned_x(const Constraint& c, const Box& group, const Metrics& m, int width)
{
	using namespace nerdfont;
	if (c.size == None && c.alignH == AlignNone)
		return group.x;
	const double span = m.faceWidth + double(width - 1) * m.cellWidth;
	const double startX = c.padLeft * m.faceWidth;
	const double endX = span - group.width - c.padRight * m.faceWidth;
	switch (c.alignH)
	{
	case Start:
		return startX;
	case End:
		return std::max(startX, endX);
	case Center:
		return std::max(startX, (startX + endX) / 2);
	case Center1:
	{
		const double end1 = m.faceWidth - group.width - c.padRight * m.faceWidth;
		return std::max(startX, (startX + end1) / 2);
	}
	default:
		return std::max(startX, std::min(group.x, endX));
	}
}

inline Box constrain_inner(const Constraint& c, const Box& glyph, const Metrics& m, int width)
{
	// Extra-wide faces never stretch a glyph over two cells (as font_patcher).
	const int w = c.size == nerdfont::Stretch && m.faceWidth > 0.9 * m.faceHeight ? 1 : std::min<int>(c.maxWidth, width);
	// The box of the glyph's scale group: scaled and aligned, then the glyph follows it.
	Box group;
	group.width = glyph.width / c.relWidth;
	group.height = glyph.height / c.relHeight;
	group.x = glyph.x - group.width * c.relX;
	group.y = glyph.y - group.height * c.relY;
	double wf, hf;
	scale_factors(c, group, m, w, wf, hf);
	const double cx = group.x + group.width / 2, cy = group.y + group.height / 2;
	group.width *= wf;
	group.height *= hf;
	group.x = cx - group.width / 2;
	group.y = cy - group.height / 2;
	group.y = aligned_y(c, group, m);
	group.x = aligned_x(c, group, m, w);
	return Box{ wf * glyph.width, hf * glyph.height, group.x + group.width * c.relX, group.y + group.height * c.relY };
}

} // namespace detail

// The glyph's box after the constraint, given `width` cells of room (constraint_width).
inline Box constrain(const Constraint& c, const Box& glyph, const Metrics& m, int width)
{
	if (!does_anything(c))
		return glyph;
	if (c.size != nerdfont::Stretch)
		return detail::constrain_inner(c, glyph, m, width);
	// Stretched glyphs line up with the grid, not the face; no negative padding.
	Metrics grid = m;
	grid.faceWidth = m.cellWidth;
	grid.faceHeight = m.cellHeight;
	grid.faceY = 0;
	Constraint s = c;
	s.padBottom = std::max(0.0, s.padBottom);
	s.padTop = std::max(0.0, s.padTop);
	s.padLeft = std::max(0.0, s.padLeft);
	s.padRight = std::max(0.0, s.padRight);
	return detail::constrain_inner(s, glyph, grid, width);
}

} // namespace glyphfit
