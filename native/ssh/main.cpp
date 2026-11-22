// omaremote-ssh: one SSH session, a terminal drawn for a tab in the OMARemote window.
//
// ssh runs in a pseudo-terminal; libghostty-vt (Ghostty's terminal) keeps the screen, and this process draws it into the
// shared-memory framebuffer the UI maps, over the same Unix socket protocol omaremote-rdp and
// omaremote-vnc speak (native/common/link.hpp). The view, tabs, own windows and reattaching work
// the same for all three; the session outlives the window like any other.
//
// Settings arrive as key=value lines on stdin:
//   arg        the command to run, one line per argument (ssh and its arguments)
//   font       font family (default: monospace, which Omarchy points at its terminal font)
//   fontSize   in points at scale 100 (default 9)
//   theme      a foot.ini with the theme's terminal colours, followed when it changes
//   scrollback lines kept above the screen (default 10000)
//
// Terminal keys: ctrl+shift+c (or ctrl+insert) copies the selection, ctrl+shift+v (or shift+insert, or a middle
// click) pastes, shift+page up/down and the wheel scroll back. Remote programs that ask for the
// mouse (htop, vim with mouse=a) get it; shift+drag still selects. Ctrl+= / ctrl+- / ctrl+0 zoom the text.

#include "../common/link.hpp"

#include <QFont>
#include <QFontMetricsF>
#include <QGlyphRun>
#include <QGuiApplication>
#include <QImage>
#include <QPainter>
#include <QPainterPath>
#include <QTransform>
#include <QRawFont>
#include <QTextLayout>

#include "ghostty_keys.hpp"
#include "glyph_constraint.hpp"

#include <ghostty/vt.h>
#include <cstring>
#include <xkbcommon/xkbcommon.h>

#include <fcntl.h>
#include <poll.h>
#include <pty.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <iostream>
#include <map>
#include <set>
#include <string>
#include <unordered_map>
#include <vector>

using oma::b64;
using oma::log;
using oma::split;
using oma::unb64;

// ---------------------------------------------------------------- state

struct Palette
{
	QColor fg = QColor(0xa9, 0xb1, 0xd6);
	QColor bg = QColor(0x1a, 0x1b, 0x26);
	QColor selFg = QColor(0xc0, 0xca, 0xf5);
	QColor selBg = QColor(0x29, 0x2e, 0x42);
	QColor cursor = QColor(0xc0, 0xca, 0xf5);
	QColor cursorText = QColor(0x1a, 0x1b, 0x26);
	QColor ansi[16];
};

// A cell position in the whole screen, scrollback included (Ghostty's "screen" points): row 0 is
// the oldest line kept.
struct Pos
{
	long line = 0;
	int col = 0;
	bool operator<(const Pos& o) const { return line < o.line || (line == o.line && col < o.col); }
	bool operator==(const Pos& o) const { return line == o.line && col == o.col; }
};

// A symbol's glyph, from the terminal font or the fallback Qt picks, and how it is drawn in one or
// two cells of room (Ghostty's constraint rules, glyph_constraint.hpp), worked out once.
struct SymbolGlyph
{
	bool ok = false; // a glyph with a size to draw
	QRawFont font;
	quint32 index = 0;
	QRectF bounds; // from the pen position on the baseline, y down
	QPainterPath path;
	struct Placed
	{
		bool done = false, stretched = false; // stretched: drawn as an outline, scaled unevenly
		QRawFont font;                        // the glyph's font at its new size (evenly scaled)
		QPointF pen;                          // where to put the pen in the cell, from its top left
		QTransform outline;                   // stretched: the outline's place in the cell
	} placed[2];
};

struct Session
{
	std::multimap<std::string, std::string> cfg;
	oma::Link link;
	volatile sig_atomic_t quit = 0;

	// The program in the terminal.
	int pty = -1;
	pid_t child = -1;
	int exitStatus = 0;

	// libghostty-vt: the terminal, a copy of what to draw, the key and mouse encoders.
	GhosttyTerminal term = nullptr;
	GhosttyRenderState render = nullptr;
	GhosttyRenderStateRowIterator rowIt = nullptr;
	GhosttyRenderStateRowCells cells = nullptr;
	GhosttyKeyEncoder keys = nullptr;
	GhosttyKeyEvent keyEvent = nullptr;
	GhosttyMouseEncoder mouse = nullptr;
	GhosttyMouseEvent mouseEvent = nullptr;
	int rows = 24, cols = 80;

	// Drawing.
	oma::Framebuffer frame;
	QImage image; // wraps frame.data
	// A row is painted here first and copied into the frame finished: the UI reads the frame at
	// any moment, and a row it catches half painted (background cleared, text not yet drawn) blinks.
	QImage strip;
	int pixelW = 0, pixelH = 0, scale = 100;
	QFont font;
	QRawFont raw[4]; // regular, bold, italic, bold italic
	glyphfit::Metrics glyphMetrics; // what Ghostty's glyph constraints measure against
	int cellW = 8, cellH = 16, ascent = 12;
	std::vector<uint32_t> rowCps;                       // draw_row's, kept to reuse
	std::unordered_map<uint64_t, SymbolGlyph> symbols; // by codepoint and style; emptied with the font
	int zoom = 0;                   // points added to fontSize (ctrl+= / ctrl+- / ctrl+0), this tab only
	std::set<uint32_t> zoomKeys;    // their keys held: the release is ours too
	int pad = 6; // margin around the cells, in pixels
	// How opaque the terminal's own background is (the view's `opacity` line, Omarchy's see-through
	// terminals): 255 is solid. Only the default background takes it; a cell with a colour of its
	// own stays solid, as in Ghostty, and text is drawn solid on top.
	int bgAlpha = 255;
	Palette pal;
	std::string themePath;
	struct timespec themeTime = {};

	// The whole picture must be redrawn (a resize, a theme, the view scrolled); otherwise the
	// render state says which rows changed.
	bool full = true;
	int cursorRow = -1; // the row the cursor was drawn on, redrawn when it moves away
	long redrawFrom = 0, redrawTo = -1; // screen lines to redraw anyway (the selection changed there)
	bool output = false;                 // the terminal got output since the last flush

	bool altScreen = false;
	bool mouseTracking = false;
	std::string title;

	// Mouse selection, in screen positions; empty when anchor == head.
	bool selecting = false;
	Pos selAnchor, selHead;
	bool hasSelection = false;
	int mouseButtons = 0; // buttons held, for the remote program's mouse reporting

	std::set<uint32_t> held; // evdev codes held: the modifiers come from these
	std::string localClip;   // the UI's clipboard, offered on focus and when it changes
	bool retryNow = false;   // Enter or the view's Try now while a lost connection waits
	bool cancelReconnect = false; // the view's Cancel: the lost connection is given up
	bool typed = false;      // a key went to the remote since the last drop
	std::string said;        // the end of this try's terminal output: what its exit is judged by
	std::string reconnectLine; // the view's reconnect banner, sent again when a view attaches

	std::string get(const char* key, const char* fallback = "") const
	{
		auto it = cfg.find(key);
		return it == cfg.end() || it->second.empty() ? fallback : it->second;
	}
};

static Session g;
// The longest window title a server may set (OSC 0/2).
static constexpr size_t kMaxTitleBytes = 4096;

static void term_write(const char* s, size_t len);
// Draws what changed; announce: tell the UI (not for a buffer it does not have yet).
static void flush(bool announce = true);

// ---------------------------------------------------------------- theme

static QColor hex(const std::string& s)
{
	QColor c(QString::fromStdString("#" + s));
	return c.isValid() ? c : QColor();
}

static GhosttyColorRgb rgb(const QColor& q)
{
	return GhosttyColorRgb{ uint8_t(q.red()), uint8_t(q.green()), uint8_t(q.blue()) };
}

