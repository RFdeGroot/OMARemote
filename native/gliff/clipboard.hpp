#pragma once

// The clipboard between this machine and the remote, as Gliff's own client shares it
// (crates/gliff-proto/src/clipboard.rs, crates/gliff-transport/src/clipboard):
//
// - Nothing is pushed. A side whose clipboard changed offers its mime types (and files); the other
//   side stands in for that on its own clipboard, and fetches the data only when something there
//   pastes. Data moves in chunks of at most 256 KiB, four in flight before an Ack.
// - Files travel as relative paths and sizes; the pasting side writes them into a private spool
//   folder and pastes a URI list pointing there.
//
// What OMARemote adds: the local clipboard is offered to the remote only while the session's view
// has the focus (as a focused window in Gliff's client is what reads the clipboard), and a local
// change while it does not is withdrawn from the remote at once. The remote's offer becomes the
// local clipboard when the view gets the focus, unless the local clipboard changed since.

#include "msg.hpp"
#include "seat.hpp"

#include <poll.h>
#include <sys/types.h>

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace gliff
{

constexpr size_t CLIP_CHUNK = 256 * 1024;
constexpr unsigned CLIP_WINDOW = 4;
constexpr uint64_t CLIP_MAX_ITEM = 32ull * 1024 * 1024;
constexpr uint64_t CLIP_MAX_FILES_TOTAL = 4ull * 1024 * 1024 * 1024;
constexpr size_t CLIP_MAX_PATH_BYTES = 512 * 1024;
constexpr uint64_t CLIP_IDLE_MS = 30000;

// ---- the pure rules (gliff-proto's), tested in gliff-proto-test

extern const char* const TEXT_MIMES[5];
bool is_text_mime(const std::string& m);
bool is_file_mime(const std::string& m);
std::vector<std::string> forwardable_mimes(const std::vector<std::string>& offered);
std::string resolve_mime(const std::string& requested, const std::vector<std::string>& offered);
std::vector<std::string> local_mimes_for_offer(const std::vector<std::string>& mimes, bool hasFiles);
std::vector<std::string> parse_uri_list(const std::string& body);
std::string uri_list(const std::vector<std::string>& paths);
std::string gnome_copied_files(const std::vector<std::string>& paths);
bool safe_relative_path(const std::string& path);
bool validate_files(const std::vector<ClipboardFile>& files);
// One offered entry, as list_files found it: its root (an index into the root descriptors), the
// path below that root ("" for the root itself), and the file it was then.
struct OfferedFile
{
	int root = 0;
	std::string inRoot;
	dev_t dev = 0;
	ino_t ino = 0;
};
bool list_files(const std::vector<std::string>& roots, std::vector<ClipboardFile>& entries,
                std::vector<OfferedFile>& files, std::vector<int>& rootFds);
int open_offered(int rootFd, const OfferedFile& file);

class Clipboard
{
  public:
	using Send = std::function<void(const std::string& body, const std::string& payload)>;
	using Ui = std::function<void(const std::string& line)>;

	Clipboard(Seat& seat, Send send, Ui ui);
	~Clipboard();

	void setEnabled(bool on) { m_enabled = on && m_seat.hasClipboard(); }
	bool enabled() const { return m_enabled; }
	void setFocused(bool focused);

	// From the server.
	void onOffer(const ClipOffer& offer);
	void onRequest(const ClipRequest& request);
	void onData(const ClipData& data, const uint8_t* payload);
	void onAck(uint32_t id, uint64_t received);
	void onAbort(uint32_t id);

	// From the UI: the cancel button of a slow paste.
	void cancel(uint32_t job);

	// The poll loop: descriptors to watch, then what they said; tick() now and then.
	void addFds(std::vector<pollfd>& fds);
	void handleFds(const std::vector<pollfd>& fds);
	void tick();

  private:
	struct Outgoing; // something of ours the remote pastes
	struct Incoming; // something of the remote's we paste
	struct Paste;    // a local paste of the remote's offer (one item, or all files)
	struct Writer;   // bytes for a paste descriptor, written as it takes them

	void localChanged();
	void offerLocal();
	void finishLocalOffer(const std::string& uriList);
	void withdraw();
	void clearOffered();
	void applyRemote();
	void paste(const std::string& mime, int fd);
	void startPaste(Paste& p);
	void nextFile(Paste& p);
	void endPaste(uint32_t job, bool ok, const std::string& why = "");
	void serve(uint32_t id, int fd, bool pipe, uint64_t total);
	void endOutgoing(uint32_t id, bool abort);
	void endIncoming(uint32_t id, bool abort);
	void flushIncoming(uint32_t id);
	uint32_t newId();
	std::string makeSpool();
	void sweepSpools();

	Seat& m_seat;
	Send m_send;
	Ui m_ui;
	bool m_enabled = false;
	bool m_focused = false;

	// What we offered the remote, and the local selection it stands for.
	uint32_t m_localSerial = 0;
	std::vector<std::string> m_offeredMimes;
	std::vector<std::string> m_localMimes; // the local selection's own mime types
	std::vector<ClipboardFile> m_localFiles;
	std::vector<OfferedFile> m_offered; // one per m_localFiles entry
	std::vector<int> m_rootFds;         // the copied roots, opened once (O_PATH) when offered
	bool m_localOffered = false;
	uint64_t m_localChangedAt = 0;
	uint64_t m_offeredAt = 0; // when our last offer (or withdrawal) went
	int m_uriFd = -1; // reading the local URI list before files can be offered
	std::string m_uriBuf;

	// The remote's offer.
	ClipOffer m_remote;
	bool m_haveRemote = false;
	bool m_remoteApplied = false;
	uint64_t m_remoteAt = 0;
	std::string m_spool;                     // this offer's spool folder, once files came
	std::vector<std::string> m_spooledRoots; // the top-level entries there, after a full fetch
	std::vector<std::pair<std::string, uint64_t>> m_retired; // old spools and when they go

	uint32_t m_nextId = 1; // the client's transfer ids are odd
	uint32_t m_nextJob = 1;
	std::map<uint32_t, std::unique_ptr<Outgoing>> m_out;
	std::map<uint32_t, std::unique_ptr<Incoming>> m_in;
	std::map<uint32_t, std::unique_ptr<Paste>> m_pastes;
	std::map<int, std::unique_ptr<Writer>> m_writers; // by descriptor
};

} // namespace gliff
