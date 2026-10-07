#include "link.hpp"

#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <map>
#include <sstream>

#include <fcntl.h>
#include <poll.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

namespace oma
{

// ---------------------------------------------------------------- helpers

static const char kAlphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

std::string b64(const std::string& s)
{
	if (s.empty())
		return "-";
	std::string out;
	out.reserve((s.size() + 2) / 3 * 4);
	size_t i = 0;
	for (; i + 2 < s.size(); i += 3)
	{
		const uint32_t v = (uint8_t(s[i]) << 16) | (uint8_t(s[i + 1]) << 8) | uint8_t(s[i + 2]);
		out += kAlphabet[(v >> 18) & 63];
		out += kAlphabet[(v >> 12) & 63];
		out += kAlphabet[(v >> 6) & 63];
		out += kAlphabet[v & 63];
	}
	if (i < s.size())
	{
		uint32_t v = uint8_t(s[i]) << 16;
		if (i + 1 < s.size())
			v |= uint8_t(s[i + 1]) << 8;
		out += kAlphabet[(v >> 18) & 63];
		out += kAlphabet[(v >> 12) & 63];
		out += i + 1 < s.size() ? kAlphabet[(v >> 6) & 63] : '=';
		out += '=';
	}
	return out;
}

std::string unb64(const std::string& s)
{
	if (s.empty() || s == "-")
		return {};
	std::string out;
	uint32_t buf = 0;
	int bits = 0;
	for (char c : s)
	{
		const char* p = strchr(kAlphabet, c);
		if (!p || c == '\0')
			continue; // '=' padding and stray characters
		buf = (buf << 6) | uint32_t(p - kAlphabet);
		bits += 6;
		if (bits >= 8)
		{
			bits -= 8;
			out += char((buf >> bits) & 0xFF);
		}
	}
	return out;
}

std::vector<std::string> split(const std::string& line)
{
	std::vector<std::string> out;
	std::istringstream in(line);
	std::string word;
	while (in >> word)
		out.push_back(word);
	return out;
}

uint64_t now_ms()
{
	timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return uint64_t(ts.tv_sec) * 1000 + uint64_t(ts.tv_nsec) / 1000000;
}

void log(const char* fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fputs("[omaremote] ", stdout);
	vfprintf(stdout, fmt, ap);
	fputc('\n', stdout);
	fflush(stdout);
	va_end(ap);
}

// ---------------------------------------------------------------- framebuffer

struct Mapping
{
	size_t size;
	int fd;
};
static std::map<void*, Mapping> g_mappings;

Framebuffer fb_alloc(uint32_t width, uint32_t height)
{
	Framebuffer fb;
	const uint32_t stride = width * 4;
	const size_t size = size_t(stride) * height;
	const int fd = memfd_create("omaremote-fb", MFD_CLOEXEC);
	if (fd < 0 || ftruncate(fd, off_t(size)) != 0)
	{
		if (fd >= 0)
			::close(fd);
		return fb;
	}
	void* p = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (p == MAP_FAILED)
	{
		::close(fd);
		return fb;
	}
	g_mappings[p] = { size, fd };
	fb.data = static_cast<uint8_t*>(p);
	fb.fd = fd;
	fb.width = width;
	fb.height = height;
	fb.stride = stride;
	return fb;
}

void fb_release(void* data)
{
	auto it = g_mappings.find(data);
	if (it == g_mappings.end())
		return;
	munmap(data, it->second.size);
	::close(it->second.fd);
	g_mappings.erase(it);
}

// ---------------------------------------------------------------- link

bool Link::listen(const char* path)
{
	if (!path || !*path)
	{
		log("OMAREMOTE_SOCKET is not set");
		return false;
	}
	sockaddr_un addr = {};
	addr.sun_family = AF_UNIX;
	if (strlen(path) >= sizeof(addr.sun_path))
	{
		log("socket path too long: %s", path);
		return false;
	}
	path_ = path;
	strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
	unlink(path);
	listenFd_ = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
	const mode_t old = umask(0077);
	const int rc = listenFd_ < 0 ? -1 : bind(listenFd_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
	umask(old);
	if (rc != 0 || ::listen(listenFd_, 4) != 0)
	{
		log("cannot listen on %s: %s", path, strerror(errno));
		return false;
	}
	return true;
}

void Link::close()
{
	drop();
	if (listenFd_ >= 0)
		::close(listenFd_);
	listenFd_ = -1;
	if (!path_.empty())
		unlink(path_.c_str());
}

void Link::drop()
{
	if (clientFd_ < 0)
		return;
	::close(clientFd_);
	clientFd_ = -1;
	inbuf_.clear();
	if (onClientChanged)
		onClientChanged();
}

void Link::attach(int fd)
{
	if (clientFd_ >= 0)
	{
		log("a new UI attached; detaching the previous one");
		drop();
	}
	timeval tv = { 2, 0 };
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
	clientFd_ = fd;
	if (onClientChanged)
		onClientChanged();
	send("hello 1");
	if (onAttach)
		onAttach();
	if (!pendingPrompt_.empty())
		send(pendingPrompt_);
}

void Link::send(const std::string& text, int fd)
{
	if (clientFd_ < 0)
		return;
	const std::string line = text + "\n";
	size_t off = 0;
	while (off < line.size())
	{
		iovec iov = { const_cast<char*>(line.data()) + off, line.size() - off };
		msghdr msg = {};
		msg.msg_iov = &iov;
		msg.msg_iovlen = 1;
		char cbuf[CMSG_SPACE(sizeof(int))] = {};
		if (fd >= 0 && off == 0)
		{
			msg.msg_control = cbuf;
			msg.msg_controllen = sizeof(cbuf);
			cmsghdr* c = CMSG_FIRSTHDR(&msg);
			c->cmsg_level = SOL_SOCKET;
			c->cmsg_type = SCM_RIGHTS;
			c->cmsg_len = CMSG_LEN(sizeof(int));
			memcpy(CMSG_DATA(c), &fd, sizeof(int));
		}
		const ssize_t n = sendmsg(clientFd_, &msg, MSG_NOSIGNAL);
		if (n < 0)
		{
			if (errno == EINTR)
				continue;
			log("UI stopped reading (%s); detaching it", strerror(errno));
			drop();
			return;
		}
		off += size_t(n);
	}
}

void Link::sendFrame(const Framebuffer& fb)
{
	if (fb.data && fb.fd >= 0)
		send("frame " + std::to_string(fb.width) + " " + std::to_string(fb.height) + " " + std::to_string(fb.stride),
		     fb.fd);
}

std::vector<std::string> Link::poll()
{
	std::vector<std::string> lines;
	if (listenFd_ >= 0)
	{
		for (;;)
		{
			const int fd = accept4(listenFd_, nullptr, nullptr, SOCK_CLOEXEC);
			if (fd < 0)
				break;
			attach(fd);
		}
	}
	if (clientFd_ < 0)
		return lines;
	char buf[65536];
	for (;;)
	{
		const ssize_t n = recv(clientFd_, buf, sizeof(buf), MSG_DONTWAIT);
		if (n > 0)
		{
			inbuf_.append(buf, size_t(n));
			continue;
		}
		if (n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR))
		{
			log("UI detached");
			drop();
		}
		break;
	}
	size_t pos;
	while ((pos = inbuf_.find('\n')) != std::string::npos)
	{
		lines.push_back(inbuf_.substr(0, pos));
		inbuf_.erase(0, pos + 1);
	}
	return lines;
}

std::string Link::ask(const std::string& question, const std::string& answerPrefix,
                      const std::function<void(const std::string&)>& onLine, const std::function<bool()>& stop)
{
	pendingPrompt_ = question;
	send(question);
	const uint64_t deadline = now_ms() + 5 * 60 * 1000;
	std::string answer;
	while (answer.empty() && !stop() && now_ms() < deadline)
	{
		pollfd fds[2] = { { listenFd_, POLLIN, 0 }, { clientFd_, POLLIN, 0 } };
		::poll(fds, clientFd_ >= 0 ? 2 : 1, 250);
		for (const auto& line : poll())
		{
			if (line.rfind(answerPrefix, 0) == 0 || line == "cancel")
				answer = line;
			else if (onLine)
				onLine(line);
		}
	}
	pendingPrompt_.clear();
	send("prompt-done");
	return answer == "cancel" ? "" : answer;
}

} // namespace oma
