#include "seat.hpp"

#include "ext-data-control-v1-client-protocol.h"

#include <wayland-client.h>

#include <fcntl.h>
#include <unistd.h>

#include <algorithm>
#include <cstring>

namespace gliff
{

namespace
{

// Larger is no keymap (the biggest layouts are well under this, and a Gliff message body is at
// most 1 MiB).
constexpr unsigned MAX_KEYMAP = 900 * 1024;
// Mime types a selection may list before the rest are ignored.
constexpr size_t MAX_MIMES = 64;
// Our own selection carries this, so its echo is told from a copy made here (as gliff-server
// marks its own with application/x-hypr-input-source). Never offered to the remote.
constexpr const char* OWN_MARK = "application/x-omaremote-gliff";

Seat* self(void* data)
{
	return static_cast<Seat*>(data);
}

const wl_keyboard_listener keyboardListener = {
	[](void* d, wl_keyboard*, uint32_t format, int32_t fd, uint32_t size) { self(d)->gotKeymap(fd, format, size); },
	[](void*, wl_keyboard*, uint32_t, wl_surface*, wl_array*) {},
	[](void*, wl_keyboard*, uint32_t, wl_surface*) {},
	[](void*, wl_keyboard*, uint32_t, uint32_t, uint32_t, uint32_t) {},
	[](void*, wl_keyboard*, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t) {},
	[](void*, wl_keyboard*, int32_t, int32_t) {},
};

const wl_seat_listener seatListener = {
	[](void* d, wl_seat*, uint32_t caps) { self(d)->gotCapabilities(caps); },
	[](void*, wl_seat*, const char*) {},
};

const ext_data_control_offer_v1_listener offerListener = {
	[](void* d, ext_data_control_offer_v1* o, const char* mime) { self(d)->gotOfferMime(o, mime); },
};

const ext_data_control_device_v1_listener deviceListener = {
	[](void* d, ext_data_control_device_v1*, ext_data_control_offer_v1* o) { self(d)->gotOffer(o); },
	[](void* d, ext_data_control_device_v1*, ext_data_control_offer_v1* o) { self(d)->gotSelection(o); },
	[](void*, ext_data_control_device_v1*) {}, // finished: the seat went away
	[](void* d, ext_data_control_device_v1*, ext_data_control_offer_v1* o) { self(d)->gotPrimary(o); },
};

const ext_data_control_source_v1_listener sourceListener = {
	[](void* d, ext_data_control_source_v1* s, const char* mime, int32_t fd) { self(d)->gotSend(s, mime, fd); },
	[](void* d, ext_data_control_source_v1* s) { self(d)->gotCancelled(s); },
};

const wl_registry_listener registryListener = {
	[](void* d, wl_registry* r, uint32_t name, const char* interface, uint32_t version) {
		if (strcmp(interface, wl_seat_interface.name) == 0)
			self(d)->gotSeat(r, name, version);
		else if (strcmp(interface, ext_data_control_manager_v1_interface.name) == 0)
			self(d)->gotManager(r, name);
	},
	[](void*, wl_registry*, uint32_t) {},
};

} // namespace

Seat::~Seat()
{
	stop();
}

bool Seat::start()
{
	m_display = wl_display_connect(nullptr);
	if (!m_display)
		return false;
	m_registry = wl_display_get_registry(m_display);
	wl_registry_add_listener(m_registry, &registryListener, this);
	// The registry; the seat's capabilities and the data device; the keymap and selection.
	for (int i = 0; i < 3; i++)
		if (wl_display_roundtrip(m_display) < 0)
		{
			stop();
			return false;
		}
	return true;
}

void Seat::stop()
{
	clearOwn();
	for (auto& p : m_pending)
		ext_data_control_offer_v1_destroy(p.offer);
	m_pending.clear();
	if (m_selection)
		ext_data_control_offer_v1_destroy(m_selection);
	m_selection = nullptr;
	m_selMimes.clear();
	if (m_device)
		ext_data_control_device_v1_destroy(m_device);
	if (m_manager)
		ext_data_control_manager_v1_destroy(m_manager);
	if (m_keyboard)
		wl_keyboard_destroy(m_keyboard);
	if (m_seat)
		wl_seat_destroy(m_seat);
	if (m_registry)
		wl_registry_destroy(m_registry);
	if (m_display)
		wl_display_disconnect(m_display);
	m_device = nullptr;
	m_manager = nullptr;
	m_keyboard = nullptr;
	m_seat = nullptr;
	m_registry = nullptr;
	m_display = nullptr;
}

int Seat::fd() const
{
	return m_display ? wl_display_get_fd(m_display) : -1;
}

void Seat::flush()
{
	if (m_display)
		wl_display_flush(m_display);
}

void Seat::dispatch()
{
	if (m_display && wl_display_dispatch(m_display) < 0)
		stop(); // the compositor went away: the last keymap stays
}

// ---------------------------------------------------------------- keymap

void Seat::gotSeat(wl_registry* registry, unsigned name, unsigned version)
{
	if (m_seat)
		return; // the first seat: Hyprland has one
	m_seat = static_cast<wl_seat*>(wl_registry_bind(registry, name, &wl_seat_interface, std::min(version, 5u)));
	wl_seat_add_listener(m_seat, &seatListener, this);
	makeDevice();
}

void Seat::gotManager(wl_registry* registry, unsigned name)
{
	if (m_manager)
		return;
	m_manager = static_cast<ext_data_control_manager_v1*>(
	    wl_registry_bind(registry, name, &ext_data_control_manager_v1_interface, 1));
	makeDevice();
}

void Seat::makeDevice()
{
	if (!m_seat || !m_manager || m_device)
		return;
	m_device = ext_data_control_manager_v1_get_data_device(m_manager, m_seat);
	ext_data_control_device_v1_add_listener(m_device, &deviceListener, this);
}

void Seat::gotCapabilities(unsigned caps)
{
	if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !m_keyboard)
	{
		m_keyboard = wl_seat_get_keyboard(m_seat);
		wl_keyboard_add_listener(m_keyboard, &keyboardListener, this);
	}
}

