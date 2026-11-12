#pragma once

// Monitor list for a mirrored Gliff tab.
//
// hyprctl's JSON is untrusted. parse_monitors accepts one array of at most 8 objects, skips anything
// it does not use, and returns the enabled screen names sorted left to right. nullopt is a rejected
// document; an empty vector is a valid list with nothing enabled.
//
// The probe's remote command is one fixed argv word. ssh joins the remote command with spaces and
// does not add quotes, so the login shell must see the quotes already in that single word. Nothing
// from the connection is interpolated into it.

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace gliff {

inline constexpr size_t kMonitorProbeMaxBytes = 65536;
inline constexpr int kMonitorMax = 8;

inline constexpr char kMonitorProbeRemote[] =
    R"probe(/bin/sh -c 'set -eu; uid=$(/usr/bin/id -u); case $uid in ""|*[!0-9]*) exit 1 ;; esac; test "${#uid}" -le 10; runtime=/run/user/$uid; base=$runtime/hypr; test -d "$base"; test ! -L "$base"; best=; bestm=-1; n=0; for d in "$base"/*; do n=$((n+1)); test "$n" -le 32; if test -d "$d" && test ! -L "$d" && test -S "$d/.socket.sock" && test ! -L "$d/.socket.sock"; then m=$(/usr/bin/stat -c %Y -- "$d") || continue; case $m in ""|*[!0-9]*) continue ;; esac; if test "$bestm" -lt 0 || test "$m" -gt "$bestm"; then bestm=$m; best=$d; fi; fi; done; test -n "$best"; sig=${best##*/}; case $sig in *[!A-Za-z0-9_-]*|"") exit 1 ;; esac; test "${#sig}" -le 128; XDG_RUNTIME_DIR=$runtime; HYPRLAND_INSTANCE_SIGNATURE=$sig; export XDG_RUNTIME_DIR HYPRLAND_INSTANCE_SIGNATURE; exec /usr/bin/hyprctl -j monitors')probe";

inline bool is_digit(unsigned char c)
{
	return c >= '0' && c <= '9';
}

inline bool is_alnum(unsigned char c)
{
	return is_digit(c) || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
}

// GLIFF_OUTPUT_RE: DP-1, HDMI-A-1, eDP-1. One leading alphanumeric, then up to 63 more.
inline bool output_name_ok(const std::string& s)
{
	if (s.empty() || s.size() > 64 || !is_alnum(static_cast<unsigned char>(s[0])))
		return false;
	for (unsigned char c : s)
		if (!(is_alnum(c) || c == '_' || c == '.' || c == '-'))
			return false;
	return true;
}

inline bool host_ok(const std::string& h)
{
	if (h.empty() || h.size() > 253 || h[0] == '-')
		return false;
	for (unsigned char c : h)
		if (!(is_alnum(c) || c == '.' || c == '_' || c == '%' || c == ':' || c == '@' || c == '[' || c == ']' ||
		      c == '-'))
			return false;
	return true;
}

// ssh prefix only: /usr/bin/ssh, options, one "--", then the host and nothing after it.
inline bool probe_prefix_ok(const std::vector<std::string>& args)
{
	if (args.size() < 3 || args.size() > 64 || args[0] != "/usr/bin/ssh")
		return false;
	int dashes = 0;
	size_t dash = 0;
	for (size_t i = 0; i < args.size(); ++i)
	{
		const std::string& a = args[i];
		if (a.empty() || a.size() > 1024)
			return false;
		for (unsigned char c : a)
			if (c < 0x20 || c == 0x7f)
				return false;
		if (a == "--")
		{
			++dashes;
			dash = i;
		}
	}
	return dashes == 1 && dash + 1 == args.size() - 1 && host_ok(args.back());
}

// Replace the value of --output that sits after "--". The current value must already be "auto" or a
// screen name. Never appends a flag.
inline bool replace_output_arg(std::vector<std::string>& args, const std::string& name)
{
	if (!output_name_ok(name))
		return false;
	int dashes = 0;
	size_t dash = 0;
	for (size_t i = 0; i < args.size(); ++i)
		if (args[i] == "--")
		{
			++dashes;
			dash = i;
		}
	if (dashes != 1)
		return false;
	for (size_t i = dash + 1; i < args.size(); ++i)
	{
		if (args[i] != "--output")
			continue;
		if (i + 1 >= args.size())
			return false;
		const std::string& cur = args[i + 1];
		if (cur != "auto" && !output_name_ok(cur))
			return false;
		args[i + 1] = name;
		return true;
	}
	return false;
}

inline bool coord_ok(double v, long& out)
{
	if (!std::isfinite(v) || v < -100000.0 || v > 100000.0)
		return false;
	const long c = std::llround(v);
	if (c < -100000 || c > 100000)
		return false;
	out = c;
	return true;
}

struct MonitorParser
{
	const char* p;
	const char* end;
	int depth = 0;
	int visits = 0;
	bool bad = false;

	struct Row
	{
		std::string name;
		long x = 0;
		long y = 0;
	};

	bool bump()
	{
		if (++visits > 1024)
			bad = true;
		return !bad;
	}

	bool enter()
	{
		if (++depth > 8)
			bad = true;
		return !bad;
	}

	void leave() { --depth; }

	void ws()
	{
		while (!bad && p < end)
		{
			const unsigned char c = static_cast<unsigned char>(*p);
			if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
			{
				++p;
				continue;
			}
			if (c < 0x20 || c == 0x7f)
				bad = true;
			break;
		}
	}

	bool parse_string(std::string* out)
	{
		if (!bump())
			return false;
		if (p >= end || *p != '"')
		{
			bad = true;
			return false;
		}
		++p;
		std::string tmp;
		while (p < end)
		{
			const unsigned char c = static_cast<unsigned char>(*p++);
			if (c == '"')
			{
				if (out)
					*out = std::move(tmp);
				return true;
			}
			if (c == '\\')
			{
				if (p >= end)
				{
					bad = true;
					return false;
				}
				const unsigned char e = static_cast<unsigned char>(*p++);
				if (e == '"' || e == '\\' || e == '/')
					tmp.push_back(static_cast<char>(e));
				else if (e == 'b')
					tmp.push_back('\b');
				else if (e == 'f')
					tmp.push_back('\f');
				else if (e == 'n')
					tmp.push_back('\n');
				else if (e == 'r')
					tmp.push_back('\r');
				else if (e == 't')
					tmp.push_back('\t');
				else if (e == 'u')
				{
					if (p + 4 > end)
					{
						bad = true;
						return false;
					}
					int cp = 0;
					for (int i = 0; i < 4; ++i)
					{
						const unsigned char h = static_cast<unsigned char>(*p++);
						cp <<= 4;
						if (h >= '0' && h <= '9')
							cp += h - '0';
						else if (h >= 'a' && h <= 'f')
							cp += h - 'a' + 10;
						else if (h >= 'A' && h <= 'F')
							cp += h - 'A' + 10;
						else
						{
							bad = true;
							return false;
						}
					}
					if (cp < 0x20 || cp == 0x7f || (cp >= 0xD800 && cp <= 0xDFFF))
					{
						bad = true;
						return false;
					}
					if (cp < 0x80)
						tmp.push_back(static_cast<char>(cp));
					else if (cp < 0x800)
					{
						tmp.push_back(static_cast<char>(0xC0 | (cp >> 6)));
						tmp.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
					}
					else
					{
						tmp.push_back(static_cast<char>(0xE0 | (cp >> 12)));
						tmp.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
						tmp.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
					}
				}
				else
				{
					bad = true;
					return false;
				}
			}
			else if (c < 0x20)
			{
				bad = true;
				return false;
			}
			else
				tmp.push_back(static_cast<char>(c));
			if (tmp.size() > 4096)
			{
				bad = true;
				return false;
			}
		}
		bad = true;
		return false;
	}

	bool parse_number(double* out)
	{
		if (!bump())
			return false;
		const char* start = p;
		if (p < end && *p == '-')
			++p;
		if (p >= end || !is_digit(static_cast<unsigned char>(*p)))
		{
			bad = true;
			return false;
		}
		if (*p == '0' && p + 1 < end && is_digit(static_cast<unsigned char>(p[1])))
		{
			bad = true;
			return false;
		}
		while (p < end && is_digit(static_cast<unsigned char>(*p)))
			++p;
		if (p < end && *p == '.')
		{
			++p;
			if (p >= end || !is_digit(static_cast<unsigned char>(*p)))
			{
				bad = true;
				return false;
			}
			while (p < end && is_digit(static_cast<unsigned char>(*p)))
				++p;
		}
		if (p < end && (*p == 'e' || *p == 'E'))
		{
			++p;
			if (p < end && (*p == '+' || *p == '-'))
				++p;
			if (p >= end || !is_digit(static_cast<unsigned char>(*p)))
			{
				bad = true;
				return false;
			}
			while (p < end && is_digit(static_cast<unsigned char>(*p)))
				++p;
		}
		if (p - start > 64)
		{
			bad = true;
			return false;
		}
		if (!out)
			return true;
		const std::string tok(start, p);
		char* endp = nullptr;
		const double v = std::strtod(tok.c_str(), &endp);
		if (!endp || endp != tok.c_str() + tok.size() || !std::isfinite(v))
		{
			bad = true;
			return false;
		}
		*out = v;
		return true;
	}

	bool lit(const char* s)
	{
		if (!bump())
			return false;
		for (; *s; ++s)
		{
			if (p >= end || *p != *s)
			{
				bad = true;
				return false;
			}
			++p;
		}
		if (p < end)
		{
			const unsigned char c = static_cast<unsigned char>(*p);
			if (is_alnum(c) || c == '_')
			{
				bad = true;
				return false;
			}
		}
		return true;
	}

	bool skip_value();

	bool skip_object()
	{
		if (!enter() || p >= end || *p != '{')
		{
			bad = true;
			return false;
		}
		++p;
		ws();
		if (p < end && *p == '}')
		{
			++p;
			leave();
			return true;
		}
		while (!bad)
		{
			if (!parse_string(nullptr))
				return false;
			ws();
			if (p >= end || *p != ':')
			{
				bad = true;
				return false;
			}
			++p;
			if (!skip_value())
				return false;
			ws();
			if (p < end && *p == ',')
			{
				++p;
				ws();
				continue;
			}
			if (p < end && *p == '}')
			{
				++p;
				leave();
				return true;
			}
			bad = true;
			return false;
		}
		return false;
	}

	bool skip_array()
	{
		if (!enter() || p >= end || *p != '[')
		{
			bad = true;
			return false;
		}
		++p;
		ws();
		if (p < end && *p == ']')
		{
			++p;
			leave();
			return true;
		}
		int n = 0;
		while (!bad)
		{
			if (++n > 64)
			{
				bad = true;
				return false;
			}
			if (!skip_value())
				return false;
			ws();
			if (p < end && *p == ',')
			{
				++p;
				ws();
				continue;
			}
			if (p < end && *p == ']')
			{
				++p;
				leave();
				return true;
			}
			bad = true;
			return false;
		}
		return false;
	}

	bool parse_monitor(Row& row, bool& keep)
	{
		keep = false;
		if (!enter() || p >= end || *p != '{')
		{
			bad = true;
			return false;
		}
		++p;
		ws();
		bool sawName = false, sawX = false, sawY = false, sawDis = false, skip = false, disabled = false;
		std::string name;
		long x = 0, y = 0;
		if (p < end && *p == '}')
		{
			++p;
			leave();
			return true;
		}
		while (!bad)
		{
			ws();
			if (p >= end || *p != '"')
			{
				bad = true;
				return false;
			}
			std::string key;
			if (!parse_string(&key))
				return false;
			ws();
			if (p >= end || *p != ':')
			{
				bad = true;
				return false;
			}
			++p;
			ws();
			if (bad || p >= end)
			{
				bad = true;
				return false;
			}
			if (key == "name" || key == "x" || key == "y" || key == "disabled")
			{
				if (key == "name")
				{
					if (sawName || *p != '"')
					{
						bad = true;
						return false;
					}
					sawName = true;
					if (!parse_string(&name))
						return false;
				}
				else if (key == "disabled")
				{
					if (sawDis || (*p != 't' && *p != 'f'))
					{
						bad = true;
						return false;
					}
					sawDis = true;
					disabled = *p == 't';
					if (!lit(disabled ? "true" : "false"))
						return false;
				}
				else
				{
					const bool isX = key == "x";
					if ((isX ? sawX : sawY) || (*p != '-' && !is_digit(static_cast<unsigned char>(*p))))
					{
						bad = true;
						return false;
					}
					double v = 0;
					if (!parse_number(&v))
						return false;
					long c = 0;
					if (!coord_ok(v, c))
						skip = true;
					else if (isX)
					{
						sawX = true;
						x = c;
					}
					else
					{
						sawY = true;
						y = c;
					}
				}
			}
			else if (!skip_value())
				return false;
			ws();
			if (p < end && *p == ',')
			{
				++p;
				continue;
			}
			if (p < end && *p == '}')
			{
				++p;
				leave();
				break;
			}
			bad = true;
			return false;
		}
		if (bad)
			return false;
		if (!skip && !disabled && output_name_ok(name))
		{
			row.name = std::move(name);
			row.x = x;
			row.y = y;
			keep = true;
		}
		return true;
	}

	std::optional<std::vector<std::string>> parse_top()
	{
		ws();
		if (bad || p >= end || *p != '[')
		{
			bad = true;
			return std::nullopt;
		}
		if (!enter())
			return std::nullopt;
		++p;
		ws();
		std::vector<Row> rows;
		std::set<std::string> seen;
		if (p < end && *p == ']')
			++p;
		else
		{
			int n = 0;
			while (!bad)
			{
				if (++n > kMonitorMax)
				{
					bad = true;
					break;
				}
				ws();
				Row row;
				bool keep = false;
				if (!parse_monitor(row, keep))
					break;
				if (keep && seen.insert(row.name).second)
					rows.push_back(std::move(row));
				ws();
				if (p < end && *p == ',')
				{
					++p;
					continue;
				}
				if (p < end && *p == ']')
				{
					++p;
					break;
				}
				bad = true;
				break;
			}
		}
		leave();
		ws();
		if (bad || p != end)
			return std::nullopt;
		std::sort(rows.begin(), rows.end(), [](const Row& a, const Row& b) {
			if (a.x != b.x)
				return a.x < b.x;
			if (a.y != b.y)
				return a.y < b.y;
			return a.name < b.name;
		});
		std::vector<std::string> names;
		names.reserve(rows.size());
		for (const auto& row : rows)
			names.push_back(row.name);
		return names;
	}
};

inline bool MonitorParser::skip_value()
{
	ws();
	if (bad || p >= end)
	{
		bad = true;
		return false;
	}
	const unsigned char c = static_cast<unsigned char>(*p);
	if (c == '"')
		return parse_string(nullptr);
	if (c == '-' || is_digit(c))
		return parse_number(nullptr);
	if (c == 't')
		return lit("true");
	if (c == 'f')
		return lit("false");
	if (c == 'n')
		return lit("null");
	if (c == '{')
		return skip_object();
	if (c == '[')
		return skip_array();
	bad = true;
	return false;
}

inline std::optional<std::vector<std::string>> parse_monitors(std::string_view in)
{
	if (in.size() > kMonitorProbeMaxBytes || in.find('\0') != std::string_view::npos)
		return std::nullopt;
	MonitorParser parser{ in.data(), in.data() + in.size() };
	return parser.parse_top();
}

} // namespace gliff
