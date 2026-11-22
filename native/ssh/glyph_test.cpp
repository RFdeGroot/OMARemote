// ssh-glyph-test: glyph_constraint.hpp against Ghostty's own test cases (src/font/Glyph.zig,
// test "Constraints": JetBrains Mono's metrics at 12 pt, 96 dpi). Prints "ok" or what differs;
// run by tests/test_ssh.py.
#include "glyph_constraint.hpp"

#include <cmath>
#include <cstdio>

using namespace glyphfit;

static int failures = 0;

static void expect(const char* what, const Box& want, const Box& got)
{
	const auto near = [](double a, double b) { return std::fabs(a - b) <= 1e-6 * std::max(1.0, std::fabs(a)); };
	if (near(want.width, got.width) && near(want.height, got.height) && near(want.x, got.x) && near(want.y, got.y))
		return;
	failures++;
	std::printf("%s: want %.6f %.6f %.6f %.6f, got %.6f %.6f %.6f %.6f\n", what, want.width, want.height, want.x,
	            want.y, got.width, got.height, got.x, got.y);
}

static void expect(const char* what, bool ok)
{
	if (!ok)
	{
		failures++;
		std::printf("%s\n", what);
	}
}

int main()
{
	Metrics m;
	m.cellWidth = 10;
	m.cellHeight = 22;
	m.iconHeight = 21.12;
	m.iconHeightSingle = 44.48 / 3.0;
	m.faceWidth = 9.6;
	m.faceHeight = 21.12;
	m.faceY = 0.2;

	// ASCII: no constraint.
	const Box x{ 6.784, 15.28, 1.408, 4.84 };
	expect("x, 1", x, constrain(constraint_for('x'), x, m, 1));
	expect("x, 2", x, constrain(constraint_for('x'), x, m, 2));

	// A symbol: fit.
	Constraint fit;
	fit.known = true;
	fit.size = nerdfont::Fit;
	const Box square{ 10.272, 10.272, 2.864, 5.304 };
	expect("square, 1", Box{ m.faceWidth, m.faceWidth, 0, 5.64 }, constrain(fit, square, m, 1));
	expect("square, 2", square, constrain(fit, square, m, 2));

	// Emoji: cover, centred, padded.
	Constraint emoji;
	emoji.known = true;
	emoji.size = nerdfont::Cover;
	emoji.alignH = emoji.alignV = nerdfont::Center;
	emoji.padLeft = emoji.padRight = 0.025;
	expect("emoji, 2", Box{ 18.72, 18.72, 0.44, 1.4 }, constrain(emoji, Box{ 20, 20, 0.46, 1 }, m, 2));

	// Nerd Font default: nf-cod-lightbulb.
	const Constraint& bulb = constraint_for(0xEA61);
	expect("0xEA61 rule", bulb.known && bulb.size == nerdfont::FitCover1 && bulb.height == nerdfont::IconHeight &&
	                          bulb.alignH == nerdfont::Center1 && bulb.alignV == nerdfont::Center1);
	const Box ea61{ 9.015625, 13.015625, 3.015625, 3.76525 };
	expect("0xEA61, 1", Box{ 7.2125, 10.4125, 0.8125, 5.950695224719102 }, constrain(bulb, ea61, m, 1));
	expect("0xEA61, 2", Box{ ea61.width, ea61.height, 1.015625, 4.7483690308988775 }, constrain(bulb, ea61, m, 2));

	// Nerd Font stretch: nf-ple-flame_thick.
	const Constraint& flame = constraint_for(0xE0C0);
	expect("0xE0C0 rule", flame.known && flame.size == nerdfont::Stretch && flame.height == nerdfont::CellHeight &&
	                          flame.alignH == nerdfont::Start && flame.alignV == nerdfont::Center1);
	const Box e0c0{ 16.796875, 16.46875, -0.796875, 1.7109375 };
	expect("0xE0C0, 1", Box{ 10, 22, 0, 0 }, constrain(flame, e0c0, m, 1));
	expect("0xE0C0, 2", Box{ 20, 22, 0, 0 }, constrain(flame, e0c0, m, 2));

	// Room: two cells before a space or an empty cell, one after another icon or before a letter.
	const uint32_t row[] = { 0xF31B, ' ', 0xF015, 'x', 0xF015, 0xF015, 0, 0xE0B0, 0xF015, 0, 'a', 0xF015 };
	const int cols = int(sizeof row / sizeof row[0]);
	const int want[] = { 2, 1, 1, 1, 1, 1, 1, 1, 2, 1, 1, 1 };
	for (int i = 0; i < cols; i++)
		if (constraint_width(row, i, cols, 1) != want[i])
		{
			failures++;
			std::printf("room at %d: want %d, got %d\n", i, want[i], constraint_width(row, i, cols, 1));
		}
	expect("wide character: two cells", constraint_width(row, 3, cols, 2) == 2);

	if (failures == 0)
		std::printf("ok\n");
	return failures ? 1 : 0;
}