// foot's colour file, the same Omarchy writes for every theme: foreground, background,
// selection-*, cursor ("text cursor"), regular0-7 and bright0-7.
static void load_theme()
{
	static const char* tokyo[16] = { "1a1b26", "f7768e", "9ece6a", "e0af68", "7aa2f7", "ad8ee6", "449dab", "a9b1d6",
		                             "414868", "ff7a93", "b9f27c", "ff9e64", "7da6ff", "bb9af7", "0db9d7", "c0caf5" };
	Palette p;
	for (int i = 0; i < 16; i++)
		p.ansi[i] = hex(tokyo[i]);
	std::ifstream in(g.themePath);
	std::string line;
	while (std::getline(in, line))
	{
		const size_t eq = line.find('=');
		if (eq == std::string::npos || line[0] == '#' || line[0] == '[')
			continue;
		std::string key = line.substr(0, eq), value = line.substr(eq + 1);
		while (!key.empty() && key.back() == ' ')
			key.pop_back();
		while (!value.empty() && value.front() == ' ')
			value.erase(0, 1);
		const auto words = split(value);
		QColor c = words.empty() ? QColor() : hex(words[0]);
		if (key == "cursor" && words.size() >= 2)
		{
			if (c.isValid())
				p.cursorText = c;
			if (QColor c2 = hex(words[1]); c2.isValid())
				p.cursor = c2;
			continue;
		}
		if (!c.isValid())
			continue;
		if (key == "foreground")
			p.fg = c;
		else if (key == "background")
			p.bg = c;
		else if (key == "selection-foreground")
			p.selFg = c;
		else if (key == "selection-background")
			p.selBg = c;
		else if (key.rfind("regular", 0) == 0 && key.size() == 8 && key[7] >= '0' && key[7] <= '7')
			p.ansi[key[7] - '0'] = c;
		else if (key.rfind("bright", 0) == 0 && key.size() == 7 && key[6] >= '0' && key[6] <= '7')
			p.ansi[8 + key[6] - '0'] = c;
	}
	g.pal = p;
	if (!g.term)
		return;
	// The theme's colours are the terminal's defaults: a program can still change them (OSC 4/10/11).
	const GhosttyColorRgb fg = rgb(p.fg), bg = rgb(p.bg), cursor = rgb(p.cursor);
	ghostty_terminal_set(g.term, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg);
	ghostty_terminal_set(g.term, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg);
	ghostty_terminal_set(g.term, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor);
	GhosttyColorRgb palette[256];
	if (ghostty_terminal_get(g.term, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, &palette) != GHOSTTY_SUCCESS)
		memset(palette, 0, sizeof(palette));
	for (int i = 0; i < 16; i++)
		palette[i] = rgb(p.ansi[i]);
	ghostty_terminal_set(g.term, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &palette);
}

// A theme switch rewrites the file: follow it.
static void check_theme()
{
	struct stat st = {};
	if (g.themePath.empty() || stat(g.themePath.c_str(), &st) != 0)
		return;
	if (st.st_mtim.tv_sec == g.themeTime.tv_sec && st.st_mtim.tv_nsec == g.themeTime.tv_nsec)
		return;
	const bool first = g.themeTime.tv_sec == 0 && g.themeTime.tv_nsec == 0;
	g.themeTime = st.st_mtim;
	if (first)
		return;
	load_theme();
	g.full = true;
}

// ---------------------------------------------------------------- font and size

static void setup_font()
{
	const double points = std::clamp(strtod(g.get("fontSize", "9").c_str(), nullptr) + g.zoom, 4.0, 48.0);
	// Points at 96 dpi, times the screen's scale: what a terminal shows on the same screen.
	const int px = std::max(6, int(std::lround(points * 96.0 / 72.0 * g.scale / 100.0)));
	g.font = QFont(QString::fromStdString(g.get("font", "monospace")));
	g.font.setStyleHint(QFont::Monospace);
	g.font.setPixelSize(px);
	g.font.setKerning(false);
	g.font.setHintingPreference(QFont::PreferFullHinting);
	for (int i = 0; i < 4; i++)
	{
		QFont f = g.font;
		f.setBold(i & 1);
		f.setItalic(i & 2);
		g.raw[i] = QRawFont::fromFont(f);
	}
	const QFontMetricsF m(g.font);
	g.cellW = std::max(1, int(std::lround(m.horizontalAdvance(QLatin1Char('M')))));
	g.cellH = std::max(1, int(std::ceil(m.height())));
	g.ascent = int(std::ceil(m.ascent()));
	g.pad = int(std::lround(6.0 * g.scale / 100.0));
	// Ghostty's grid metrics (src/font/Metrics.zig) from Qt's: the face's own width and height,
	// where its bottom sits in the cell, and the icon heights the Nerd Font rules use.
	glyphfit::Metrics& gm = g.glyphMetrics;
	gm.cellWidth = g.cellW;
	gm.cellHeight = g.cellH;
	gm.faceWidth = m.horizontalAdvance(QLatin1Char('M'));
	gm.faceHeight = m.height();
	gm.faceY = (g.cellH - g.ascent) - m.descent();
	const double cap = m.capHeight() > 0 ? m.capHeight() : 0.75 * m.ascent();
	gm.iconHeight = gm.faceHeight;
	gm.iconHeightSingle = (2 * cap + gm.faceHeight) / 3;
	g.symbols.clear();
}

static void set_pty_size()
{
	if (g.pty < 0)
		return;
	winsize ws = {};
	ws.ws_row = uint16_t(g.rows);
	ws.ws_col = uint16_t(g.cols);
	ws.ws_xpixel = uint16_t(g.cols * g.cellW);
	ws.ws_ypixel = uint16_t(g.rows * g.cellH);
	ioctl(g.pty, TIOCSWINSZ, &ws);
}

// The mouse encoder turns the view's pixels into cells: it needs the picture's geometry.
static void set_mouse_size()
{
	GhosttyMouseEncoderSize s = GHOSTTY_INIT_SIZED(GhosttyMouseEncoderSize);
	s.screen_width = uint32_t(g.pixelW);
	s.screen_height = uint32_t(g.pixelH);
	s.cell_width = uint32_t(g.cellW);
	s.cell_height = uint32_t(g.cellH);
	s.padding_top = s.padding_left = uint32_t(g.pad);
	s.padding_right = uint32_t(std::max(0, g.pixelW - g.pad - g.cols * g.cellW));
	s.padding_bottom = uint32_t(std::max(0, g.pixelH - g.pad - g.rows * g.cellH));
	ghostty_mouse_encoder_set(g.mouse, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &s);
}

// The view's size in pixels, and the screen scale: a new framebuffer that size, as many cells as
// fit. The terminal (which reflows) and the program in it follow.
static void resize(int w, int h, int scale, bool fontChanged = false)
{
	w = std::clamp(w, 64, 16384);
	h = std::clamp(h, 32, 16384);
	scale = std::clamp(scale, 50, 500);
	if (w == g.pixelW && h == g.pixelH && scale == g.scale && g.frame.data && !fontChanged)
		return;
	fontChanged = fontChanged || scale != g.scale || !g.frame.data;
	g.scale = scale;
	if (fontChanged)
		setup_font();
	// The same size (a zoom): the picture is redrawn in place, row by row, never shown empty.
	const bool sameSize = g.frame.data && w == g.pixelW && h == g.pixelH;
	oma::Framebuffer old = {};
	if (!sameSize)
	{
		oma::Framebuffer fb = oma::fb_alloc(uint32_t(w), uint32_t(h));
		if (!fb.data)
			return;
		old = g.frame;
		g.frame = fb;
		// Premultiplied: B G R A in memory. With the background solid every A is 255, the same bytes
		// as RGB32; the view reads it this way only for SSH (RdpView.alphaFrames).
		g.image = QImage(fb.data, w, h, int(fb.stride), QImage::Format_ARGB32_Premultiplied);
		g.pixelW = w;
		g.pixelH = h;
	}
	const int cols = std::clamp((w - 2 * g.pad) / g.cellW, 2, 4096), rows = std::clamp((h - 2 * g.pad) / g.cellH, 1, 4096);
	if (cols != g.cols || rows != g.rows || fontChanged)
	{
		g.cols = cols;
		g.rows = rows;
		ghostty_terminal_resize(g.term, uint16_t(cols), uint16_t(rows), uint32_t(g.cellW), uint32_t(g.cellH));
		set_pty_size();
	}
	set_mouse_size();
	g.full = true;
	if (sameSize)
		return; // the next flush redraws it and says so
	// A new buffer goes to the UI painted: an empty one would show for a moment (the wallpaper
	// through it).
	flush(false);
	g.full = true; // the program redraws for its new size: the next flush paints that whole
	g.link.sendFrame(g.frame);
	if (old.data)
		oma::fb_release(old.data);
}

// ---------------------------------------------------------------- what the terminal says

static GhosttyTerminalScrollbar scrollbar()
{
	GhosttyTerminalScrollbar s = {};
	ghostty_terminal_get(g.term, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &s);
	return s;
}

// Whether the view is scrolled back into the history.
static bool scrolled_back()
{
	bool active = true;
	ghostty_terminal_get(g.term, GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, &active);
	return !active;
}

static void send_cursor_shape()
{
	// A text cursor over the terminal, the arrow while a program takes the mouse.
	g.link.send(g.mouseTracking ? "cursor-default" : "cursor-text");
}

