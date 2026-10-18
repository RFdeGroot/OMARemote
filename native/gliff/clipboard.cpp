#include "clipboard.hpp"

#include "../common/link.hpp"

#include <dirent.h>
#include <fcntl.h>
#include <linux/openat2.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <deque>
#include <filesystem>

namespace fs = std::filesystem;

namespace gliff
{

// ---------------------------------------------------------------- the pure rules

const char* const TEXT_MIMES[5] = { "text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING", "TEXT" };
static const char* const FILE_MIMES[2] = { "text/uri-list", "x-special/gnome-copied-files" };
static const char* const NON_DATA[] = { "TARGETS", "TIMESTAMP", "MULTIPLE", "SAVE_TARGETS", "DELETE",
	                                    "INSERT_PROPERTY", "INSERT_SELECTION" };
// A selection a password manager marks: never shared.
static const char* const PASSWORD_HINT = "x-kde-passwordManagerHint";

bool is_text_mime(const std::string& m)
{
	return std::any_of(std::begin(TEXT_MIMES), std::end(TEXT_MIMES), [&](const char* t) { return m == t; });
}

bool is_file_mime(const std::string& m)
{
	return m == FILE_MIMES[0] || m == FILE_MIMES[1];
}

static std::string trim(const std::string& s)
{
	const size_t a = s.find_first_not_of(" \t\r\n");
	const size_t b = s.find_last_not_of(" \t\r\n");
	return a == std::string::npos ? std::string() : s.substr(a, b - a + 1);
}

std::vector<std::string> forwardable_mimes(const std::vector<std::string>& offered)
{
	std::vector<std::string> out;
	bool text = false;
	for (const auto& raw : offered)
	{
		const std::string m = trim(raw);
		if (m.empty() || is_file_mime(m) || m.find_first_of(" \t\r\n") != std::string::npos ||
		    std::any_of(std::begin(NON_DATA), std::end(NON_DATA), [&](const char* t) { return m == t; }))
			continue;
		if (is_text_mime(m))
		{
			text = true;
			continue;
		}
		if (std::find(out.begin(), out.end(), m) == out.end())
			out.push_back(m);
	}
	if (text)
		out.insert(out.begin(), std::begin(TEXT_MIMES), std::end(TEXT_MIMES));
	return out;
}

std::string resolve_mime(const std::string& requested, const std::vector<std::string>& offered)
{
	if (std::find(offered.begin(), offered.end(), requested) != offered.end())
		return requested;
	if (is_text_mime(requested))
		for (const char* t : TEXT_MIMES)
			if (std::find(offered.begin(), offered.end(), t) != offered.end())
				return t;
	return {};
}

std::vector<std::string> local_mimes_for_offer(const std::vector<std::string>& mimes, bool hasFiles)
{
	std::vector<std::string> out;
	for (const auto& m : mimes)
		if (!is_file_mime(m))
			out.push_back(m);
	if (hasFiles)
		out.insert(out.end(), std::begin(FILE_MIMES), std::end(FILE_MIMES));
	return out;
}

static bool percent_decode(const std::string& s, std::string& out)
{
	out.clear();
	for (size_t i = 0; i < s.size(); i++)
	{
		if (s[i] != '%')
		{
			out += s[i];
			continue;
		}
		if (i + 2 >= s.size() || !isxdigit(static_cast<unsigned char>(s[i + 1])) ||
		    !isxdigit(static_cast<unsigned char>(s[i + 2])))
			return false;
		out += char(std::stoi(s.substr(i + 1, 2), nullptr, 16));
		i += 2;
	}
	return out.find('\0') == std::string::npos;
}

std::vector<std::string> parse_uri_list(const std::string& body)
{
	std::vector<std::string> out;
	size_t start = 0;
	while (start <= body.size())
	{
		size_t nl = body.find('\n', start);
		if (nl == std::string::npos)
			nl = body.size();
		const std::string line = trim(body.substr(start, nl - start));
		start = nl + 1;
		if (line.empty() || line[0] == '#' || line.rfind("file://", 0) != 0)
			continue;
		const std::string rest = line.substr(7);
		const size_t slash = rest.find('/');
		if (slash == std::string::npos)
			continue;
		const std::string host = rest.substr(0, slash);
		if (!host.empty() && host != "localhost")
			continue;
		std::string path;
		if (percent_decode(rest.substr(slash), path))
			out.push_back(path);
	}
	return out;
}

static std::string percent_encode(const std::string& path)
{
	static const char* keep = "/-._~!$&'()*+,;=:@";
	std::string out;
	char hex[4];
	for (unsigned char c : path)
	{
		if (isalnum(c) || strchr(keep, c))
			out += char(c);
		else
		{
			snprintf(hex, sizeof(hex), "%%%02X", c);
			out += hex;
		}
	}
	return out;
}

std::string uri_list(const std::vector<std::string>& paths)
{
	std::string s;
	for (const auto& p : paths)
		s += "file://" + percent_encode(p) + "\r\n";
	return s;
}

std::string gnome_copied_files(const std::vector<std::string>& paths)
{
	std::string s = "copy";
	for (const auto& p : paths)
		s += "\nfile://" + percent_encode(p);
	return s;
}

bool safe_relative_path(const std::string& path)
{
	if (path.empty() || path.find('\0') != std::string::npos || path[0] == '/')
		return false;
	size_t start = 0;
	while (start <= path.size())
	{
		size_t slash = path.find('/', start);
		if (slash == std::string::npos)
			slash = path.size();
		const std::string part = path.substr(start, slash - start);
		if (part.empty() || part == "." || part == "..")
			return false;
		start = slash + 1;
	}
	return true;
}

bool validate_files(const std::vector<ClipboardFile>& files)
{
	if (files.size() > CLIP_MAX_ENTRIES)
		return false;
	size_t pathBytes = 0;
	uint64_t total = 0;
	std::vector<std::string> seen;
	for (const auto& f : files)
	{
		pathBytes += f.path.size();
		if (!safe_relative_path(f.path) || (f.dir && f.size != 0))
			return false;
		seen.push_back(f.path);
		total += f.size;
		if (total > CLIP_MAX_FILES_TOTAL || total < f.size)
			return false;
	}
	if (pathBytes > CLIP_MAX_PATH_BYTES)
		return false;
	std::sort(seen.begin(), seen.end());
	return std::adjacent_find(seen.begin(), seen.end()) == seen.end();
}

// The copied paths, walked through descriptors: each root opened once and kept, every folder
// below it opened from its parent without following symlinks, each file's device and inode noted.
// A paste later opens the file from its root the same way and checks it is the one offered
// (open_offered), so a folder in the path swapped since (another account, in a shared folder)
// never hands the remote a file of ours. Symlinks inside are skipped (no loops); sockets, FIFOs
// and devices too. False when a cap is exceeded or a root is unreadable: then nothing is offered.
bool list_files(const std::vector<std::string>& roots, std::vector<ClipboardFile>& entries,
                std::vector<OfferedFile>& files, std::vector<int>& rootFds)
{
	uint64_t total = 0;
	size_t pathBytes = 0;
	std::function<bool(int, const std::string&, const std::string&, int)> walk =
	    [&](int dirFd, const std::string& rel, const std::string& inRoot, int root) -> bool {
		const int listFd = openat(dirFd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
		DIR* d = listFd < 0 ? nullptr : fdopendir(listFd);
		if (!d)
		{
			if (listFd >= 0)
				close(listFd);
			return false;
		}
		bool ok = true;
		while (dirent* e = readdir(d))
		{
			const std::string name = e->d_name;
			if (name == "." || name == "..")
				continue;
			struct stat st;
			if (fstatat(dirFd, name.c_str(), &st, AT_SYMLINK_NOFOLLOW) != 0)
				continue;
			const bool isDir = S_ISDIR(st.st_mode);
			if (!isDir && !S_ISREG(st.st_mode))
				continue; // symlinks, sockets, devices: nothing to copy
			if (entries.size() >= CLIP_MAX_ENTRIES)
			{
				ok = false;
				break;
			}
			const std::string childRel = rel + "/" + name, childIn = inRoot.empty() ? name : inRoot + "/" + name;
			pathBytes += childRel.size();
			if (pathBytes > CLIP_MAX_PATH_BYTES)
			{
				ok = false; // a tree too deep or too wide: stopped here, not after walking all of it
				break;
			}
			entries.push_back({ childRel, isDir ? 0 : uint64_t(st.st_size), isDir });
			files.push_back({ root, childIn, st.st_dev, st.st_ino });
			if (!isDir)
			{
				total += uint64_t(st.st_size);
				if (total > CLIP_MAX_FILES_TOTAL)
				{
					ok = false;
					break;
				}
				continue;
			}
			const int child = openat(dirFd, name.c_str(), O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
			struct stat cst;
			ok = child >= 0 && fstat(child, &cst) == 0 && cst.st_dev == st.st_dev && cst.st_ino == st.st_ino &&
			     walk(child, childRel, childIn, root);
			if (child >= 0)
				close(child);
			if (!ok)
				break;
		}
		closedir(d);
		return ok;
	};
	for (const auto& r : roots)
	{
		const std::string name = fs::path(r).filename().string();
		// A root is what the user copied: a symlink there is followed, as chosen, now and only now.
		const int fd = name.empty() ? -1 : ::open(r.c_str(), O_PATH | O_CLOEXEC);
		struct stat st;
		if (fd < 0 || fstat(fd, &st) != 0 || (!S_ISDIR(st.st_mode) && !S_ISREG(st.st_mode)) ||
		    entries.size() >= CLIP_MAX_ENTRIES)
		{
			if (fd >= 0)
				close(fd);
			return false;
		}
		const int root = int(rootFds.size());
		rootFds.push_back(fd);
		const bool dir = S_ISDIR(st.st_mode);
		entries.push_back({ name, dir ? 0 : uint64_t(st.st_size), dir });
		files.push_back({ root, "", st.st_dev, st.st_ino });
		if (!dir)
		{
			total += uint64_t(st.st_size);
			if (total > CLIP_MAX_FILES_TOTAL)
				return false;
		}
		else if (!walk(fd, name, "", root))
			return false;
	}
	return validate_files(entries);
}

// A copied file, opened when the remote pastes it: from the root's descriptor, never leaving it
// and following no symlink on the way (openat2), and only when it is still an ordinary file with
// the device and inode the offer saw. A root file is reopened through its own descriptor.
int open_offered(int rootFd, const OfferedFile& f)
{
	int fd;
	if (f.inRoot.empty())
		fd = ::open(("/proc/self/fd/" + std::to_string(rootFd)).c_str(), O_RDONLY | O_CLOEXEC | O_NONBLOCK);
	else
	{
		open_how how {};
		how.flags = O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW;
		how.resolve = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS;
		fd = int(syscall(SYS_openat2, rootFd, f.inRoot.c_str(), &how, sizeof how));
	}
	struct stat st;
	if (fd >= 0 && (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_dev != f.dev || st.st_ino != f.ino))
	{
		close(fd);
		fd = -1;
	}
	return fd;
}

// ---------------------------------------------------------------- transfers

struct Clipboard::Outgoing
{
	int fd = -1;
	bool pipe = true; // a mime from the selection's owner (capped); else a file
	uint64_t size = 0; // a file: the size offered, never more sent
	uint64_t offset = 0;
	std::deque<uint64_t> unacked; // the end of every chunk sent and not yet acked
	uint64_t lastAt = 0;
};

struct Clipboard::Incoming
{
	uint32_t job = 0;
	int fd = -1;
	bool toFile = false;
	uint64_t received = 0, acked = 0, cap = 0;
	bool done = false;
	std::string buf; // received, not yet written
	uint64_t lastAt = 0;
};

struct Clipboard::Paste
{
	std::string mime;
	int fd = -1;        // the pasting application's descriptor
	bool files = false; // a file list: every file into the spool first
	size_t next = 0;    // the next file entry to fetch
	uint32_t transfer = 0;
	std::vector<std::pair<std::string, int>> waiting; // more file-list pastes of the same offer
	uint64_t total = 0, got = 0;
	uint64_t startedAt = 0, shownAt = 0;
	uint32_t serial = 0;
};

struct Clipboard::Writer
{
	std::string buf;
	uint64_t lastAt = 0;
};

Clipboard::Clipboard(Seat& seat, Send send, Ui ui) : m_seat(seat), m_send(std::move(send)), m_ui(std::move(ui))
{
	m_seat.onSelection = [this] { localChanged(); };
	m_seat.onPaste = [this](const std::string& mime, int fd) { paste(mime, fd); };
}

Clipboard::~Clipboard()
{
	clearOffered();
	for (auto& [id, o] : m_out)
		close(o->fd);
	for (auto& [id, i] : m_in)
		close(i->fd);
	for (auto& [job, p] : m_pastes)
	{
		if (p->fd >= 0)
			close(p->fd);
		for (auto& w : p->waiting)
			close(w.second);
	}
	for (auto& [fd, w] : m_writers)
		close(fd);
	if (m_uriFd >= 0)
		close(m_uriFd);
	std::error_code ec;
	if (!m_spool.empty())
		fs::remove_all(m_spool, ec);
	for (auto& r : m_retired)
		fs::remove_all(r.first, ec);
}

uint32_t Clipboard::newId()
{
	const uint32_t id = m_nextId;
	m_nextId += 2;
	return id;
}

// ---------------------------------------------------------------- focus and offers

void Clipboard::setFocused(bool focused)
{
	if (focused == m_focused)
		return;
	m_focused = focused;
	if (!focused || !m_enabled)
		return;
	// Whichever changed last wins: the remote's offer, or this machine's clipboard.
	if (m_haveRemote && !m_remoteApplied && m_remoteAt > m_localChangedAt)
		applyRemote();
	else if (!m_localOffered && !m_seat.ownsSelection())
		offerLocal();
}

void Clipboard::localChanged()
{
	std::string types;
	for (const auto& m : m_seat.selectionMimes())
		types += (types.empty() ? "" : ", ") + m;
	oma::log("clipboard: the local selection changed%s: %s", m_focused ? "" : " (not focused)",
	         types.empty() ? "empty" : types.c_str());
	m_localChangedAt = oma::now_ms();
	m_remoteApplied = false;
	if (!m_enabled)
		return;
	if (m_focused)
		offerLocal();
	else if (m_localOffered)
		withdraw(); // the remote never reads what was copied while it was not looking
}

void Clipboard::offerLocal()
{
	const std::vector<std::string>& mimes = m_seat.selectionMimes();
	if (std::find(mimes.begin(), mimes.end(), PASSWORD_HINT) != mimes.end())
	{
		withdraw();
		return;
	}
	m_localMimes = mimes;
	if (m_uriFd >= 0)
	{
		close(m_uriFd);
		m_uriFd = -1;
	}
	// Files: the URI list is read first, so the offer can name every file and its size.
	for (const char* fm : FILE_MIMES)
		if (std::find(mimes.begin(), mimes.end(), fm) != mimes.end())
		{
			m_uriFd = m_seat.receive(fm);
			m_uriBuf.clear();
			if (m_uriFd >= 0)
				return; // finishLocalOffer once it is read
		}
	finishLocalOffer("");
}

void Clipboard::finishLocalOffer(const std::string& uriList)
{
	clearOffered();
	if (!uriList.empty() && !list_files(parse_uri_list(uriList), m_localFiles, m_offered, m_rootFds))
	{
		oma::log("clipboard: too many or unreadable files to offer");
		clearOffered();
	}
	m_offeredMimes = forwardable_mimes(m_localMimes);
	m_localSerial++;
	m_localOffered = !m_offeredMimes.empty() || !m_localFiles.empty();
	m_send(clipboardOffer(m_localSerial, m_offeredMimes, m_localFiles), {});
	m_offeredAt = oma::now_ms();
	oma::log("clipboard: offered the local selection (%zu types, %zu files, serial %u)", m_offeredMimes.size(),
	         m_localFiles.size(), m_localSerial);
}

// The files of our last offer forgotten, their roots' descriptors closed.
void Clipboard::clearOffered()
{
	for (int fd : m_rootFds)
		close(fd);
	m_rootFds.clear();
	m_offered.clear();
	m_localFiles.clear();
}

void Clipboard::withdraw()
{
	m_localSerial++;
	m_localOffered = false;
	m_offeredMimes.clear();
	clearOffered();
	m_send(clipboardOffer(m_localSerial, {}, {}), {});
	m_offeredAt = oma::now_ms();
	oma::log("clipboard: withdrew the local selection (serial %u)", m_localSerial);
}

void Clipboard::onOffer(const ClipOffer& offer)
{
	// An offer that crossed ours: the server sent it before it took ours, which then replaced
	// that selection on the remote. Ours is what both sides hold.
	if (m_offeredAt && oma::now_ms() - m_offeredAt < 1000)
	{
		oma::log("clipboard: the remote's offer (serial %u) crossed ours; ours stands", offer.serial);
		return;
	}
	m_remote = offer;
	oma::log("clipboard: the remote offers %zu types, %zu files (serial %u)%s", offer.mimes.size(), offer.files.size(),
	         offer.serial, m_focused ? "" : ", applied on focus");
	if (!validate_files(m_remote.files))
	{
		oma::log("clipboard: the remote offered files with unsafe paths; ignored");
		m_remote.files.clear();
	}
	m_haveRemote = !m_remote.mimes.empty() || !m_remote.files.empty();
	m_remoteApplied = false;
	m_remoteAt = oma::now_ms();
	// The old offer's files stay a while: an application handed their paths may still read them.
	if (!m_spool.empty())
		m_retired.push_back({ m_spool, oma::now_ms() + 300000 });
	m_spool.clear();
	m_spooledRoots.clear();
	if (!m_enabled)
		return;
	if (!m_haveRemote)
	{
		m_seat.clearOwn();
		return;
	}
	if (m_focused)
		applyRemote();
}

void Clipboard::applyRemote()
{
	m_seat.setSelection(local_mimes_for_offer(m_remote.mimes, !m_remote.files.empty()));
	oma::log("clipboard: the remote's selection is the local clipboard now");
	m_remoteApplied = true;
	m_localOffered = false; // the clipboard holds the remote's own now
}

// ---------------------------------------------------------------- the remote pastes ours

void Clipboard::onRequest(const ClipRequest& r)
{
	oma::log("clipboard: the remote pastes %s (serial %u, ours %u)", r.isFile ? "a file" : r.mime.c_str(), r.serial,
	         m_localSerial);
	if (!m_enabled || !m_localOffered || r.serial != m_localSerial || (r.id & 1) || m_out.count(r.id))
	{
		m_send(clipboardAbort(r.id), {});
		return;
	}
	if (r.isFile)
	{
		if (r.file >= m_localFiles.size() || m_localFiles[r.file].dir)
		{
			m_send(clipboardAbort(r.id), {});
			return;
		}
		const OfferedFile& f = m_offered[r.file];
		const int fd = open_offered(m_rootFds[size_t(f.root)], f);
		if (fd < 0)
		{
			m_send(clipboardAbort(r.id), {});
			return;
		}
		serve(r.id, fd, false, m_localFiles[r.file].size);
		return;
	}
	if (std::find(m_offeredMimes.begin(), m_offeredMimes.end(), r.mime) == m_offeredMimes.end())
	{
		m_send(clipboardAbort(r.id), {});
		return;
	}
	const int fd = m_seat.receive(resolve_mime(r.mime, m_localMimes));
	if (fd < 0)
	{
		m_send(clipboardAbort(r.id), {});
		return;
	}
	serve(r.id, fd, true, 0);
}

void Clipboard::serve(uint32_t id, int fd, bool pipe, uint64_t total)
{
	auto o = std::make_unique<Outgoing>();
	o->fd = fd;
	o->pipe = pipe;
	o->size = total;
	o->lastAt = oma::now_ms();
	m_out[id] = std::move(o);
}

void Clipboard::onAck(uint32_t id, uint64_t received)
{
	auto it = m_out.find(id);
	if (it == m_out.end())
		return;
	Outgoing& o = *it->second;
	if (received > o.offset)
	{
		endOutgoing(id, true);
		return;
	}
	while (!o.unacked.empty() && o.unacked.front() <= received)
		o.unacked.pop_front();
	o.lastAt = oma::now_ms();
}

void Clipboard::endOutgoing(uint32_t id, bool abort)
{
	auto it = m_out.find(id);
	if (it == m_out.end())
		return;
	close(it->second->fd);
	m_out.erase(it);
	if (abort)
		m_send(clipboardAbort(id), {});
}

// ---------------------------------------------------------------- we paste the remote's

static std::string mime_label(const std::string& mime)
{
	if (is_text_mime(mime) || mime.rfind("text/", 0) == 0)
		return "text";
	if (mime.rfind("image/", 0) == 0)
		return "an image";
	return mime;
}

void Clipboard::paste(const std::string& mime, int fd)
{
	if (!m_haveRemote || !m_enabled)
	{
		close(fd);
		return;
	}
	if (is_file_mime(mime))
	{
		if (m_remote.files.empty())
		{
			close(fd);
			return;
		}
		if (!m_spooledRoots.empty())
		{
			// Fetched already: the list again.
			auto w = std::make_unique<Writer>();
			w->buf = mime == FILE_MIMES[0] ? uri_list(m_spooledRoots) : gnome_copied_files(m_spooledRoots);
			w->lastAt = oma::now_ms();
			m_writers[fd] = std::move(w);
			return;
		}
		for (auto& [job, p] : m_pastes)
			if (p->files && p->serial == m_remote.serial)
			{
				p->waiting.push_back({ mime, fd });
				return;
			}
	}
	else if (std::find(m_remote.mimes.begin(), m_remote.mimes.end(), mime) == m_remote.mimes.end())
	{
		close(fd);
		return;
	}
	auto p = std::make_unique<Paste>();
	p->mime = mime;
	p->fd = fd;
	p->files = is_file_mime(mime);
	p->serial = m_remote.serial;
	p->startedAt = oma::now_ms();
	if (p->files)
		for (const auto& f : m_remote.files)
			p->total += f.size;
	const uint32_t job = m_nextJob++;
	Paste& ref = *p;
	m_pastes[job] = std::move(p);
	if (ref.files)
	{
		if (m_spool.empty())
			m_spool = makeSpool();
		if (m_spool.empty())
		{
			endPaste(job, false, "no clipboard folder");
			return;
		}
		nextFile(ref);
		return;
	}
	const uint32_t id = newId();
	auto in = std::make_unique<Incoming>();
	in->job = job;
	in->fd = fd;
	in->cap = CLIP_MAX_ITEM;
	in->lastAt = oma::now_ms();
	m_in[id] = std::move(in);
	ref.transfer = id;
	ref.fd = -1; // the transfer owns it now
	m_send(clipboardRequest(id, ref.serial, mime), {});
	oma::log("clipboard: pasting %s from the remote (serial %u)", mime.c_str(), ref.serial);
}

// The next entry of a file paste: folders made, a file requested into the spool.
void Clipboard::nextFile(Paste& p)
{
	uint32_t job = 0;
	for (auto& [j, q] : m_pastes)
		if (q.get() == &p)
			job = j;
	while (p.next < m_remote.files.size())
	{
		const ClipboardFile& f = m_remote.files[p.next];
		const fs::path dest = fs::path(m_spool) / f.path;
		std::error_code ec;
		if (f.dir)
		{
			fs::create_directories(dest, ec);
			if (ec)
				return endPaste(job, false, "could not make a folder");
			p.next++;
			continue;
		}
		fs::create_directories(dest.parent_path(), ec);
		const int fd = ec ? -1
		                  : ::open(dest.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0600);
		if (fd < 0)
			return endPaste(job, false, "could not write a file");
		const uint32_t id = newId();
		auto in = std::make_unique<Incoming>();
		in->job = job;
		in->fd = fd;
		in->toFile = true;
		in->cap = f.size;
		in->lastAt = oma::now_ms();
		m_in[id] = std::move(in);
		p.transfer = id;
		m_send(clipboardRequest(id, p.serial, "", int64_t(p.next)), {});
		p.next++;
		return;
	}
	// Every file is in: the pastes get the list of the top-level entries.
	m_spooledRoots.clear();
	for (const auto& f : m_remote.files)
		if (f.path.find('/') == std::string::npos)
			m_spooledRoots.push_back((fs::path(m_spool) / f.path).string());
	auto answer = [&](const std::string& mime, int fd) {
		auto w = std::make_unique<Writer>();
		w->buf = mime == FILE_MIMES[0] ? uri_list(m_spooledRoots) : gnome_copied_files(m_spooledRoots);
		w->lastAt = oma::now_ms();
		m_writers[fd] = std::move(w);
	};
	answer(p.mime, p.fd);
	p.fd = -1;
	for (auto& w : p.waiting)
		answer(w.first, w.second);
	p.waiting.clear();
	endPaste(job, true);
}

void Clipboard::onData(const ClipData& d, const uint8_t* payload)
{
	auto it = m_in.find(d.id);
	if (it == m_in.end())
		return; // finished or aborted already; the server has our Abort
	Incoming& in = *it->second;
	if (in.done || d.offset != in.received || d.len > CLIP_CHUNK || in.received + d.len > in.cap)
	{
		oma::log("clipboard: a transfer broke the rules; aborted");
		endIncoming(d.id, true);
		return;
	}
	in.buf.append(reinterpret_cast<const char*>(payload), d.len);
	in.received += d.len;
	in.done = d.done;
	in.lastAt = oma::now_ms();
	auto p = m_pastes.find(in.job);
	if (p != m_pastes.end())
		p->second->got += d.len;
	flushIncoming(d.id);
}

// Writes what the descriptor takes now (the rest when poll says so), acks what is written, and
// ends the transfer when all of it is.
void Clipboard::flushIncoming(uint32_t id)
{
	auto it = m_in.find(id);
	if (it == m_in.end())
		return;
	Incoming& in = *it->second;
	while (!in.buf.empty())
	{
		const ssize_t n = write(in.fd, in.buf.data(), in.buf.size());
		if (n > 0)
			in.buf.erase(0, size_t(n));
		else if (n < 0 && errno == EINTR)
			continue;
		else if (n < 0 && errno == EAGAIN)
			break;
		else
		{
			endIncoming(id, true); // the pasting application went away, or the disk is full
			return;
		}
	}
	if (in.buf.empty() && in.acked < in.received)
	{
		in.acked = in.received;
		m_send(clipboardAck(id, in.received), {});
	}
	if (in.done && in.buf.empty())
		endIncoming(id, false);
}

void Clipboard::endIncoming(uint32_t id, bool abort)
{
	auto it = m_in.find(id);
	if (it == m_in.end())
		return;
	const uint32_t job = it->second->job;
	const bool ok = !abort && it->second->done && it->second->buf.empty();
	const bool toFile = it->second->toFile;
	close(it->second->fd);
	m_in.erase(it);
	if (abort)
		m_send(clipboardAbort(id), {});
	auto p = m_pastes.find(job);
	if (p == m_pastes.end())
		return;
	if (ok && toFile)
		nextFile(*p->second);
	else
		endPaste(job, ok, ok ? "" : "the transfer failed");
}

void Clipboard::onAbort(uint32_t id)
{
	if (m_out.count(id))
	{
		auto it = m_out.find(id);
		close(it->second->fd);
		m_out.erase(it);
	}
	if (m_in.count(id))
	{
		auto it = m_in.find(id);
		const uint32_t job = it->second->job;
		close(it->second->fd);
		m_in.erase(it);
		endPaste(job, false, "the remote gave up");
	}
}

void Clipboard::endPaste(uint32_t job, bool ok, const std::string& why)
{
	auto it = m_pastes.find(job);
	if (it == m_pastes.end())
		return;
	Paste& p = *it->second;
	if (p.transfer && m_in.count(p.transfer))
	{
		const uint32_t id = p.transfer;
		p.transfer = 0;
		auto in = m_in.find(id);
		close(in->second->fd);
		m_in.erase(in);
		m_send(clipboardAbort(id), {});
	}
	if (p.fd >= 0)
		close(p.fd); // the application sees an empty paste
	for (auto& w : p.waiting)
		close(w.second);
	if (!ok)
		oma::log("clipboard: a paste failed: %s", why.c_str());
	// A file paste that failed leaves part of the files: a new attempt starts in a fresh folder.
	if (!ok && p.files && !m_spool.empty())
	{
		std::error_code ec;
		fs::remove_all(m_spool, ec);
		m_spool.clear();
	}
	if (p.shownAt)
		m_ui("clip-done " + std::to_string(job));
	m_pastes.erase(it);
}

void Clipboard::cancel(uint32_t job)
{
	endPaste(job, false, "cancelled");
}

// ---------------------------------------------------------------- the spool

void Clipboard::sweepSpools()
{
	const char* cache = getenv("XDG_CACHE_HOME");
	const char* home = getenv("HOME");
	const fs::path base = cache && *cache ? fs::path(cache) / "omaremote" / "clipboard"
	                      : home           ? fs::path(home) / ".cache" / "omaremote" / "clipboard"
	                                       : fs::path();
	if (base.empty())
		return;
	std::error_code ec;
	for (const auto& e : fs::directory_iterator(base, ec))
	{
		const std::string name = e.path().filename().string();
		const long pid = strtol(name.c_str(), nullptr, 10);
		if (pid > 0 && pid != getpid() && !fs::exists("/proc/" + std::to_string(pid), ec))
			fs::remove_all(e.path(), ec);
	}
}

// A new folder for one offer's files: ~/.cache/omaremote/clipboard/<pid>-<n>, private (0700),
// on disk rather than the RAM-backed runtime folder, as Gliff does. Spools of sessions that are
// gone are swept first.
std::string Clipboard::makeSpool()
{
	const char* cache = getenv("XDG_CACHE_HOME");
	const char* home = getenv("HOME");
	if (!(cache && *cache) && !home)
		return {};
	const fs::path base = cache && *cache ? fs::path(cache) / "omaremote" / "clipboard"
	                                      : fs::path(home) / ".cache" / "omaremote" / "clipboard";
	std::error_code ec;
	fs::create_directories(base, ec);
	if (ec)
		return {};
	sweepSpools();
	for (int n = 0; n < 100000; n++)
	{
		const fs::path dir = base / (std::to_string(getpid()) + "-" + std::to_string(n));
		if (mkdir(dir.c_str(), 0700) == 0)
			return dir.string();
		if (errno != EEXIST)
			return {};
	}
	return {};
}

// ---------------------------------------------------------------- the poll loop

void Clipboard::addFds(std::vector<pollfd>& fds)
{
	if (m_uriFd >= 0)
		fds.push_back({ m_uriFd, POLLIN, 0 });
	for (auto& [id, o] : m_out)
		if (o->unacked.size() < CLIP_WINDOW)
			fds.push_back({ o->fd, POLLIN, 0 });
	for (auto& [id, in] : m_in)
		if (!in->buf.empty())
			fds.push_back({ in->fd, POLLOUT, 0 });
	for (auto& [fd, w] : m_writers)
		fds.push_back({ fd, POLLOUT, 0 });
}

void Clipboard::handleFds(const std::vector<pollfd>& fds)
{
	for (const pollfd& p : fds)
	{
		if (!p.revents)
			continue;
		// The local URI list, for an offer of files.
		if (p.fd == m_uriFd)
		{
			char buf[65536];
			ssize_t n;
			while ((n = read(m_uriFd, buf, sizeof(buf))) > 0 && m_uriBuf.size() < CLIP_MAX_PATH_BYTES * 4)
				m_uriBuf.append(buf, size_t(n));
			if (n == 0 || (n < 0 && errno != EAGAIN) || m_uriBuf.size() >= CLIP_MAX_PATH_BYTES * 4)
			{
				close(m_uriFd);
				m_uriFd = -1;
				finishLocalOffer(m_uriBuf);
			}
			continue;
		}
		// Ours to the remote: one chunk at a time while the window has room.
		for (auto it = m_out.begin(); it != m_out.end(); ++it)
		{
			Outgoing& o = *it->second;
			if (o.fd != p.fd)
				continue;
			const uint32_t id = it->first;
			std::string chunk(CLIP_CHUNK, '\0');
			const ssize_t n = read(o.fd, chunk.data(), chunk.size());
			if (n < 0 && (errno == EAGAIN || errno == EINTR))
				break;
			if (n < 0 || o.offset + uint64_t(n) > (o.pipe ? CLIP_MAX_ITEM : o.size))
			{
				endOutgoing(id, true);
				break;
			}
			chunk.resize(size_t(n));
			const bool done = n == 0;
			m_send(clipboardData(id, o.offset, uint32_t(n), done), chunk);
			o.offset += uint64_t(n);
			o.unacked.push_back(o.offset);
			o.lastAt = oma::now_ms();
			if (done)
				endOutgoing(id, false);
			break;
		}
		// The remote's into a paste or a spool file.
		for (auto it = m_in.begin(); it != m_in.end(); ++it)
			if (it->second->fd == p.fd)
			{
				flushIncoming(it->first);
				break;
			}
		// A file list for a paste.
		auto w = m_writers.find(p.fd);
		if (w != m_writers.end())
		{
			const ssize_t n = write(p.fd, w->second->buf.data(), w->second->buf.size());
			if (n > 0)
				w->second->buf.erase(0, size_t(n));
			if (w->second->buf.empty() || (n < 0 && errno != EAGAIN && errno != EINTR))
			{
				close(p.fd);
				m_writers.erase(w);
			}
		}
	}
}

void Clipboard::tick()
{
	const uint64_t now = oma::now_ms();
	// A transfer that makes no progress for 30 seconds is given up, as Gliff does.
	std::vector<uint32_t> stale;
	for (auto& [id, o] : m_out)
		if (now - o->lastAt > CLIP_IDLE_MS)
			stale.push_back(id);
	for (uint32_t id : stale)
		endOutgoing(id, true);
	stale.clear();
	for (auto& [id, in] : m_in)
		if (now - in->lastAt > CLIP_IDLE_MS)
			stale.push_back(id);
	for (uint32_t id : stale)
		endIncoming(id, true);
	for (auto it = m_writers.begin(); it != m_writers.end();)
		if (now - it->second->lastAt > CLIP_IDLE_MS)
		{
			close(it->first);
			it = m_writers.erase(it);
		}
		else
			++it;
	// A paste taking more than a second shows its progress, with a cancel button.
	for (auto& [job, p] : m_pastes)
		if (now - p->startedAt > 1000 && now - p->shownAt > 250)
		{
			p->shownAt = now;
			const std::string what = p->files ? std::to_string(std::count_if(m_remote.files.begin(), m_remote.files.end(),
			                                                                 [](const ClipboardFile& f) { return !f.dir; })) +
			                                        " files"
			                                  : mime_label(p->mime);
			m_ui("clip-progress " + std::to_string(job) + " " + std::to_string(p->got) + " " +
			     std::to_string(p->total) + " " + oma::b64(what));
		}
	// Old spools whose grace is over.
	for (auto it = m_retired.begin(); it != m_retired.end();)
		if (now >= it->second)
		{
			std::error_code ec;
			fs::remove_all(it->first, ec);
			it = m_retired.erase(it);
		}
		else
			++it;
}

} // namespace gliff
