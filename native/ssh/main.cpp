// omaremote-ssh: one SSH session, a terminal drawn for a tab in the OMARemote window.
//
// ssh runs in a pseudo-terminal; libvterm keeps the screen, and this process draws it into the
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
// Terminal keys: ctrl+shift+c copies the selection, ctrl+shift+v (or shift+insert, or a middle
// click) pastes, shift+page up/down and the wheel scroll back. Remote programs that ask for the
// mouse (htop, vim with mouse=a) get it; shift+drag still selects.

#include "../common/link.hpp"

#include <QFont>
#include <QFontMetricsF>
#include <QGlyphRun>
#include <QGuiApplication>
#include <QImage>
#include <QPainter>
#include <QRawFont>

#include <vterm.h>
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

// A cell position in the whole history: lines 0 .. scrollback.size()-1 are history, the screen
// follows them.
struct Pos
{
	long line = 0;
	int col = 0;
	bool operator<(const Pos& o) const { return line < o.line || (line == o.line && col < o.col); }
	bool operator==(const Pos& o) const { return line == o.line && col == o.col; }
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

	VTerm* vt = nullptr;
	VTermScreen* screen = nullptr;
	int rows = 24, cols = 80;

	// Drawing.
	oma::Framebuffer frame;
	QImage image; // wraps frame.data
	int pixelW = 0, pixelH = 0, scale = 100;
	QFont font;
	QRawFont raw[4]; // regular, bold, italic, bold italic
	int cellW = 8, cellH = 16, ascent = 12;
	int pad = 6; // margin around the cells, in pixels
	Palette pal;
	std::string themePath;
	struct timespec themeTime = {};

	// What changed since the last flush, in cells; full when the whole picture must be redrawn.
	bool dirty = false, full = false;
	int dr0 = 0, dc0 = 0, dr1 = 0, dc1 = 0;

	VTermPos cursor = { 0, 0 };
	bool cursorVisible = true;
	int cursorShape = VTERM_PROP_CURSORSHAPE_BLOCK;
	bool altScreen = false;
	int mouseMode = VTERM_PROP_MOUSE_NONE;
	std::string title;

	// History above the screen, oldest first, and how far the view is scrolled into it.
	std::deque<std::vector<VTermScreenCell>> history;
	size_t historyMax = 10000;
	int viewOffset = 0;

	// Mouse selection, in history positions; empty when anchor == head.
	bool selecting = false;
	Pos selAnchor, selHead;
	bool hasSelection = false;
	int mouseButtons = 0; // buttons held, for the remote program's mouse reporting

	std::set<uint32_t> held; // evdev codes held: the modifiers come from these
	std::string localClip;   // the UI's clipboard, offered on focus and when it changes
	std::string osc52;       // a clipboard write from the remote program, gathered in fragments

	std::string get(const char* key, const char* fallback = "") const
	{
		auto it = cfg.find(key);
		return it == cfg.end() || it->second.empty() ? fallback : it->second;
	}
};

static Session g;

// ---------------------------------------------------------------- theme

static QColor hex(const std::string& s)
{
	QColor c(QString::fromStdString("#" + s));
	return c.isValid() ? c : QColor();
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
	if (!g.vt)
		return;
	VTermState* state = vterm_obtain_state(g.vt);
	auto vc = [](const QColor& q) {
		VTermColor c;
		vterm_color_rgb(&c, uint8_t(q.red()), uint8_t(q.green()), uint8_t(q.blue()));
		return c;
	};
	VTermColor fg = vc(p.fg), bg = vc(p.bg);
	vterm_state_set_default_colors(state, &fg, &bg);
	for (int i = 0; i < 16; i++)
	{
		VTermColor c = vc(p.ansi[i]);
		vterm_state_set_palette_color(state, i, &c);
	}
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
	g.full = g.dirty = true;
}

// ---------------------------------------------------------------- font and size