// After the terminal took input: the modes the rest of this file follows.
static void after_write()
{
	bool tracking = false;
	ghostty_terminal_get(g.term, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking);
	if (tracking != g.mouseTracking)
	{
		g.mouseTracking = tracking;
		send_cursor_shape();
	}
	GhosttyTerminalScreen screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY;
	ghostty_terminal_get(g.term, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
	const bool alt = screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
	if (alt != g.altScreen)
	{
		g.altScreen = alt;
		g.full = true;
	}
}

static bool mode(uint16_t number)
{
	GhosttyTerminalModeConfig m = {};
	m.mode = ghostty_mode_new(number, false);
	return ghostty_terminal_get(g.term, GHOSTTY_TERMINAL_DATA_MODE, &m) == GHOSTTY_SUCCESS && m.value;
}

// ---------------------------------------------------------------- drawing

static QColor qcolor(GhosttyColorRgb c)
{
	return QColor(c.r, c.g, c.b);
}

// The default background at the view's alpha. It is painted with CompositionMode_Source, so it
// replaces what was there instead of blending over the previous picture.
static QColor background(GhosttyColorRgb c)
{
	return QColor(c.r, c.g, c.b, g.bgAlpha);
}

// One row of the render state, the row iterator on it.
// One cell of a row, as the passes below need it.
struct DrawCell
{
	QRect box;
	QColor fg, bg;
	QString text; // empty: nothing to draw (blank, a space, invisible)
	uint32_t first = 0; // its first codepoint, 0 for an empty cell (also when not drawn)
	int col = 0, span = 1;
	bool bold = false, italic = false, atCursor = false;
	GhosttyStyle style;
};

// The glyph for cp in this style: the terminal font's, else the one Qt falls back to.
static SymbolGlyph& symbol_glyph(uint32_t cp, int variant, const QString& text)
{
	// Every codepoint a remote program prints could add one: bounded.
	if (g.symbols.size() > 4096)
		g.symbols.clear();
	SymbolGlyph& s = g.symbols[uint64_t(cp) | uint64_t(variant) << 32];
	if (s.ok || s.index)
		return s;
	s.index = 1; // looked up (ok tells whether there is something to draw)
	QRawFont font = g.raw[variant];
	QList<quint32> glyphs = font.glyphIndexesForString(text);
	if (glyphs.size() != 1 || glyphs[0] == 0)
	{
		QFont f = g.font;
		f.setBold(variant & 1);
		f.setItalic(variant & 2);
		QTextLayout layout(text, f);
		layout.beginLayout();
		layout.createLine();
		layout.endLayout();
		const QList<QGlyphRun> runs = layout.glyphRuns();
		if (runs.size() != 1 || runs[0].glyphIndexes().size() != 1)
			return s;
		font = runs[0].rawFont();
		glyphs = runs[0].glyphIndexes();
	}
	s.font = font;
	s.index = glyphs[0];
	s.bounds = font.boundingRect(glyphs[0]);
	s.ok = s.index != 0 && s.bounds.width() >= 0.25 && s.bounds.height() >= 0.25;
	return s;
}

// A symbol drawn as Ghostty draws it: its constraint (a Nerd Font rule, else fit for any symbol)
// with `width` cells of room. False when there is no rule for it or no glyph: drawn as text then.
static bool draw_symbol(QPainter& painter, const DrawCell& c, int width)
{
	const glyphfit::Constraint rule = glyphfit::constraint_for(c.first);
	if (!glyphfit::does_anything(rule))
		return false;
	SymbolGlyph& s = symbol_glyph(c.first, (c.bold ? 1 : 0) | (c.italic ? 2 : 0), c.text);
	if (!s.ok)
		return false;
	SymbolGlyph::Placed& p = s.placed[width > 1 ? 1 : 0];
	if (!p.done)
	{
		p.done = true;
		const QRectF& b = s.bounds;
		const double baseline = g.cellH - g.ascent; // above the cell's bottom
		const glyphfit::Box in{ b.width(), b.height(), b.x(), baseline - (b.y() + b.height()) };
		glyphfit::Box r = glyphfit::constrain(rule, in, g.glyphMetrics, width);
		// As Ghostty: a face narrower than the pixel cell is centred in it (not when stretched).
		if (rule.size != nerdfont::Stretch && g.glyphMetrics.faceWidth < g.cellW)
			r.x += std::round((g.cellW - g.glyphMetrics.faceWidth) / 2);
		const double sx = r.width / b.width(), sy = r.height / b.height();
		const double left = r.x, top = g.cellH - (r.y + r.height);
		if (std::fabs(sx - sy) <= 1e-3 * std::max(sx, sy))
		{
			// Evenly: the font at that size (hinting and colour glyphs kept).
			p.font = s.font;
			if (std::fabs(sx - 1) > 1e-3)
				p.font.setPixelSize(s.font.pixelSize() * sx);
			p.pen = QPointF(left - b.x() * sx, top - b.y() * sx);
		}
		else
		{
			p.stretched = true;
			if (s.path.isEmpty())
				s.path = s.font.pathForGlyph(s.index);
			p.outline = QTransform::fromTranslate(-b.x(), -b.y()) * QTransform::fromScale(sx, sy) *
			            QTransform::fromTranslate(left, top);
		}
	}
	if (p.stretched)
	{
		painter.save();
		painter.setRenderHint(QPainter::Antialiasing);
		painter.translate(c.box.topLeft());
		painter.setTransform(p.outline, true);
		painter.fillPath(s.path, c.fg);
		painter.restore();
		return true;
	}
	QGlyphRun run;
	run.setRawFont(p.font);
	run.setGlyphIndexes({ s.index });
	run.setPositions({ QPointF(c.box.x(), c.box.y()) + p.pen });
	painter.setPen(c.fg);
	painter.drawGlyphRun(QPointF(0, 0), run);
	return true;
}

// Painted into g.strip from x = 0, y = 0. Backgrounds first, then the text, then lines and the
// cursor: a glyph wider than its cell (an icon, an italic's overhang) is never painted over by
// the next cell's background.
static void draw_row(QPainter& painter, int row, const GhosttyRenderStateColors& colors,
                     const GhosttyRenderStateCursor& cursor)
{
	if (ghostty_render_state_row_get(g.rowIt, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &g.cells) != GHOSTTY_SUCCESS)
		return;
	const int y = 0;
	painter.setCompositionMode(QPainter::CompositionMode_Source);
	painter.fillRect(QRect(0, y, g.cols * g.cellW, g.cellH), background(colors.background));
	painter.setCompositionMode(QPainter::CompositionMode_SourceOver);
	const bool cursorHere = cursor.visible && cursor.viewport_has_value && cursor.viewport_y == row && !scrolled_back();
	const QColor cursorColour = colors.cursor_has_value ? qcolor(colors.cursor) : g.pal.cursor;
	uint32_t cps[32];
	std::vector<DrawCell> cells;
	cells.reserve(size_t(g.cols));
	for (int col = 0; ghostty_render_state_row_cells_next(g.cells) && col < g.cols; col++)
	{
		GhosttyCell raw = 0;
		ghostty_render_state_row_cells_get(g.cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw);
		GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
		ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide);
		// The right half of a wide character is drawn with its left half.
		if (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL)
			continue;
		const int span = wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : 1;
		DrawCell c;
		ghostty_style_default(&c.style);
		ghostty_render_state_row_cells_get(g.cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &c.style);
		GhosttyColorRgb rgb;
		c.fg = ghostty_render_state_row_cells_get(g.cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &rgb) ==
		               GHOSTTY_SUCCESS
		           ? qcolor(rgb)
		           : qcolor(colors.foreground);
		c.bg = ghostty_render_state_row_cells_get(g.cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &rgb) ==
		               GHOSTTY_SUCCESS
		           ? qcolor(rgb)
		           : qcolor(colors.background);
		if (c.style.flags & GHOSTTY_STYLE_FLAG_INVERSE)
			std::swap(c.fg, c.bg);
		if (c.style.flags & GHOSTTY_STYLE_FLAG_FAINT)
			c.fg = QColor((c.fg.red() + c.bg.red()) / 2, (c.fg.green() + c.bg.green()) / 2, (c.fg.blue() + c.bg.blue()) / 2);
		bool selected = false;
		ghostty_render_state_row_cells_get(g.cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED, &selected);
		if (selected)
		{
			c.fg = g.pal.selFg;
			c.bg = g.pal.selBg;
		}
		c.atCursor = cursorHere && cursor.viewport_x == col;
		if (c.atCursor && cursor.visual_style == GHOSTTY_CURSOR_STYLE_BLOCK)
		{
			c.fg = g.pal.cursorText;
			c.bg = cursorColour;
		}
		c.box = QRect(col * g.cellW, y, span * g.cellW, g.cellH);
		GhosttyCodepointBuffer graphemes = { cps, 32, 0 };
		ghostty_render_state_row_cells_get(g.cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &graphemes);
		const size_t n = std::min<size_t>(graphemes.len, 32);
		c.first = n ? cps[0] : 0;
		c.col = col;
		c.span = span;
		if (n && !(n == 1 && cps[0] == ' ') && !(c.style.flags & GHOSTTY_STYLE_FLAG_INVISIBLE))
			c.text = QString::fromUcs4(reinterpret_cast<const char32_t*>(cps), qsizetype(n));
		c.bold = c.style.flags & GHOSTTY_STYLE_FLAG_BOLD;
		c.italic = c.style.flags & GHOSTTY_STYLE_FLAG_ITALIC;
		cells.push_back(std::move(c));
	}

	for (const DrawCell& c : cells)
		if (c.bg != qcolor(colors.background))
			painter.fillRect(c.box, c.bg);

	// Each column's first codepoint (0: empty, or the right half of a wide character): how much
	// room a symbol has.
	g.rowCps.assign(size_t(g.cols), 0);
	for (const DrawCell& c : cells)
		g.rowCps[size_t(c.col)] = c.first;

	for (size_t i = 0; i < cells.size(); i++)
	{
		const DrawCell& c = cells[i];
		if (c.text.isEmpty())
			continue;
		const QRawFont& rawFont = g.raw[(c.bold ? 1 : 0) | (c.italic ? 2 : 0)];
		painter.setPen(c.fg);
		// One codepoint (with a variation selector at most): a symbol may be sized by its rule.
		const qsizetype units = QChar::requiresSurrogates(c.first) ? 2 : 1;
		if ((c.text.size() == units || (c.text.size() == units + 1 && c.text.back().unicode() == 0xFE0F)) &&
		    draw_symbol(painter, c, glyphfit::constraint_width(g.rowCps.data(), c.col, g.cols, c.span)))
			continue;
		const QList<quint32> glyphs = rawFont.glyphIndexesForString(c.text);
		if (!glyphs.isEmpty() && glyphs[0] != 0 && glyphs.size() == 1)
		{
			QGlyphRun run;
			run.setRawFont(rawFont);
			run.setGlyphIndexes(glyphs);
			run.setPositions({ QPointF(c.box.x(), y + g.ascent) });
			painter.drawGlyphRun(QPointF(0, 0), run);
		}
		else
		{
			// Grapheme clusters (combining marks, emoji sequences) and glyphs the font lacks:
			// Qt shapes them and picks a fallback font.
			QFont f = g.font;
			f.setBold(c.bold);
			f.setItalic(c.italic);
			painter.setFont(f);
			painter.drawText(QPointF(c.box.x(), y + g.ascent), c.text);
		}
	}

	const int thick = std::max(1, g.cellH / 14);
	for (const DrawCell& c : cells)
	{
		const QRect& box = c.box;
		if (GHOSTTY_STYLE_UNDERLINE(c.style))
			painter.fillRect(QRect(box.x(), y + g.ascent + thick, box.width(), thick), c.fg);
		if (c.style.flags & GHOSTTY_STYLE_FLAG_STRIKETHROUGH)
			painter.fillRect(QRect(box.x(), y + g.cellH / 2, box.width(), thick), c.fg);
		if (c.style.flags & GHOSTTY_STYLE_FLAG_OVERLINE)
			painter.fillRect(QRect(box.x(), y, box.width(), thick), c.fg);
		if (!c.atCursor)
			continue;
		if (cursor.visual_style == GHOSTTY_CURSOR_STYLE_UNDERLINE)
			painter.fillRect(QRect(box.x(), y + g.cellH - 2 * thick, box.width(), 2 * thick), cursorColour);
		if (cursor.visual_style == GHOSTTY_CURSOR_STYLE_BAR)
			painter.fillRect(QRect(box.x(), y, 2 * thick, g.cellH), cursorColour);
		if (cursor.visual_style == GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW)
		{
			painter.setPen(cursorColour);
			painter.drawRect(box.adjusted(0, 0, -1, -1));
		}
	}
}

