#pragma once

// ssh's questions, answered in OMARemote. Gliff runs ssh without a terminal, so ssh cannot ask
// whether to trust a host it has never seen and gave up with "Host key verification failed".
// The session process now starts ssh with itself as SSH_ASKPASS (SSH_ASKPASS_REQUIRE=force): run
// that way (OMAREMOTE_ASKPASS set), it passes a host-key question to the session over a socket of
// its own (the session's socket path + ".askpass"), which shows it in the session view, and prints
// "yes" only when the user trusts the key. ssh itself then records it in known_hosts, so
// ~/.ssh/config, aliases and hashing all apply. Any other question (a key's passphrase) goes to the
// askpass that was there before (SSH_ASKPASS, else /usr/lib/ssh/ssh-askpass), as without OMARemote.
// A changed host key is never asked: ssh refuses it, and hostkey_failure says so.

#include <optional>
#include <string>

namespace gliff
{

struct HostKeyQuestion
{
	std::string host; // as ssh names it: "pc.lan (192.168.1.5)"
	std::string key;  // "ED25519 key fingerprint is: SHA256:..." (no colon before OpenSSH 10)
	std::string details; // ssh's whole text but its last line ("Are you sure ...?"), shown as is
	bool otherKeys = false; // "keys of different type are already known for this host": a warning
};

// ssh's "The authenticity of host ... can't be established ... continue connecting?" question.
// Only text that starts with it: a server's keyboard-interactive prompt reaches the askpass too,
// always after "(user@host) ", and must not be able to bring up the Trust dialog.
std::optional<HostKeyQuestion> parse_hostkey_question(const std::string& prompt);

// The askpass process: true when this process was started as one (it then exits with the
// returned code: 0 with the answer printed, 1 for no answer).
bool is_askpass();
int askpass_main(int argc, char** argv);

// The environment ssh gets: SSH_ASKPASS (self), SSH_ASKPASS_REQUIRE, OMAREMOTE_ASKPASS (socket),
// OMAREMOTE_SYSTEM_ASKPASS (the one before). Called in the forked child, before exec.
void askpass_env(const std::string& self, const std::string& socketPath);

// A failure message for ssh's last words about host keys, or "" when they are about something else.
std::string hostkey_failure(const std::string& errTail, const std::string& host, bool declined);

} // namespace gliff