static void setup_font()
{
	const double points = strtod(g.get("fontSize", "9").c_str(), nullptr);
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

// The view's size in pixels, and the screen scale: a new framebuffer that size, as many cells as
// fit. The terminal and the program in it follow.
static void resize(int w, int h, int scale)
{
	w = std::clamp(w, 64, 16384);
	h = std::clamp(h, 32, 16384);
	scale = std::clamp(scale, 50, 500);
	if (w == g.pixelW && h == g.pixelH && scale == g.scale && g.frame.data)
		return;
	const bool fontChanged = scale != g.scale || !g.frame.data;
	g.scale = scale;
	if (fontChanged)
		setup_font();
	oma::Framebuffer fb = oma::fb_alloc(uint32_t(w), uint32_t(h));
	if (!fb.data)
		return;
	oma::Framebuffer old = g.frame;
	g.frame = fb;
	g.image = QImage(fb.data, w, h, int(fb.stride), QImage::Format_RGB32);
	g.pixelW = w;
	g.pixelH = h;
	const int cols = std::max(2, (w - 2 * g.pad) / g.cellW), rows = std::max(1, (h - 2 * g.pad) / g.cellH);
	if (cols != g.cols || rows != g.rows)
	{
		g.cols = cols;
		g.rows = rows;
		vterm_set_size(g.vt, rows, cols);
		set_pty_size();
	}
	g.viewOffset = std::min<int>(g.viewOffset, int(g.history.size()));
	g.full = g.dirty = true;
	g.link.sendFrame(g.frame);
	if (old.data)
		oma::fb_release(old.data);
}

// ---------------------------------------------------------------- reading cells

static void blank_cell(VTermScreenCell& c)
{
	c = {};
	c.width = 1;
	vterm_color_rgb(&c.fg, 0, 0, 0);
	c.fg.type = VTERM_COLOR_DEFAULT_FG;
	vterm_color_rgb(&c.bg, 0, 0, 0);
	c.bg.type = VTERM_COLOR_DEFAULT_BG;
}

// The cell at a history position (history lines first, then the screen).
static VTermScreenCell cell_at(long line, int col)
{
	VTermScreenCell c;
	const long h = long(g.history.size());
	if (line < h)
	{
		const auto& l = g.history[size_t(line)];
		if (col < int(l.size()))
			return l[size_t(col)];
		blank_cell(c);
		return c;
	}
	if (vterm_screen_get_cell(g.screen, VTermPos{ int(line - h), col }, &c) == 0)
		blank_cell(c);
	return c;
}

// The history line shown on a screen row, given how far the view is scrolled back.
static long line_of_row(int row)
{
	return long(g.history.size()) - g.viewOffset + row;
}

static QColor resolve(VTermColor c, bool fg)
{
	if (fg ? VTERM_COLOR_IS_DEFAULT_FG(&c) : VTERM_COLOR_IS_DEFAULT_BG(&c))
		return fg ? g.pal.fg : g.pal.bg;
	if (VTERM_COLOR_IS_INDEXED(&c) && c.indexed.idx < 16)
		return g.pal.ansi[c.indexed.idx];
	vterm_screen_convert_color_to_rgb(g.screen, &c);
	return QColor(c.rgb.red, c.rgb.green, c.rgb.blue);
}

static bool selected(long line, int col)
{
	if (!g.hasSelection)
		return false;
	Pos a = g.selAnchor, b = g.selHead;
	if (b < a)
		std::swap(a, b);
	const Pos p{ line, col };
	return !(p < a) && p < b;
}

// ---------------------------------------------------------------- drawing

static void draw_rows(int r0, int r1, int c0, int c1)
{
	if (g.image.isNull())
		return;
	QPainter painter(&g.image);
	painter.setRenderHint(QPainter::TextAntialiasing);
	for (int row = r0; row < r1 && row < g.rows; row++)
	{
		const long line = line_of_row(row);
		const int y = g.pad + row * g.cellH;
		for (int col = c0; col < c1 && col < g.cols; col++)
		{
			VTermScreenCell cell = cell_at(line, col);
			// The right half of a wide character is drawn with its left half.
			if (cell.chars[0] == uint32_t(-1) || (col > 0 && cell.width == 0))
				continue;
			const int span = std::max(1, int(cell.width));
			QColor fg = resolve(cell.fg, true), bg = resolve(cell.bg, false);
			if (cell.attrs.reverse)
				std::swap(fg, bg);
			if (selected(line, col))
			{
				fg = g.pal.selFg;
				bg = g.pal.selBg;
			}
			const bool atCursor = g.viewOffset == 0 && g.cursorVisible && row == g.cursor.row && col == g.cursor.col;
			if (atCursor && g.cursorShape == VTERM_PROP_CURSORSHAPE_BLOCK)
			{
				fg = g.pal.cursorText;
				bg = g.pal.cursor;
			}
			const QRect box(g.pad + col * g.cellW, y, span * g.cellW, g.cellH);
			painter.fillRect(box, bg);
			if (cell.chars[0] && cell.chars[0] != ' ' && !cell.attrs.conceal)
			{
				QString text;
				for (int i = 0; i < VTERM_MAX_CHARS_PER_CELL && cell.chars[i]; i++)
					text += QString::fromUcs4(reinterpret_cast<const char32_t*>(&cell.chars[i]), 1);
				const QRawFont& raw = g.raw[(cell.attrs.bold ? 1 : 0) | (cell.attrs.italic ? 2 : 0)];
				const QList<quint32> glyphs = raw.glyphIndexesForString(text);
				painter.setPen(fg);
				if (!glyphs.isEmpty() && glyphs[0] != 0 && glyphs.size() == 1)
				{
					QGlyphRun run;
					run.setRawFont(raw);
					run.setGlyphIndexes(glyphs);
					run.setPositions({ QPointF(box.x(), y + g.ascent) });
					painter.drawGlyphRun(QPointF(0, 0), run);
				}
				else
				{
					// Combining characters, and glyphs the font lacks: let Qt pick a fallback.
					QFont f = g.font;
					f.setBold(cell.attrs.bold);
					f.setItalic(cell.attrs.italic);
					painter.setFont(f);
					painter.drawText(QPointF(box.x(), y + g.ascent), text);
				}
			}
			const int thick = std::max(1, g.cellH / 14);
			if (cell.attrs.underline)
				painter.fillRect(QRect(box.x(), y + g.ascent + thick, box.width(), thick), fg);
			if (cell.attrs.strike)
				painter.fillRect(QRect(box.x(), y + g.cellH / 2, box.width(), thick), fg);
			if (atCursor && g.cursorShape == VTERM_PROP_CURSORSHAPE_UNDERLINE)
				painter.fillRect(QRect(box.x(), y + g.cellH - 2 * thick, box.width(), 2 * thick), g.pal.cursor);
			if (atCursor && g.cursorShape == VTERM_PROP_CURSORSHAPE_BAR_LEFT)
				painter.fillRect(QRect(box.x(), y, 2 * thick, g.cellH), g.pal.cursor);
		}
	}
}

// Draws what changed and tells the UI where.
static void flush()
{
	if (!g.dirty || g.image.isNull())
		return;
	if (g.full)
	{
		{
			QPainter painter(&g.image);
			painter.fillRect(g.image.rect(), g.pal.bg);
		}
		draw_rows(0, g.rows, 0, g.cols);
		g.link.send("damage 0 0 " + std::to_string(g.pixelW) + " " + std::to_string(g.pixelH));
	}
	else
	{
		draw_rows(g.dr0, g.dr1, g.dc0, g.dc1);
		g.link.send("damage " + std::to_string(g.pad + g.dc0 * g.cellW) + " " + std::to_string(g.pad + g.dr0 * g.cellH) + " " +
		            std::to_string((g.dc1 - g.dc0) * g.cellW) + " " + std::to_string((g.dr1 - g.dr0) * g.cellH));
	}
	g.dirty = g.full = false;
}

static void damage(int r0, int r1, int c0, int c1)
{
	if (g.viewOffset > 0)
	{
		g.full = true; // the view is shifted against the screen: redraw it whole
		g.dirty = true;
		return;
	}
	if (!g.dirty)
	{
		g.dr0 = r0, g.dr1 = r1, g.dc0 = c0, g.dc1 = c1;
		g.dirty = true;
		return;
	}
	g.dr0 = std::min(g.dr0, r0), g.dr1 = std::max(g.dr1, r1);
	g.dc0 = std::min(g.dc0, c0), g.dc1 = std::max(g.dc1, c1);
}

static void scroll_view(int lines)
{
	const int next = std::clamp(g.viewOffset + lines, 0, int(g.history.size()));
	if (next == g.viewOffset)
		return;
	g.viewOffset = next;
	g.full = g.dirty = true;
}

// ---------------------------------------------------------------- libvterm callbacks

static int cb_damage(VTermRect r, void*)
{
	damage(r.start_row, r.end_row, r.start_col, r.end_col);
	return 1;
}

static int cb_movecursor(VTermPos pos, VTermPos old, int visible, void*)
{
	damage(old.row, old.row + 1, old.col, old.col + 2);
	g.cursor = pos;
	g.cursorVisible = visible;
	damage(pos.row, pos.row + 1, pos.col, pos.col + 2);
	return 1;
}

static void send_cursor_shape()
{
	// A text cursor over the terminal, the arrow while a program takes the mouse.
	g.link.send(g.mouseMode == VTERM_PROP_MOUSE_NONE ? "cursor-text" : "cursor-default");
}

static int cb_settermprop(VTermProp prop, VTermValue* val, void*)
{
	switch (prop)
	{
		case VTERM_PROP_CURSORVISIBLE:
			g.cursorVisible = val->boolean;
			damage(g.cursor.row, g.cursor.row + 1, g.cursor.col, g.cursor.col + 2);
			break;
		case VTERM_PROP_CURSORSHAPE:
			g.cursorShape = val->number;
			damage(g.cursor.row, g.cursor.row + 1, g.cursor.col, g.cursor.col + 2);
			break;
		case VTERM_PROP_ALTSCREEN:
			g.altScreen = val->boolean;
			g.viewOffset = 0;
			g.full = g.dirty = true;
			break;
		case VTERM_PROP_MOUSE:
			g.mouseMode = val->number;
			send_cursor_shape();
			break;
		case VTERM_PROP_TITLE:
			if (val->string.initial)
				g.title.clear();
			g.title.append(val->string.str, val->string.len);
			if (val->string.final)
				g.link.send("title " + b64(g.title));
			break;
		default:
			break;
	}
	return 1;
}

static int cb_sb_pushline(int cols, const VTermScreenCell* cells, void*)
{
	g.history.emplace_back(cells, cells + cols);
	if (g.history.size() > g.historyMax)
	{
		g.history.pop_front();
		// Positions are counted from the oldest line kept: move the selection along.
		g.selAnchor.line--;
		g.selHead.line--;
		if (g.selAnchor.line < 0 || g.selHead.line < 0)
			g.hasSelection = false;
	}
	else if (g.viewOffset > 0)
		g.viewOffset = std::min<int>(g.viewOffset + 1, int(g.history.size())); // keep looking at the same lines
	return 1;
}

static int cb_sb_popline(int cols, VTermScreenCell* cells, void*)
{
	if (g.history.empty())
		return 0;
	const auto& line = g.history.back();
	for (int i = 0; i < cols; i++)
	{
		if (i < int(line.size()))
			cells[i] = line[size_t(i)];
		else
			blank_cell(cells[i]);
	}
	g.history.pop_back();
	g.viewOffset = std::min<int>(g.viewOffset, int(g.history.size()));
	return 1;
}

static int cb_sb_clear(void*)
{
	g.history.clear();
	g.viewOffset = 0;
	g.hasSelection = false;
	g.full = g.dirty = true;
	return 1;
}

// OSC 52 from the remote program (tmux, Neovim): it sets our clipboard. Reading it is not offered.
static int cb_selection_set(VTermSelectionMask, VTermStringFragment frag, void*)
{
	if (frag.initial)
		g.osc52.clear();
	g.osc52.append(frag.str, frag.len);
	if (frag.final && !g.osc52.empty())
	{
		g.localClip = g.osc52;
		g.link.send("clip " + b64(g.osc52));
	}
	return 1;
}

static void cb_output(const char* s, size_t len, void*)
{
	while (len > 0 && g.pty >= 0)
	{
		const ssize_t n = write(g.pty, s, len);
		if (n < 0)
		{
			if (errno == EINTR)
				continue;
			if (errno == EAGAIN)
			{
				pollfd p = { g.pty, POLLOUT, 0 };
				poll(&p, 1, 100);
				continue;
			}
			return;
		}
		s += n;
		len -= size_t(n);
	}
}

// ---------------------------------------------------------------- selection and clipboard

static std::string selection_text()
{
	if (!g.hasSelection)
		return {};
	Pos a = g.selAnchor, b = g.selHead;
	if (b < a)
		std::swap(a, b);
	std::string out;
	for (long line = a.line; line <= b.line; line++)
	{
		const int from = line == a.line ? a.col : 0;
		const int to = line == b.line ? b.col : g.cols;
		std::string text;
		for (int col = from; col < to; col++)
		{
			const VTermScreenCell c = cell_at(line, col);
			if (c.chars[0] == uint32_t(-1))
				continue;
			if (!c.chars[0])
			{
				text += ' ';
				continue;
			}
			for (int i = 0; i < VTERM_MAX_CHARS_PER_CELL && c.chars[i]; i++)
				text += QString::fromUcs4(reinterpret_cast<const char32_t*>(&c.chars[i]), 1).toStdString();
		}
		while (!text.empty() && text.back() == ' ')
			text.pop_back();
		out += text;
		if (line != b.line)
			out += '\n';
	}
	return out;
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
// then do not run or indent it line by line).
static void paste()
{
	if (g.localClip.empty() || g.pty < 0)
		return;
	std::string text = g.localClip;
	for (auto& c : text)
		if (c == '\n')
			c = '\r';
	g.viewOffset = 0;
	g.full = g.dirty = true;
	vterm_keyboard_start_paste(g.vt);
	cb_output(text.data(), text.size(), nullptr);
	vterm_keyboard_end_paste(g.vt);
}

static void clear_selection()
{
	if (!g.hasSelection)
		return;
	g.hasSelection = false;
	g.full = g.dirty = true;
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

static VTermModifier mods()
{
	int m = VTERM_MOD_NONE;
	if (shift_held())
		m |= VTERM_MOD_SHIFT;
	if (ctrl_held())
		m |= VTERM_MOD_CTRL;
	if (alt_held())
		m |= VTERM_MOD_ALT;
	return VTermModifier(m);
}

static VTermKey special_key(uint32_t sym)
{
	switch (sym)
	{
		case XKB_KEY_Return: return VTERM_KEY_ENTER;
		case XKB_KEY_KP_Enter: return VTERM_KEY_KP_ENTER;
		case XKB_KEY_Tab:
		case XKB_KEY_ISO_Left_Tab: return VTERM_KEY_TAB;
		case XKB_KEY_BackSpace: return VTERM_KEY_BACKSPACE;
		case XKB_KEY_Escape: return VTERM_KEY_ESCAPE;
		case XKB_KEY_Up: case XKB_KEY_KP_Up: return VTERM_KEY_UP;
		case XKB_KEY_Down: case XKB_KEY_KP_Down: return VTERM_KEY_DOWN;
		case XKB_KEY_Left: case XKB_KEY_KP_Left: return VTERM_KEY_LEFT;
		case XKB_KEY_Right: case XKB_KEY_KP_Right: return VTERM_KEY_RIGHT;
		case XKB_KEY_Insert: case XKB_KEY_KP_Insert: return VTERM_KEY_INS;
		case XKB_KEY_Delete: case XKB_KEY_KP_Delete: return VTERM_KEY_DEL;
		case XKB_KEY_Home: case XKB_KEY_KP_Home: return VTERM_KEY_HOME;
		case XKB_KEY_End: case XKB_KEY_KP_End: return VTERM_KEY_END;
		case XKB_KEY_Page_Up: case XKB_KEY_KP_Page_Up: return VTERM_KEY_PAGEUP;
		case XKB_KEY_Page_Down: case XKB_KEY_KP_Page_Down: return VTERM_KEY_PAGEDOWN;
		default: break;
	}
	if (sym >= XKB_KEY_F1 && sym <= XKB_KEY_F12)
		return VTermKey(VTERM_KEY_FUNCTION(int(sym - XKB_KEY_F1) + 1));
	return VTERM_KEY_NONE;
}

static bool is_modifier(uint32_t sym)
{
	return (sym >= XKB_KEY_Shift_L && sym <= XKB_KEY_Hyper_R) || sym == XKB_KEY_ISO_Level3_Shift ||
	       sym == XKB_KEY_ISO_Level5_Shift || sym == XKB_KEY_Mode_switch || sym == XKB_KEY_Num_Lock;
}

static void key_down(uint32_t evdev, uint32_t sym, const std::string& text)
{
	g.held.insert(evdev);
	if (is_modifier(sym) || g.pty < 0)
		return;
	const bool shift = shift_held(), ctrl = ctrl_held();

	// The terminal's own keys.
	const uint32_t lower = xkb_keysym_to_lower(sym);
	if (ctrl && shift && lower == XKB_KEY_c)
		return copy_selection();
	if (ctrl && shift && lower == XKB_KEY_v)
		return paste();
	if (shift && !ctrl && sym == XKB_KEY_Insert)
		return paste();
	if (shift && !ctrl && (sym == XKB_KEY_Page_Up || sym == XKB_KEY_Page_Down) && !g.altScreen)
		return scroll_view(sym == XKB_KEY_Page_Up ? g.rows - 1 : -(g.rows - 1));

	// Typing returns the view to the bottom.
	if (g.viewOffset)
	{
		g.viewOffset = 0;
		g.full = g.dirty = true;
	}
	clear_selection();

	VTermModifier m = mods();
	if (const VTermKey key = special_key(sym); key != VTERM_KEY_NONE)
	{
		if (sym == XKB_KEY_ISO_Left_Tab)
			m = VTermModifier(m | VTERM_MOD_SHIFT);
		vterm_keyboard_key(g.vt, key, m);
		return;
	}
	// With ctrl or alt the key is a combination: the character itself, shift already applied.
	if (m & (VTERM_MOD_CTRL | VTERM_MOD_ALT))
	{
		const uint32_t c = xkb_keysym_to_utf32(sym);
		if (c)
			vterm_keyboard_unichar(g.vt, c, VTermModifier(m & ~VTERM_MOD_SHIFT));
		return;
	}
	// Plain typing: the text the keyboard layout produced (dead keys and compose included).
	const QString typed = QString::fromStdString(text);
	if (!typed.isEmpty())
	{
		for (char32_t c : typed.toUcs4())
			if (c >= 0x20 && c != 0x7f)
				vterm_keyboard_unichar(g.vt, uint32_t(c), VTERM_MOD_NONE);
		return;
	}
	if (const uint32_t c = xkb_keysym_to_utf32(sym); c >= 0x20)
		vterm_keyboard_unichar(g.vt, c, VTERM_MOD_NONE);
}

static Pos pos_at(int x, int y)
{
	const int col = std::clamp((x - g.pad) / std::max(1, g.cellW), 0, g.cols - 1);
	const int row = std::clamp((y - g.pad) / std::max(1, g.cellH), 0, g.rows - 1);
	return Pos{ line_of_row(row), col };
}

// Whether the program in the terminal gets the mouse (shift keeps it for selecting).
static bool program_mouse()
{
	return g.mouseMode != VTERM_PROP_MOUSE_NONE && !shift_held();
}

static void mouse_button(int button, bool down, int x, int y)
{
	// UI numbering: 1 left, 2 right, 3 middle. Terminals: 1 left, 2 middle, 3 right.
	const int term = button == 1 ? 1 : button == 2 ? 3 : button == 3 ? 2 : 0;
	if (program_mouse() && term)
	{
		const Pos p = pos_at(x, y);
		vterm_mouse_move(g.vt, int(p.line - long(g.history.size()) + g.viewOffset), p.col, mods());
		vterm_mouse_button(g.vt, term, down, mods());
		if (down)
			g.mouseButtons |= 1 << term;
		else
			g.mouseButtons &= ~(1 << term);
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
		if (g.mouseMode == VTERM_PROP_MOUSE_MOVE || (g.mouseMode == VTERM_PROP_MOUSE_DRAG && g.mouseButtons))
		{
			const Pos p = pos_at(x, y);
			vterm_mouse_move(g.vt, int(p.line - long(g.history.size()) + g.viewOffset), p.col, mods());
		}
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
	g.selHead = p;
	g.hasSelection = !(g.selAnchor == g.selHead);
	g.full = g.dirty = true;
}

static void wheel(long dy, int x, int y)
{
	const int notches = int(dy / 120);
	if (!notches)
		return;
	if (program_mouse())
	{
		const Pos p = pos_at(x, y);
		vterm_mouse_move(g.vt, int(p.line - long(g.history.size()) + g.viewOffset), p.col, mods());
		for (int i = 0; i < std::abs(notches); i++)
		{
			vterm_mouse_button(g.vt, notches > 0 ? 4 : 5, true, mods());
			vterm_mouse_button(g.vt, notches > 0 ? 4 : 5, false, mods());
		}
		return;
	}
	if (g.altScreen)
	{
		// Full-screen programs without the mouse (less, man): the wheel moves through them.
		for (int i = 0; i < 3 * std::abs(notches); i++)
			vterm_keyboard_key(g.vt, notches > 0 ? VTERM_KEY_UP : VTERM_KEY_DOWN, VTERM_MOD_NONE);
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
		if (num(1))
			key_down(evdev, w.size() >= 4 ? uint32_t(strtoul(w[3].c_str(), nullptr, 10)) : 0,
			         w.size() >= 5 ? unb64(w[4]) : std::string());
		else
			g.held.erase(evdev);
	}
	else if (cmd == "text" && w.size() >= 2 && g.pty >= 0)
	{
		// Composed text that came without a key.
		for (char32_t c : QString::fromStdString(unb64(w[1])).toUcs4())
			vterm_keyboard_unichar(g.vt, uint32_t(c), VTERM_MOD_NONE);
	}
	else if (cmd == "mouse" && w.size() >= 3)
		mouse_move(int(num(1)), int(num(2)));
	else if (cmd == "button" && w.size() >= 5)
		mouse_button(int(num(1)), num(2) != 0, int(num(3)), int(num(4)));
	else if (cmd == "wheel" && w.size() >= 5)
		wheel(num(1), int(num(3)), int(num(4)));
	else if (cmd == "clip" && w.size() >= 2)
		g.localClip = unb64(w[1]);
	else if (cmd == "disconnect")
		g.quit = 1;
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
	g.held.clear();
}

// The last lines the program left on the screen: why ssh gave up, when it did.
static std::string last_words()
{
	std::vector<std::string> lines;
	for (int row = 0; row < g.rows; row++)
	{
		std::string text;
		for (int col = 0; col < g.cols; col++)
		{
			VTermScreenCell c;
			if (!vterm_screen_get_cell(g.screen, VTermPos{ row, col }, &c) || c.chars[0] == uint32_t(-1))
				continue;
			text += c.chars[0] ? QString::fromUcs4(reinterpret_cast<const char32_t*>(&c.chars[0]), 1).toStdString() : " ";
		}
		while (!text.empty() && text.back() == ' ')
			text.pop_back();
		if (!text.empty())
			lines.push_back(text);
	}
	return lines.empty() ? std::string() : lines.back();
}

int main(int argc, char** argv)
{
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
	g.historyMax = size_t(std::max(0L, strtol(g.get("scrollback", "10000").c_str(), nullptr, 10)));

	if (!g.link.listen(getenv("OMAREMOTE_SOCKET")))
		return 136;
	g.link.onAttach = replay;

	g.vt = vterm_new(g.rows, g.cols);
	vterm_set_utf8(g.vt, 1);
	vterm_output_set_callback(g.vt, cb_output, nullptr);
	g.screen = vterm_obtain_screen(g.vt);
	static VTermScreenCallbacks callbacks = {};
	callbacks.damage = cb_damage;
	callbacks.movecursor = cb_movecursor;
	callbacks.settermprop = cb_settermprop;
	callbacks.sb_pushline = cb_sb_pushline;
	callbacks.sb_popline = cb_sb_popline;
	callbacks.sb_clear = cb_sb_clear;
	vterm_screen_set_callbacks(g.screen, &callbacks, nullptr);
	vterm_screen_enable_altscreen(g.screen, 1);
	vterm_screen_enable_reflow(g.screen, true);
	static VTermSelectionCallbacks selection = {};
	selection.set = cb_selection_set;
	static char selectionBuffer[4096];
	vterm_state_set_selection_callbacks(vterm_obtain_state(g.vt), &selection, nullptr, selectionBuffer,
	                                    sizeof(selectionBuffer));
	vterm_screen_reset(g.screen, 1);
	load_theme();
	check_theme();

	// A size to start with; the UI sends the tab's as soon as it attaches.
	resize(1280, 800, 100);

	winsize ws = {};
	ws.ws_row = uint16_t(g.rows);
	ws.ws_col = uint16_t(g.cols);
	g.child = forkpty(&g.pty, nullptr, nullptr, &ws);
	if (g.child < 0)
	{
		log("cannot start a terminal: %s", strerror(errno));
		g.link.send("state failed 1");
		g.link.close();
		return 1;
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
	// The terminal is up: the user answers ssh's questions (host key, password) in it.
	// The supervisor reads this line as "connected".
	log("connected to %s", g.get("host", args.back().c_str()).c_str());
	g.link.send("state connected");
	send_cursor_shape();

	uint64_t lastThemeCheck = 0;
	char buf[65536];
	bool ended = false;
	while (!g.quit && !ended)
	{
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
					vterm_input_write(g.vt, buf, size_t(got));
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
	if (g.quit && !ended)
	{
		kill(g.child, SIGHUP);
		rc = 11;
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
	// ssh exits 255 when the connection failed; what it said is on the screen.
	if (rc == 255)
		log("connection failed: %s", last_words().c_str());
	log("session ended (%d)", rc);
	g.link.send(std::string(rc == 255 ? "state failed " : "state ended ") + std::to_string(rc));
	g.link.close();
	close(g.pty);
	return rc;
}