// Draws what changed and tells the UI where: the rows the render state marks, and the rows the
// cursor left and moved to.
static void flush(bool announce)
{
	if (g.image.isNull() || !g.term)
		return;
	if (ghostty_render_state_update(g.render, g.term) != GHOSTTY_SUCCESS)
		return;
	GhosttyRenderStateDirty dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
	ghostty_render_state_get(g.render, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty);
	GhosttyRenderStateCursor cursor = GHOSTTY_INIT_SIZED(GhosttyRenderStateCursor);
	ghostty_render_state_get(g.render, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor);
	const int cursorRow = cursor.visible && cursor.viewport_has_value ? int(cursor.viewport_y) : -1;
	if (dirty == GHOSTTY_RENDER_STATE_DIRTY_FALSE && !g.full && cursorRow == g.cursorRow)
		return;
	GhosttyRenderStateColors colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
	ghostty_render_state_get(g.render, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors);
	if (ghostty_render_state_get(g.render, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &g.rowIt) != GHOSTTY_SUCCESS)
		return;
	// A selection change makes the library report the whole screen dirty; when nothing else
	// happened, only the lines the selection changed on need drawing.
	const bool onlySelection = !g.full && !g.output && g.redrawFrom <= g.redrawTo;
	const bool all = g.full || (dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL && !onlySelection);
	const int stripW = g.cols * g.cellW;
	if (g.strip.width() != stripW || g.strip.height() != g.cellH)
		g.strip = QImage(std::max(1, stripW), std::max(1, g.cellH), g.image.format());
	if (all)
	{
		// Only the padding: the rows paint their own background.
		QPainter frame(&g.image);
		frame.setCompositionMode(QPainter::CompositionMode_Source);
		const QColor bg = background(colors.background);
		const int gridH = g.rows * g.cellH;
		frame.fillRect(0, 0, g.pixelW, g.pad, bg);
		frame.fillRect(0, g.pad + gridH, g.pixelW, g.pixelH - g.pad - gridH, bg);
		frame.fillRect(0, g.pad, g.pad, gridH, bg);
		frame.fillRect(g.pad + stripW, g.pad, g.pixelW - g.pad - stripW, gridH, bg);
	}
	const long top = long(scrollbar().offset);
	QPainter painter(&g.strip);
	painter.setRenderHint(QPainter::TextAntialiasing);
	std::vector<std::pair<int, int>> runs; // redrawn rows, [first, last + 1)
	for (int row = 0; ghostty_render_state_row_iterator_next(g.rowIt) && row < g.rows; row++)
	{
		bool rowDirty = false;
		ghostty_render_state_row_get(g.rowIt, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &rowDirty);
		const bool selChanged = top + row >= g.redrawFrom && top + row <= g.redrawTo;
		if (onlySelection)
			rowDirty = false;
		if (!all && !rowDirty && !selChanged && row != cursorRow && row != g.cursorRow)
			continue;
		draw_row(painter, row, colors, cursor);
		const int y = g.pad + row * g.cellH;
		const size_t bytes = size_t(stripW) * 4;
		for (int line = 0; line < g.cellH && y + line < g.image.height(); line++)
			memcpy(g.image.scanLine(y + line) + size_t(g.pad) * 4, g.strip.constScanLine(line), bytes);
		if (!runs.empty() && runs.back().second == row)
			runs.back().second = row + 1;
		else
			runs.emplace_back(row, row + 1);
	}
	painter.end();
	g.redrawFrom = 0;
	g.redrawTo = -1;
	g.output = false;
	ghostty_render_state_clean(g.render);
	g.cursorRow = cursorRow;
	if (!announce)
		;
	else if (all)
		g.link.send("damage 0 0 " + std::to_string(g.pixelW) + " " + std::to_string(g.pixelH));
	else
		for (const auto& [r0, r1] : runs)
			g.link.send("damage " + std::to_string(g.pad) + " " + std::to_string(g.pad + r0 * g.cellH) + " " +
			            std::to_string(stripW) + " " + std::to_string((r1 - r0) * g.cellH));
	g.full = false;
}

static void scroll_view(int lines)
{
	// Positive: back into the history (up).
	GhosttyTerminalScrollViewport s = {};
	s.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA;
	s.value.delta = -intptr_t(lines);
	ghostty_terminal_scroll_viewport(g.term, s);
	g.full = true;
}

static void scroll_to_bottom()
{
	if (!scrolled_back())
		return;
	GhosttyTerminalScrollViewport s = {};
	s.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM;
	ghostty_terminal_scroll_viewport(g.term, s);
	g.full = true;
}

// ---------------------------------------------------------------- libghostty-vt callbacks

// How long the pty may take no byte at all before what we write to it is dropped: a remote program
// that stops reading its input (a server flooding queries it never reads the answers to) must not
// hang the session. A slow one that still reads keeps everything: the time counts without progress.
static constexpr uint64_t kPtyStallMs = 5000;
static uint64_t g_ptyStalledSince = 0; // when the pty last refused a write, 0 while it takes them

// Terminal answers, keys and pastes to the program. Never waits past a stop, or longer than
// kPtyStallMs without progress; once stalled, later writes are dropped at once until one goes in.
static void cb_write_pty(GhosttyTerminal, void*, const uint8_t* data, size_t len)
{
	const char* s = reinterpret_cast<const char*>(data);
	while (len > 0 && g.pty >= 0 && !g.quit)
	{
		const ssize_t n = write(g.pty, s, len);
		if (n < 0)
		{
			if (errno == EINTR)
				continue;
			if (errno == EAGAIN)
			{
				const uint64_t now = oma::now_ms();
				if (!g_ptyStalledSince)
					g_ptyStalledSince = now;
				if (now - g_ptyStalledSince >= kPtyStallMs)
				{
					static uint64_t loggedAt = 0;
					if (now - loggedAt >= 60000)
					{
						loggedAt = now;
						log("the remote program reads no input: what is written to it is dropped");
					}
					return;
				}
				pollfd p = { g.pty, POLLOUT, 0 };
				poll(&p, 1, 100);
				continue;
			}
			return;
		}
		g_ptyStalledSince = 0;
		s += n;
		len -= size_t(n);
	}
}

static void to_pty(const std::string& s)
{
	cb_write_pty(g.term, nullptr, reinterpret_cast<const uint8_t*>(s.data()), s.size());
}

static void cb_title(GhosttyTerminal, void*)
{
	GhosttyString t = {};
	if (ghostty_terminal_get(g.term, GHOSTTY_TERMINAL_DATA_TITLE, &t) != GHOSTTY_SUCCESS)
		return;
	g.title.assign(reinterpret_cast<const char*>(t.ptr), std::min(t.len, kMaxTitleBytes));
	g.link.send("title " + b64(g.title));
}

