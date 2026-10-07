#pragma once

// The session side of the link to the UI, shared by every protocol's session process
// (omaremote-rdp, omaremote-vnc). Protocol: native/PROTOCOL.md.
//
// A session listens on a Unix socket (OMAREMOTE_SOCKET); one UI at a time attaches, and a new
// one replaces the old. Lines go both ways; the framebuffer travels as a file descriptor.

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace oma
{

std::string b64(const std::string& s); // "-" for empty, so a field is never missing
std::string unb64(const std::string& s);
std::vector<std::string> split(const std::string& line);
uint64_t now_ms();
void log(const char* fmt, ...) __attribute__((format(printf, 1, 2)));

// A shared-memory framebuffer, 32 bits per pixel, B G R X in memory (Qt's RGB32).
struct Framebuffer
{
	uint8_t* data = nullptr;
	int fd = -1;
	uint32_t width = 0;
	uint32_t height = 0;
	uint32_t stride = 0;
};

// Maps a new framebuffer; nullptr data on failure. The mapping lives until fb_release(data),
// whose signature fits FreeRDP's pfree, so gdi can own it.
Framebuffer fb_alloc(uint32_t width, uint32_t height);
void fb_release(void* data);

class Link
{
  public:
	// Listens on path (mode 0600). False with a log line on failure.
	bool listen(const char* path);
	void close();

	int listenFd() const { return listenFd_; }
	int clientFd() const { return clientFd_; }
	bool attached() const { return clientFd_ >= 0; }

	// One line to the UI, with a file descriptor attached when fd >= 0. A UI that stops reading
	// for two seconds is dropped rather than allowed to stall the session; it can reattach.
	void send(const std::string& line, int fd = -1);
	void sendFrame(const Framebuffer& fb);

	// Accepts a waiting UI (running onAttach) and returns the complete lines sent so far.
	std::vector<std::string> poll();

	// Asks the UI something and blocks until a line starting with answerPrefix (or "cancel")
	// arrives, handing every other line to onLine. Gives up after five minutes, or when stop()
	// says so. Returns the answer, or "" when cancelled or given up. The question is replayed to
	// a UI that attaches while it waits.
	std::string ask(const std::string& question, const std::string& answerPrefix,
	                const std::function<void(const std::string&)>& onLine, const std::function<bool()>& stop);

	// After "hello" goes to a newly attached UI: replay whatever state it needs.
	std::function<void()> onAttach;
	// When the attached client changes (attach or drop), for loops that wait on its descriptor.
	std::function<void()> onClientChanged;

  private:
	void attach(int fd);
	void drop();

	std::string path_;
	int listenFd_ = -1;
	int clientFd_ = -1;
	std::string inbuf_;
	std::string pendingPrompt_;
};

} // namespace oma