void Seat::gotKeymap(int fd, unsigned format, unsigned size)
{
	std::string text;
	if (format == WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 && size > 0 && size <= MAX_KEYMAP)
	{
		// Read without moving the offset: the descriptor may be shared with other clients.
		text.resize(size);
		size_t got = 0;
		while (got < size)
		{
			const ssize_t n = pread(fd, text.data() + got, size - got, off_t(got));
			if (n <= 0)
				break;
			got += size_t(n);
		}
		text.resize(got);
		while (!text.empty() && text.back() == '\0')
			text.pop_back();
	}
	close(fd);
	if (!text.empty() && text != m_keymap)
	{
		const bool first = m_keymap.empty();
		m_keymap = text;
		if (!first && onKeymap)
			onKeymap();
	}
}

// ---------------------------------------------------------------- clipboard: the local selection

void Seat::gotOffer(ext_data_control_offer_v1* offer)
{
	ext_data_control_offer_v1_add_listener(offer, &offerListener, this);
	m_pending.push_back({ offer, {} });
}

void Seat::gotOfferMime(ext_data_control_offer_v1* offer, const char* mime)
{
	for (auto& p : m_pending)
		if (p.offer == offer && p.mimes.size() < MAX_MIMES)
			p.mimes.emplace_back(mime);
}

void Seat::gotSelection(ext_data_control_offer_v1* offer)
{
	if (m_selection)
		ext_data_control_offer_v1_destroy(m_selection);
	m_selection = nullptr;
	m_selMimes.clear();
	// Announced offers that did not become the selection are of no use any more.
	for (auto& p : m_pending)
	{
		if (p.offer == offer)
		{
			m_selection = offer;
			m_selMimes = std::move(p.mimes);
		}
		else
			ext_data_control_offer_v1_destroy(p.offer);
	}
	m_pending.clear();
	if (std::find(m_selMimes.begin(), m_selMimes.end(), OWN_MARK) != m_selMimes.end())
	{
		// Our own selection, coming back: nothing new to tell the remote.
		m_selMimes.clear();
		return;
	}
	if (onSelection)
		onSelection();
}

// The primary selection (text selected, not copied) is not shared: its offer goes at once, and
// only once (it is still on the pending list, which a selection would otherwise clear again).
void Seat::gotPrimary(ext_data_control_offer_v1* offer)
{
	if (!offer)
		return;
	for (auto it = m_pending.begin(); it != m_pending.end(); ++it)
		if (it->offer == offer)
		{
			m_pending.erase(it);
			break;
		}
	ext_data_control_offer_v1_destroy(offer);
}

int Seat::receive(const std::string& mime)
{
	if (!m_selection || std::find(m_selMimes.begin(), m_selMimes.end(), mime) == m_selMimes.end())
		return -1;
	int fds[2];
	if (pipe2(fds, O_CLOEXEC) != 0)
		return -1;
	ext_data_control_offer_v1_receive(m_selection, mime.c_str(), fds[1]);
	close(fds[1]); // the compositor holds its copy for the owner
	wl_display_flush(m_display);
	fcntl(fds[0], F_SETFL, fcntl(fds[0], F_GETFL) | O_NONBLOCK);
	return fds[0];
}

// ---------------------------------------------------------------- clipboard: our selection

void Seat::setSelection(const std::vector<std::string>& mimes)
{
	if (!m_device)
		return;
	// The new one first, then the old one goes: destroying the selection's source first would
	// empty the clipboard in between.
	ext_data_control_source_v1* old = m_source;
	m_source = ext_data_control_manager_v1_create_data_source(m_manager);
	ext_data_control_source_v1_add_listener(m_source, &sourceListener, this);
	for (const auto& m : mimes)
		if (m != OWN_MARK)
			ext_data_control_source_v1_offer(m_source, m.c_str());
	ext_data_control_source_v1_offer(m_source, OWN_MARK);
	ext_data_control_device_v1_set_selection(m_device, m_source);
	if (old)
		ext_data_control_source_v1_destroy(old);
	wl_display_flush(m_display);
}

void Seat::clearOwn()
{
	if (!m_source)
		return;
	ext_data_control_source_v1_destroy(m_source);
	m_source = nullptr;
}

void Seat::gotSend(ext_data_control_source_v1* source, const char* mime, int fd)
{
	if (source != m_source || !onPaste)
	{
		close(fd);
		return;
	}
	fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
	onPaste(mime, fd);
}

void Seat::gotCancelled(ext_data_control_source_v1* source)
{
	// Something else took the clipboard.
	ext_data_control_source_v1_destroy(source);
	if (source == m_source)
		m_source = nullptr;
}

} // namespace gliff