// OSC 52 (and its newer cousins) from the remote program (tmux, Neovim): it sets our clipboard,
// unless the connection's Clipboard switch is off (copying a selection still works). Reading the
// clipboard is not offered: no CLIPBOARD_READ callback, so those requests are refused.
static void cb_clipboard_write(GhosttyTerminal, void*, const GhosttyClipboardWrite* w)
{
	GhosttyClipboardWriteReply reply = GHOSTTY_INIT_SIZED(GhosttyClipboardWriteReply);
	reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED;
	if (g.get("clipboard", "1") != "0" && w->location == GHOSTTY_CLIPBOARD_LOCATION_STANDARD)
	{
		for (size_t i = 0; i < w->contents_len; i++)
		{
			const GhosttyClipboardContent& c = w->contents[i];
			const std::string mime(reinterpret_cast<const char*>(c.mime.ptr), c.mime.len);
			if (mime != "text/plain" && mime.rfind("text/plain;", 0) != 0)
				continue;
			if (c.data.len > oma::kMaxClipBytes)
			{
				oma::log("clipboard: the remote program's text is larger than %zu bytes; not passed on",
				         oma::kMaxClipBytes);
				reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA;
				break;
			}
			if (c.data.len)
			{
				g.localClip.assign(reinterpret_cast<const char*>(c.data.ptr), c.data.len);
				g.link.send("clip " + b64(g.localClip));
			}
			reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS;
			break;
		}
	}
	w->reply(w, &reply);
}

// ---------------------------------------------------------------- selection and clipboard

// The terminal keeps the selection (it follows the text as the screen scrolls), from our anchor
// and head: positions between cells, so the end is the cell before the head.
static bool apply_selection()
{
	if (!g.hasSelection)
	{
		ghostty_terminal_set(g.term, GHOSTTY_TERMINAL_OPT_SELECTION, nullptr);
		return false;
	}
	Pos a = g.selAnchor, b = g.selHead;
	if (b < a)
		std::swap(a, b);
	if (b.col > 0)
		b.col--;
	else if (b.line > a.line)
	{
		b.line--;
		b.col = g.cols - 1;
	}
	GhosttyPoint pa = {}, pb = {};
	pa.tag = pb.tag = GHOSTTY_POINT_TAG_SCREEN;
	pa.value.coordinate = { uint16_t(a.col), uint32_t(std::max(0L, a.line)) };
	pb.value.coordinate = { uint16_t(b.col), uint32_t(std::max(0L, b.line)) };
	GhosttySelection sel = {};
	if (ghostty_terminal_grid_ref(g.term, pa, &sel.start) != GHOSTTY_SUCCESS ||
	    ghostty_terminal_grid_ref(g.term, pb, &sel.end) != GHOSTTY_SUCCESS)
		return false;
	ghostty_terminal_set(g.term, GHOSTTY_TERMINAL_OPT_SELECTION, &sel);
	return true;
}

static std::string selection_text()
{
	if (!g.hasSelection)
		return {};
	GhosttySelection sel = {};
	if (ghostty_terminal_get(g.term, GHOSTTY_TERMINAL_DATA_SELECTION, &sel) != GHOSTTY_SUCCESS)
		return {};
	GhosttyFormatter f = nullptr;
	if (ghostty_formatter_terminal_new(nullptr, &f, g.term) != GHOSTTY_SUCCESS)
		return {};
	const GhosttyFormatterFormat plain = GHOSTTY_FORMATTER_FORMAT_PLAIN;
	const bool yes = true;
	ghostty_formatter_set(f, GHOSTTY_FORMATTER_OPT_EMIT, &plain);
	ghostty_formatter_set(f, GHOSTTY_FORMATTER_OPT_TRIM, &yes);
	ghostty_formatter_set(f, GHOSTTY_FORMATTER_OPT_UNWRAP, &yes);
	ghostty_formatter_set(f, GHOSTTY_FORMATTER_OPT_SELECTION, &sel);
	uint8_t* out = nullptr;
	size_t len = 0;
	std::string text;
	if (ghostty_formatter_format_alloc(f, nullptr, &out, &len) == GHOSTTY_SUCCESS && out)
	{
		text.assign(reinterpret_cast<const char*>(out), std::min(len, oma::kMaxClipBytes));
		ghostty_free(nullptr, out, len);
	}
	ghostty_formatter_free(f);
	return text;
}

static void copy_selection()
{
	const std::string text = selection_text();
	if (text.empty())
		return;
	g.localClip = text;
	g.link.send("clip " + b64(text));
}

// Pasted text goes to the program as typed, bracketed when it asks for that (shells and editors
// then do not run or indent it line by line). Ghostty's encoder also takes out what could end
// the bracket early.
static void paste()
{
	if (g.localClip.empty() || g.pty < 0)
		return;
	std::string text = g.localClip;
	scroll_to_bottom();
	const bool bracketed = mode(2004);
	size_t need = 0;
	ghostty_paste_encode(text.data(), text.size(), bracketed, nullptr, 0, &need);
	std::string out(need, '\0');
	size_t written = 0;
	if (ghostty_paste_encode(text.data(), text.size(), bracketed, reinterpret_cast<uint8_t*>(out.data()), out.size(),
	                         &written) == GHOSTTY_SUCCESS)
		to_pty(out.substr(0, written));
}

// Marks the screen lines from a to b (either order) for the next flush.
static void redraw_lines(const Pos& a, const Pos& b)
{
	const long from = std::min(a.line, b.line), to = std::max(a.line, b.line);
	if (g.redrawFrom > g.redrawTo)
		g.redrawFrom = from, g.redrawTo = to;
	else
		g.redrawFrom = std::min(g.redrawFrom, from), g.redrawTo = std::max(g.redrawTo, to);
}

static void clear_selection()
{
	if (!g.hasSelection)
		return;
	g.hasSelection = false;
	redraw_lines(g.selAnchor, g.selHead);
	apply_selection();
}

// ---------------------------------------------------------------- input

// evdev codes of the modifier keys.
static bool held(std::initializer_list<uint32_t> codes)
{
	for (uint32_t c : codes)
		if (g.held.count(c))
			return true;
	return false;
}
static bool shift_held() { return held({ 42, 54 }); }
static bool ctrl_held() { return held({ 29, 97 }); }
static bool alt_held() { return held({ 56 }); } // right alt is AltGr: it types characters

static GhosttyMods mods()
{
	GhosttyMods m = 0;
	if (shift_held())
		m |= GHOSTTY_MODS_SHIFT;
	if (ctrl_held())
		m |= GHOSTTY_MODS_CTRL;
	if (alt_held())
		m |= GHOSTTY_MODS_ALT;
	return m;
}

static GhosttyKey key_of(uint32_t evdev)
{
	for (const auto& k : kEvdevKeys)
		if (k.evdev == evdev)
			return k.key;
	return GHOSTTY_KEY_UNIDENTIFIED;
}

static bool is_modifier(uint32_t sym)
{
	return (sym >= XKB_KEY_Shift_L && sym <= XKB_KEY_Hyper_R) || sym == XKB_KEY_ISO_Level3_Shift ||
	       sym == XKB_KEY_ISO_Level5_Shift || sym == XKB_KEY_Mode_switch || sym == XKB_KEY_Num_Lock;
}

// One key through Ghostty's encoder, which follows the modes the program set: cursor and keypad
// application keys, modifyOtherKeys, the Kitty keyboard protocol.
static void encode_key(GhosttyKeyAction action, uint32_t evdev, uint32_t sym, const std::string& text)
{
	const GhosttyKey key = key_of(evdev);
	if (key == GHOSTTY_KEY_UNIDENTIFIED && text.empty())
		return;
	// The layout's text, without control characters (ctrl+c comes as the key and its modifiers).
	std::string utf8;
	for (char32_t c : QString::fromStdString(text).toUcs4())
		if (c >= 0x20 && c != 0x7f)
			utf8 += QString::fromUcs4(&c, 1).toStdString();
	if (utf8.empty() && action != GHOSTTY_KEY_ACTION_RELEASE)
		if (const uint32_t c = xkb_keysym_to_utf32(sym); c >= 0x20 && c != 0x7f)
		{
			const char32_t cc = c;
			utf8 = QString::fromUcs4(&cc, 1).toStdString();
		}
	const GhosttyMods m = mods();
	ghostty_key_event_set_action(g.keyEvent, action);
	ghostty_key_event_set_key(g.keyEvent, key);
	ghostty_key_event_set_mods(g.keyEvent, m);
	// Shift that made the character (a capital, a symbol) is part of it, not a modifier on top.
	ghostty_key_event_set_consumed_mods(g.keyEvent, (m & GHOSTTY_MODS_SHIFT) && !utf8.empty() ? GHOSTTY_MODS_SHIFT : 0);
	ghostty_key_event_set_utf8(g.keyEvent, GhosttyString{ reinterpret_cast<const uint8_t*>(utf8.data()), utf8.size() });
	ghostty_key_event_set_unshifted_codepoint(g.keyEvent, xkb_keysym_to_utf32(xkb_keysym_to_lower(sym)));
	ghostty_key_encoder_set_from_terminal(g.keys, g.term);
	uint8_t buf[128];
	size_t n = 0;
	if (ghostty_key_encoder_encode(g.keys, g.keyEvent, buf, sizeof(buf), &n) == GHOSTTY_SUCCESS && n)
		to_pty(std::string(reinterpret_cast<const char*>(buf), n));
	else if (action != GHOSTTY_KEY_ACTION_RELEASE && key == GHOSTTY_KEY_UNIDENTIFIED && !utf8.empty())
		to_pty(utf8); // a key Ghostty has no name for that still typed something
	ghostty_key_event_set_utf8(g.keyEvent, GhosttyString{});
}

