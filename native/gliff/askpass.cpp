#include "askpass.hpp"

#include "../common/link.hpp"

#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace gliff
{

std::optional<HostKeyQuestion> parse_hostkey_question(const std::string& prompt)
{
	const std::string open = "The authenticity of host '";
	if (prompt.compare(0, open.size(), open) != 0 || prompt.find("continue connecting") == std::string::npos)
		return std::nullopt;
	const size_t start = open.size(), end = prompt.find('\'', start);
	if (end == std::string::npos || end == start || end - start > 512)
		return std::nullopt;
	HostKeyQuestion q;
	q.host = prompt.substr(start, end - start);
	// "ED25519 key fingerprint is SHA256:..." (OpenSSH 9) or "... is: SHA256:..." (OpenSSH 10).
	const size_t fp = prompt.find("key fingerprint is");
	if (fp == std::string::npos)
		return std::nullopt;
	// From the key type before it ("ED25519 key fingerprint is SHA256:...") to the end of the line.
	const size_t lineStart = prompt.rfind('\n', fp);
	const size_t from = lineStart == std::string::npos ? 0 : lineStart + 1;
	const size_t lineEnd = prompt.find('\n', fp);
	q.key = prompt.substr(from, (lineEnd == std::string::npos ? prompt.size() : lineEnd) - from);
	while (!q.key.empty() && (q.key.back() == '.' || q.key.back() == '\r' || q.key.back() == ' '))
		q.key.pop_back();
	if (q.key.size() > 512 || prompt.size() > 8192)
		return std::nullopt;
	const size_t last = prompt.rfind("Are you sure");
	q.details = prompt.substr(0, last == std::string::npos ? prompt.size() : last);
	while (!q.details.empty() && (q.details.back() == '\n' || q.details.back() == ' '))
		q.details.pop_back();
	q.otherKeys = prompt.find("keys of different type are already known") != std::string::npos;
	return q;
}

bool is_askpass() { return getenv("OMAREMOTE_ASKPASS") != nullptr; }

// Not a host-key question: the askpass the user had (a passphrase dialog), or no answer.
static int other_askpass(char** argv)
{
	const char* system = getenv("OMAREMOTE_SYSTEM_ASKPASS");
	if (system && *system && access(system, X_OK) == 0)
	{
		argv[0] = const_cast<char*>(system);
		execv(system, argv);
	}
	return 1;
}

int askpass_main(int argc, char** argv)
{
	const std::string prompt = argc > 1 ? argv[1] : "";
	if (!parse_hostkey_question(prompt))
		return other_askpass(argv);
	const char* path = getenv("OMAREMOTE_ASKPASS");
	sockaddr_un addr = {};
	addr.sun_family = AF_UNIX;
	if (!path || strlen(path) >= sizeof(addr.sun_path))
		return 1;
	strcpy(addr.sun_path, path);
	const int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (fd < 0 || connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0)
		return 1;
	const std::string line = oma::b64(prompt) + "\n";
	if (write(fd, line.data(), line.size()) != ssize_t(line.size()))
		return 1;
	// The user may take a while; the session gives up after five minutes (oma::Link::ask).
	std::string answer;
	char c;
	while (answer.size() < 16 && read(fd, &c, 1) == 1 && c != '\n')
		answer += c;
	close(fd);
	if (answer != "yes")
		return 1;
	fputs("yes\n", stdout);
	return 0;
}

void askpass_env(const std::string& self, const std::string& socketPath)
{
	const char* before = getenv("SSH_ASKPASS");
	setenv("OMAREMOTE_SYSTEM_ASKPASS", before && *before ? before : "/usr/lib/ssh/ssh-askpass", 1);
	setenv("SSH_ASKPASS", self.c_str(), 1);
	setenv("SSH_ASKPASS_REQUIRE", "force", 1);
	setenv("OMAREMOTE_ASKPASS", socketPath.c_str(), 1);
}

std::string hostkey_failure(const std::string& errTail, const std::string& host, bool declined)
{
	if (errTail.find("REMOTE HOST IDENTIFICATION HAS CHANGED") != std::string::npos)
		return "The host key of " + host + " has CHANGED: someone may be intercepting the connection. "
		       "If the machine was reinstalled, remove the old key with ssh-keygen -R " + host + " and connect again";
	if (errTail.find("Host key verification failed") == std::string::npos)
		return "";
	if (declined)
		return "Not connected: the host key of " + host + " was not trusted";
	return host + " is not a known host yet, and its key could not be confirmed here: connect once with ssh " +
	       host + " in a terminal and accept its key";
}

} // namespace gliff
