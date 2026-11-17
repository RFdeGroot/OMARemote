// The session link from two threads at once (oma::Link::send), as RDP sends: damage lines from its
// graphics channel's thread while the main thread sends cursors, which take several writes each.
// Run by tests/test_memory.py; prints FAIL lines, exit 1.

#include "link.hpp"

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <atomic>
#include <cstdio>
#include <vector>
#include <cstdlib>
#include <string>
#include <thread>

static int failures = 0;

static void expect(bool ok, const char* what)
{
	if (!ok)
	{
		printf("FAIL %s\n", what);
		failures++;
	}
}

// A UI attached to link through a socket at path; -1 when it would not attach.
static int attach_ui(oma::Link& link, const std::string& path)
{
	const int ui = socket(AF_UNIX, SOCK_STREAM, 0);
	sockaddr_un addr = {};
	addr.sun_family = AF_UNIX;
	snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", path.c_str());
	if (connect(ui, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0)
		return -1;
	for (int i = 0; i < 100 && !link.attached(); i++)
	{
		link.poll();
		usleep(10000);
	}
	return link.attached() ? ui : -1;
}

// The UI goes away while another thread sends: only the main thread's poll() lets it go, once.
static void ui_leaves_while_sending(const std::string& path)
{
	oma::Link link;
	if (!link.listen(path.c_str()))
		return expect(false, "listen");
	const std::thread::id main = std::this_thread::get_id();
	std::vector<std::thread::id> changed;
	link.onClientChanged = [&] { changed.push_back(std::this_thread::get_id()); };
	const int ui = attach_ui(link, path);
	if (ui < 0)
		return expect(false, "attach");
	changed.clear();
	std::atomic<bool> stop = false;
	const std::string body(300 * 1024, 'f');
	std::thread sender([&] {
		while (!stop)
			link.send("frame-ish " + body);
	});
	usleep(50000);
	close(ui);
	for (int i = 0; i < 300 && link.attached(); i++)
	{
		link.poll();
		usleep(10000);
	}
	stop = true;
	sender.join();
	expect(!link.attached(), "the UI that left is let go");
	expect(changed.size() == 1, "onClientChanged runs once");
	expect(!changed.empty() && changed[0] == main, "on the main thread, not the sending one");
	link.close();
}

int main()
{
	const char* tmp = getenv("TMPDIR");
	std::string dirTemplate = std::string(tmp && *tmp ? tmp : "/tmp") + "/omaremote-link-test-XXXXXX";
	char* dir = dirTemplate.data();
	if (!mkdtemp(dir))
		return 2;
	const std::string path = std::string(dir) + "/s";
	oma::Link link;
	if (!link.listen(path.c_str()))
		return 2;
	const int ui = attach_ui(link, path);
	if (ui < 0)
		return 2;

	constexpr int kCursors = 40, kDamage = 4000;
	const std::string body(300 * 1024, 'c'); // a large cursor's base64
	std::string got;
	std::thread reader([&] {
		char buf[65536];
		ssize_t n;
		while ((n = read(ui, buf, sizeof(buf))) > 0)
			got.append(buf, size_t(n));
	});
	std::thread cursors([&] {
		for (int i = 0; i < kCursors; i++)
			link.send("cursor " + std::to_string(i) + " " + body);
	});
	std::thread damage([&] {
		for (int i = 0; i < kDamage; i++)
			link.send("damage " + std::to_string(i) + " 0 10 10");
	});
	cursors.join();
	damage.join();
	link.close();
	shutdown(ui, SHUT_WR);
	reader.join();
	close(ui);

	int whole = 0, damaged = 0, broken = 0;
	size_t start = 0;
	while (start < got.size())
	{
		size_t end = got.find('\n', start);
		if (end == std::string::npos)
			end = got.size();
		const std::string line = got.substr(start, end - start);
		start = end + 1;
		if (line == "hello 1")
			continue;
		if (line.rfind("cursor ", 0) == 0 && line.size() > body.size() &&
		    line.compare(line.size() - body.size(), body.size(), body) == 0)
			whole++;
		else if (line.rfind("damage ", 0) == 0 && line.size() < 40 && line.compare(line.size() - 8, 8, " 0 10 10") == 0)
			damaged++;
		else
			broken++;
	}
	if (whole != kCursors || damaged != kDamage || broken)
	{
		printf("FAIL lines mixed: %d of %d cursors whole, %d of %d damage lines, %d broken\n", whole, kCursors,
		       damaged, kDamage, broken);
		failures++;
	}
	ui_leaves_while_sending(path);
	unlink(path.c_str());
	rmdir(dir);
	if (!failures)
		printf("ok\n");
	return failures ? 1 : 0;
}