// Ctrl+= (or +) bigger, ctrl+- smaller, ctrl+0 back, a point at a time, as Ghostty and Alacritty.
// The terminal reflows to the new cell size; the program gets the new rows and columns.
static bool zoom_key(uint32_t sym)
{
	int step;
	switch (sym)
	{
	case XKB_KEY_equal: case XKB_KEY_plus: case XKB_KEY_KP_Add: step = 1; break;
	case XKB_KEY_minus: case XKB_KEY_KP_Subtract: step = -1; break;
	case XKB_KEY_0: case XKB_KEY_KP_0: case XKB_KEY_KP_Insert: step = 0; break;
	default: return false;
	}
	const double base = strtod(g.get("fontSize", "9").c_str(), nullptr);
	const int next = step ? std::clamp(g.zoom + step, int(std::ceil(4.0 - base)), int(std::floor(48.0 - base))) : 0;
	if (next != g.zoom && g.frame.data)
	{
		g.zoom = next;
		resize(g.pixelW, g.pixelH, g.scale, true);
	}
	return true;
}

static void key_down(uint32_t evdev, uint32_t sym, const std::string& text)
{
	g.held.insert(evdev);
	if (g.pty < 0 && (sym == 0xff0d || sym == 0xff8d)) // Return, KP_Enter: try again now
		g.retryNow = true;
	if (g.pty < 0)
		return;
	if (is_modifier(sym))
	{
		encode_key(GHOSTTY_KEY_ACTION_PRESS, evdev, sym, {}); // the Kitty protocol may report it
		return;
	}
	g.typed = true;
	const bool shift = shift_held(), ctrl = ctrl_held();

	// The terminal's own keys.
	const uint32_t lower = xkb_keysym_to_lower(sym);
	if (ctrl && shift && lower == XKB_KEY_c)
		return copy_selection();
	// Omarchy's Super+C sends this to a window tagged as a terminal.
	if (ctrl && !shift && (sym == XKB_KEY_Insert || sym == XKB_KEY_KP_Insert))
		return copy_selection();
	if (ctrl && shift && lower == XKB_KEY_v)
		return paste();
	if (shift && !ctrl && sym == XKB_KEY_Insert)
		return paste();
	if (shift && !ctrl && (sym == XKB_KEY_Page_Up || sym == XKB_KEY_Page_Down) && !g.altScreen)
		return scroll_view(sym == XKB_KEY_Page_Up ? g.rows - 1 : -(g.rows - 1));
	if (ctrl && !alt_held() && zoom_key(sym))
	{
		g.zoomKeys.insert(evdev);
		return;
	}

	// Typing returns the view to the bottom.
	scroll_to_bottom();
	clear_selection();
	encode_key(GHOSTTY_KEY_ACTION_PRESS, evdev, sym, text);
}

static void key_up(uint32_t evdev, uint32_t sym)
{
	g.held.erase(evdev);
	if (g.zoomKeys.erase(evdev))
		return;
	if (g.pty >= 0)
		encode_key(GHOSTTY_KEY_ACTION_RELEASE, evdev, sym, {}); // nothing unless the program asked for releases
}

static Pos pos_at(int x, int y)
{
	const int col = std::clamp((x - g.pad) / std::max(1, g.cellW), 0, g.cols - 1);
	const int row = std::clamp((y - g.pad) / std::max(1, g.cellH), 0, g.rows - 1);
	return Pos{ long(scrollbar().offset) + row, col };
}

// Whether the program in the terminal gets the mouse (shift keeps it for selecting).
static bool program_mouse()
{
	return g.mouseTracking && !shift_held();
}

static void send_mouse(GhosttyMouseAction action, int button, int x, int y)
{
	ghostty_mouse_event_set_action(g.mouseEvent, action);
	if (button)
		ghostty_mouse_event_set_button(g.mouseEvent, GhosttyMouseButton(button));
	else
		ghostty_mouse_event_clear_button(g.mouseEvent);
	ghostty_mouse_event_set_mods(g.mouseEvent, mods());
	ghostty_mouse_event_set_position(g.mouseEvent, GhosttyMousePosition{ float(x), float(y) });
	ghostty_mouse_encoder_set_from_terminal(g.mouse, g.term);
	const bool pressed = g.mouseButtons != 0;
	ghostty_mouse_encoder_set(g.mouse, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed);
	uint8_t buf[64];
	size_t n = 0;
	if (ghostty_mouse_encoder_encode(g.mouse, g.mouseEvent, buf, sizeof(buf), &n) == GHOSTTY_SUCCESS && n)
		to_pty(std::string(reinterpret_cast<const char*>(buf), n));
}

static void mouse_button(int button, bool down, int x, int y)
{
	// UI numbering: 1 left, 2 right, 3 middle; Ghostty's is the same.
	if (program_mouse() && button >= 1 && button <= 3)
	{
		if (down)
			g.mouseButtons |= 1 << button;
		else
			g.mouseButtons &= ~(1 << button);
		send_mouse(down ? GHOSTTY_MOUSE_ACTION_PRESS : GHOSTTY_MOUSE_ACTION_RELEASE, button, x, y);
		return;
	}
	if (button == 1)
	{
		const Pos p = pos_at(x + g.cellW / 2, y); // the gap nearest the pointer
		if (down)
		{
			clear_selection();
			g.selecting = true;
			g.selAnchor = g.selHead = p;
		}
		else
			g.selecting = false;
	}
	else if (button == 3 && down)
		paste();
}

static void mouse_move(int x, int y)
{
	if (program_mouse())
	{
		// The encoder knows the tracking mode: motion only with a button, or always, or never.
		int button = 0;
		for (int b = 1; b <= 3; b++)
			if (g.mouseButtons & (1 << b))
			{
				button = b;
				break;
			}
		send_mouse(GHOSTTY_MOUSE_ACTION_MOTION, button, x, y);
		return;
	}
	if (!g.selecting)
		return;
	// Dragging past the top or bottom edge scrolls.
	if (y < g.pad)
		scroll_view(1);
	else if (y >= g.pad + g.rows * g.cellH)
		scroll_view(-1);
	const Pos p = pos_at(x + g.cellW / 2, y);
	if (p == g.selHead)
		return;
	// Only the lines between the old and the new end change.
	redraw_lines(g.selHead, p);
	g.selHead = p;
	g.hasSelection = !(g.selAnchor == g.selHead);
	apply_selection();
}

static void wheel(long dy, int x, int y)
{
	const int notches = int(dy / 120);
	if (!notches)
		return;
	if (program_mouse())
	{
		for (int i = 0; i < std::abs(notches); i++)
			send_mouse(GHOSTTY_MOUSE_ACTION_PRESS, notches > 0 ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE, x,
			           y);
		return;
	}
	if (g.altScreen)
	{
		// Full-screen programs without the mouse (less, man): the wheel moves through them, as
		// arrow keys in the mode the program set.
		const uint32_t evdev = notches > 0 ? 103 : 108; // KEY_UP, KEY_DOWN
		for (int i = 0; i < 3 * std::abs(notches); i++)
			encode_key(GHOSTTY_KEY_ACTION_PRESS, evdev, notches > 0 ? XKB_KEY_Up : XKB_KEY_Down, {});
		return;
	}
	scroll_view(3 * notches);
}

static void handle_line(const std::string& line)
{
	const auto w = split(line);
	if (w.empty())
		return;
	const std::string& cmd = w[0];
	auto num = [&](size_t i) -> long { return i < w.size() ? strtol(w[i].c_str(), nullptr, 10) : 0; };

	if (cmd == "size" && w.size() >= 3)
		resize(int(num(1)), int(num(2)), w.size() >= 4 ? int(num(3)) : g.scale);
	else if (cmd == "key" && w.size() >= 3)
	{
		const uint32_t evdev = uint32_t(num(2));
		const uint32_t sym = w.size() >= 4 ? uint32_t(strtoul(w[3].c_str(), nullptr, 10)) : 0;
		if (num(1))
			key_down(evdev, sym, w.size() >= 5 ? unb64(w[4]) : std::string());
		else
			key_up(evdev, sym);
	}
	else if (cmd == "text" && w.size() >= 2 && g.pty >= 0)
	{
		// Composed text that came without a key: as it is, control characters left out.
		std::string text;
		for (char32_t c : QString::fromStdString(unb64(w[1])).toUcs4())
			if (c >= 0x20 && c != 0x7f)
				text += QString::fromUcs4(&c, 1).toStdString();
		to_pty(text);
	}
	else if (cmd == "mouse" && w.size() >= 3)
		mouse_move(int(num(1)), int(num(2)));
	else if (cmd == "button" && w.size() >= 5)
		mouse_button(int(num(1)), num(2) != 0, int(num(3)), int(num(4)));
	else if (cmd == "wheel" && w.size() >= 5)
		wheel(num(1), int(num(3)), int(num(4)));
	else if (cmd == "clip" && w.size() >= 2)
		g.localClip = unb64(w[1]);
	else if (cmd == "opacity" && w.size() >= 2)
	{
		const int alpha = int(std::clamp(num(1), 0L, 255L));
		if (alpha != g.bgAlpha)
		{
			g.bgAlpha = alpha;
			g.full = true;
		}
	}
	else if (cmd == "disconnect")
		g.quit = 1;
	else if (cmd == "reconnect" && w.size() >= 2 && !g.reconnectLine.empty())
	{
		// Only while the view shows the banner: a late click never ends a connection that is back.
		if (w[1] == "now")
			g.retryNow = true;
		else if (w[1] == "cancel")
			g.cancelReconnect = true;
	}
}

// What the program printed, into the terminal.
static void term_write(const char* s, size_t len)
{
	ghostty_terminal_vt_write(g.term, reinterpret_cast<const uint8_t*>(s), len);
	g.output = true;
	after_write();
}

// ---------------------------------------------------------------- main

static void on_signal(int)
{
	g.quit = 1;
}

static void replay()
{
	g.link.send("state connected");
	if (g.frame.data)
		g.link.sendFrame(g.frame);
	send_cursor_shape();
	if (!g.title.empty())
		g.link.send("title " + b64(g.title));
	if (!g.reconnectLine.empty())
		g.link.send(g.reconnectLine);
	g.held.clear();
}

// How long a session that lost its connection keeps trying, and how long an ssh must have run
// to count as a session that was up (not a sign-in that went wrong at once).
// A `reconnectMs=` config line scales every pause, kUpMs and kReconnectMs by it/1000 (tests/test_ssh.py).
static constexpr uint64_t kReconnectMs = 10 * 60 * 1000;
static constexpr uint64_t kUpMs = 5000;
// How long a try keeps running after it first printed (a prompt, a shell) to count as answered.
static constexpr uint64_t kAnsweredMs = 2000;
// Drops in a row with nothing typed in between: then it is no one at work there, and a server
// that makes "Broken pipe" its last words (and exits 255, as ssh does) cannot keep us dialling.
static constexpr int kMaxQuietDrops = 20;
static uint64_t g_pace = 1000; // milliseconds in a second of pause

// The last line of this try's terminal output (ssh's words, or the remote program's last ones),
// its escapes left out: what its exit is judged by. Never the screen, where a program's cursor
// moves can leave older words at the bottom.
static std::string said_last()
{
	std::string text;
	for (size_t i = 0; i < g.said.size(); i++)
	{
		const unsigned char c = static_cast<unsigned char>(g.said[i]);
		if (c == 0x1b && i + 1 < g.said.size())
		{
			const char kind = g.said[++i];
			if (kind == '[') // CSI: up to its final byte
				while (i + 1 < g.said.size() && !(g.said[i + 1] >= 0x40 && g.said[i + 1] <= 0x7e))
					i++;
			if (kind == '[' || kind == '(' || kind == ')')
				i++;
			else if (kind == ']') // OSC: up to BEL or ST
				while (i + 1 < g.said.size() && g.said[i + 1] != '\a' && g.said[i + 1] != 0x1b)
					i++;
			continue;
		}
		text += c == '\r' ? '\n' : (c < 0x20 && c != '\n') ? ' ' : char(c);
	}
	const size_t end = text.find_last_not_of(" \n");
	if (end == std::string::npos)
		return {};
	const size_t nl = text.rfind('\n', end);
	const size_t start = nl == std::string::npos ? 0 : nl + 1;
	std::string line = text.substr(start, end + 1 - start);
	line.erase(0, line.find_first_not_of(' '));
	return line.size() > 512 ? line.substr(0, 512) : line;
}

// The view's banner: "wait <try> <seconds>" before a try, "trying <try>" during one, "off" when
// the connection is back or given up.
static void show_reconnect(const std::string& what)
{
	g.reconnectLine = what == "off" ? std::string() : "reconnect " + what;
	g.link.send(what == "off" ? std::string("reconnect off") : g.reconnectLine);
}

// ssh in a new terminal the size of the view: at the start, and again after a lost connection.
static bool start_ssh(std::vector<std::string>& args)
{
	winsize ws = {};
	ws.ws_row = uint16_t(g.rows);
	ws.ws_col = uint16_t(g.cols);
	g.child = forkpty(&g.pty, nullptr, nullptr, &ws);
	if (g.child < 0)
	{
		g.pty = -1;
		log("cannot start a terminal: %s", strerror(errno));
		return false;
	}
	if (g.child == 0)
	{
		setenv("TERM", "xterm-256color", 1);
		setenv("COLORTERM", "truecolor", 1);
		unsetenv("OMAREMOTE_SOCKET");
		std::vector<char*> cargs;
		for (auto& a : args)
			cargs.push_back(a.data());
		cargs.push_back(nullptr);
		execvp(cargs[0], cargs.data());
		fprintf(stderr, "cannot run %s: %s\r\n", cargs[0], strerror(errno));
		_exit(127);
	}
	fcntl(g.pty, F_SETFL, fcntl(g.pty, F_GETFL) | O_NONBLOCK);
	g_ptyStalledSince = 0; // a new terminal: the last one's stall says nothing about this one
	return true;
}

// The terminal, until ssh exits: its exit status, or 11 when the session was stopped.
static int run_ssh()
{
	uint64_t lastThemeCheck = 0;
	uint64_t saidAt = 0; // when this try first printed something
	char buf[65536];
	bool ended = false;
	g.said.clear();
	while (!g.quit && !ended && !g.cancelReconnect)
	{
		// A try that answered (a prompt, a shell) and keeps running is a connection again: the
		// view's banner goes. One still waiting for the computer prints nothing and keeps it; one
		// that failed prints its reason and exits at once.
		if (!g.reconnectLine.empty() && saidAt && oma::now_ms() - saidAt >= kAnsweredMs * g_pace / 1000)
			show_reconnect("off");
		pollfd fds[3] = { { g.pty, POLLIN, 0 }, { g.link.listenFd(), POLLIN, 0 }, { g.link.clientFd(), POLLIN, 0 } };
		const int n = poll(fds, g.link.attached() ? 3 : 2, 500);
		if (n < 0 && errno != EINTR)
			break;
		if (fds[0].revents & (POLLIN | POLLHUP | POLLERR))
		{
			// Read what is there, a bounded amount at a time, so a flood of output still draws.
			for (int i = 0; i < 16; i++)
			{
				const ssize_t got = read(g.pty, buf, sizeof(buf));
				if (got > 0)
				{
					term_write(buf, size_t(got));
					g.said.append(buf, size_t(got));
					if (!saidAt)
						saidAt = oma::now_ms();
					if (g.said.size() > 8192)
						g.said.erase(0, g.said.size() - 4096);
					continue;
				}
				if (got < 0 && (errno == EAGAIN || errno == EINTR))
					break;
				ended = true; // EIO: the program exited and the terminal closed
				break;
			}
		}
		for (const auto& l : g.link.poll())
			handle_line(l);
		if (oma::now_ms() - lastThemeCheck > 1000)
		{
			lastThemeCheck = oma::now_ms();
			check_theme();
		}
		flush();
	}
	flush();

	int rc = 0;
	if ((g.quit || g.cancelReconnect) && !ended)
	{
		kill(g.child, SIGHUP);
		rc = g.quit ? 11 : 255; // a cancelled try fails as the drop it was for
	}
	int status = 0;
	for (int i = 0; i < 50 && waitpid(g.child, &status, WNOHANG) == 0; i++)
		usleep(20000);
	if (waitpid(g.child, &status, WNOHANG) == 0)
	{
		kill(g.child, SIGKILL);
		waitpid(g.child, &status, 0);
	}
	if (rc == 0)
		rc = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
	close(g.pty);
	g.pty = -1;
	return rc;
}

static bool says(const std::string& text, std::initializer_list<const char*> words)
{
	for (const char* w : words)
		if (text.find(w) != std::string::npos)
			return true;
	return false;
}

// ssh's last words when a connection that was up went away (a restart, a network change). Not
// a refusal before signing in (kex_exchange_identification: too many tries, fail2ban): that
// one is never retried.
static bool lost_words(const std::string& said)
{
	return !says(said, { "kex_exchange_identification" }) &&
	       says(said, { "Broken pipe", "closed by remote host", "Connection reset", "not responding",
	                    "packet_write_wait", "Software caused connection abort" });
}

// ...and of a try that may work in a while: the computer still starting, the network still coming.
static bool transient_words(const std::string& said)
{
	return lost_words(said) ||
	       says(said, { "Connection refused", "timed out", "No route to host", "Network is unreachable",
	                    "Could not resolve hostname", "Name or service not known",
	                    "Temporary failure in name resolution", "Connection closed by" });
}

// A dim line in the terminal between what was and what comes; the modes a program on the server
// left on (its own screen, mouse reporting, bracketed paste, a hidden cursor) end with it.
static void note(std::string text)
{
	// Never a control character from a setting (the host): nothing here can be an escape.
	text.erase(std::remove_if(text.begin(), text.end(), [](unsigned char c) { return c < 0x20 || c == 0x7f; }),
	           text.end());
	// Its own screen only when one is on: ?1049l also puts the cursor back where it was saved.
	if (g.altScreen)
		term_write("\x1b[?1049l", 8);
	static const char reset[] = "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?2004l\x1b[?25h\x1b[0m";
	term_write(reset, sizeof(reset) - 1);
	const std::string line = "\r\n\x1b[2m\xe2\x94\x80\xe2\x94\x80 " + text + " \xe2\x94\x80\xe2\x94\x80\x1b[0m\r\n";
	term_write(line.data(), line.size());
	flush();
}

// A pause between tries, the view still served (drawn, resized, scrolled); Enter ends it early.
// False when the session was stopped meanwhile.
static bool wait_serving(uint64_t ms)
{
	const uint64_t until = oma::now_ms() + ms;
	g.retryNow = false;
	while (!g.quit && !g.retryNow && !g.cancelReconnect && oma::now_ms() < until)
	{
		pollfd fds[2] = { { g.link.listenFd(), POLLIN, 0 }, { g.link.clientFd(), POLLIN, 0 } };
		poll(fds, g.link.attached() ? 2 : 1, int(std::min<uint64_t>(200, until - oma::now_ms())));
		for (const auto& l : g.link.poll())
			handle_line(l);
		flush();
	}
	return !g.quit && !g.cancelReconnect;
}

int main(int argc, char** argv)
{
	oma::limit_memory();
	std::vector<std::string> args;
	std::string line;
	while (std::getline(std::cin, line))
	{
		const size_t eq = line.find('=');
		if (eq == std::string::npos)
			continue;
		const std::string key = line.substr(0, eq), value = line.substr(eq + 1);
		if (key == "arg")
			args.push_back(value);
		else
			g.cfg.emplace(key, value);
	}
	if (args.empty())
	{
		log("nothing to run");
		return 2;
	}
	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	signal(SIGHUP, on_signal);
	signal(SIGPIPE, SIG_IGN);

	// Fonts through fontconfig, no window: the drawing happens in the framebuffer.
	setenv("QT_QPA_PLATFORM", "offscreen", 1);
	QGuiApplication app(argc, argv);

	g.themePath = g.get("theme");
	if (!g.link.listen(getenv("OMAREMOTE_SOCKET")))
		return 136;
	g.link.onAttach = replay;

	// The terminal: its scrollback, and what it tells us (output to the program, a title, a
	// clipboard write). No clipboard read: a program on the server never reads ours.
	if (ghostty_terminal_new(nullptr, &g.term, uint16_t(g.cols), uint16_t(g.rows)) != GHOSTTY_SUCCESS ||
	    ghostty_render_state_new(nullptr, &g.render) != GHOSTTY_SUCCESS ||
	    ghostty_render_state_row_iterator_new(nullptr, &g.rowIt) != GHOSTTY_SUCCESS ||
	    ghostty_render_state_row_cells_new(nullptr, &g.cells) != GHOSTTY_SUCCESS ||
	    ghostty_key_encoder_new(nullptr, &g.keys) != GHOSTTY_SUCCESS ||
	    ghostty_key_event_new(nullptr, &g.keyEvent) != GHOSTTY_SUCCESS ||
	    ghostty_mouse_encoder_new(nullptr, &g.mouse) != GHOSTTY_SUCCESS ||
	    ghostty_mouse_event_new(nullptr, &g.mouseEvent) != GHOSTTY_SUCCESS)
	{
		log("cannot start the terminal");
		return 1;
	}
	const size_t scrollback = size_t(std::max(0L, strtol(g.get("scrollback", "10000").c_str(), nullptr, 10)));
	ghostty_terminal_set(g.term, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &scrollback);
	// No Kitty graphics: nothing here shows images, and a remote program could fill memory with
	// them (stored up to 10 MB by default). Zero turns the protocol off; loading from files or
	// shared memory is off already. Escape sequences of that kind are buffered up to 64 KiB.
	const uint64_t noImages = 0;
	if (ghostty_terminal_set(g.term, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &noImages) != GHOSTTY_SUCCESS)
		log("Kitty graphics: not turned off (not in this libghostty-vt)");
	const size_t apcMax = 64 << 10;
	ghostty_terminal_set(g.term, GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES, &apcMax);
	ghostty_terminal_set(g.term, GHOSTTY_TERMINAL_OPT_WRITE_PTY, reinterpret_cast<const void*>(&cb_write_pty));
	ghostty_terminal_set(g.term, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, reinterpret_cast<const void*>(&cb_title));
	ghostty_terminal_set(g.term, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, reinterpret_cast<const void*>(&cb_clipboard_write));
	// Unicode grapheme clusters (mode 2027), as Ghostty itself runs: an emoji with a skin tone, a flag,
	// a family is one character of the right width, not its parts side by side.
	GhosttyTerminalModeConfig clusters = {};
	clusters.mode = GHOSTTY_MODE_GRAPHEME_CLUSTER;
	clusters.value = true;
	ghostty_terminal_set(g.term, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &clusters);
	load_theme();
	check_theme();

	// A size to start with; the UI sends the tab's as soon as it attaches.
	resize(1280, 800, 100);

	if (!start_ssh(args))
	{
		g.link.send("state failed 1");
		g.link.close();
		return 1;
	}
	// The terminal is up: the user answers ssh's questions (host key, password) in it.
	// The supervisor reads this line as "connected".
	const std::string host = g.get("host", args.back().c_str());
	log("connected to %s", host.c_str());
	g.link.send("state connected");
	send_cursor_shape();

	// A connection that goes away under a working session (the computer restarts, the network
	// changes) is tried again in the same terminal, the screen and history kept, for up to
	// kReconnectMs with growing pauses. A shell that ends, a sign-in that fails, a host key that
	// is not accepted: those end the session as before.
	const bool reconnect = g.get("reconnect", "1") == "1";
	g_pace = std::clamp<uint64_t>(strtoull(g.get("reconnectMs", "1000").c_str(), nullptr, 10), 1, 1000);
	// giveUp: trying again until then. A connection that came back and stayed up (kUpMs) before
	// dropping again starts a new 10 minutes; kMaxQuietDrops ends that when no one types.
	uint64_t giveUp = 0, delay = 0;
	int quietDrops = 0, tries = 0;
	std::string lost; // what ssh said when the connection went
	int rc;
	for (;;)
	{
		const uint64_t began = oma::now_ms();
		rc = run_ssh();
		// A server shutting down (a reboot) may stop the shell before it cuts the connection: ssh
		// then ends with the shell's hang-up or terminate signal, not 255. A drop too, once it was up.
		const bool shellStopped = rc == 128 + SIGHUP || rc == 128 + SIGTERM;
		if ((rc != 255 && !shellStopped) || !reconnect || g.cancelReconnect)
			break;
		std::string said = said_last();
		const uint64_t now = oma::now_ms();
		const bool wasUp = now - began >= kUpMs * g_pace / 1000;
		if (shellStopped && !wasUp)
			break;
		if (shellStopped)
			said = "the remote shell was stopped (" + std::to_string(rc) + ")";
		if (wasUp && (shellStopped || lost_words(said)))
		{
			quietDrops = g.typed ? 1 : quietDrops + 1;
			g.typed = false;
			if (quietDrops > kMaxQuietDrops)
				break;
			log("connection lost: %s; trying again", said.c_str());
			lost = said;
			giveUp = now + kReconnectMs * g_pace / 1000;
			delay = 2000;
			tries = 0;
		}
		else if (!giveUp || now >= giveUp || !transient_words(said))
			break;
		else
			delay = std::min<uint64_t>(delay * 2, 15000);
		tries++;
		note("connection lost: trying again in " + std::to_string(delay / 1000) + " s");
		show_reconnect("wait " + std::to_string(tries) + " " + std::to_string(delay / 1000));
		if (!wait_serving(delay * g_pace / 1000))
		{
			if (g.quit)
				rc = 11;
			break;
		}
		note("connecting to " + host);
		show_reconnect("trying " + std::to_string(tries));
		if (!start_ssh(args))
			break;
	}
	if (!g.reconnectLine.empty())
		show_reconnect("off");
	if (g.cancelReconnect)
	{
		// Given up from the view: it ends as the drop it was, in ssh's words then.
		log("reconnecting cancelled");
		rc = 255;
		g.said = lost;
	}
	// ssh exits 255 when the connection failed; what it said is on the screen.
	if (rc == 255)
		log("connection failed: %s", said_last().c_str());
	log("session ended (%d)", rc);
	g.link.send(std::string(rc == 255 ? "state failed " : "state ended ") + std::to_string(rc));
	g.link.close();
	return rc;
}
