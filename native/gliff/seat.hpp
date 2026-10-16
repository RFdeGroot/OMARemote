#pragma once

// This machine's seat, on a Wayland connection of the session process's own (no window):
// - the keyboard's keymap, for Gliff's Hello and Keymap messages, so every key means on the remote
//   what it means here (as Gliff's own client does, hypr-input's keymap_watch.rs);
// - the clipboard, through ext-data-control: the local selection's mime types and data, and a
//   selection of our own that stands for the remote's, its data fetched only when pasted.

#include <functional>
#include <string>
#include <vector>

struct wl_display;
struct wl_registry;
struct wl_seat;
struct wl_keyboard;
struct ext_data_control_manager_v1;
struct ext_data_control_device_v1;
struct ext_data_control_offer_v1;
struct ext_data_control_source_v1;

namespace gliff
{

class Seat
{
  public:
	~Seat();
	// Connects and waits briefly for the first keymap and selection. False without a Wayland
	// session (the server then uses the remote's own layout, and there is no clipboard).
	bool start();
	int fd() const;  // for poll(): -1 when not connected
	void flush();    // before every poll()
	void dispatch(); // when poll() says fd() is readable

	// ---- keymap
	const std::string& keymap() const { return m_keymap; }
	std::function<void()> onKeymap; // the keymap changed

	// ---- clipboard
	bool hasClipboard() const { return m_device != nullptr; }
	// The local selection's mime types; empty when there is none, or it is ours.
	const std::vector<std::string>& selectionMimes() const { return m_selMimes; }
	std::function<void()> onSelection; // someone else's selection replaced the local one
	// A pipe's read end that the selection's owner writes mime's data into; -1 on failure.
	int receive(const std::string& mime);
	// Puts a selection of ours on the clipboard, offering mimes; each paste comes to onPaste with
	// the mime and a descriptor to write into (ours to close).
	void setSelection(const std::vector<std::string>& mimes);
	void clearOwn(); // our selection goes, if it is still the clipboard's
	bool ownsSelection() const { return m_source != nullptr; }
	std::function<void(const std::string& mime, int fd)> onPaste;

	// Reached from the Wayland listeners.
	void gotSeat(wl_registry* registry, unsigned name, unsigned version);
	void gotManager(wl_registry* registry, unsigned name);
	void gotCapabilities(unsigned caps);
	void gotKeymap(int fd, unsigned format, unsigned size);
	void gotOffer(ext_data_control_offer_v1* offer);
	void gotOfferMime(ext_data_control_offer_v1* offer, const char* mime);
	void gotSelection(ext_data_control_offer_v1* offer);
	void gotPrimary(ext_data_control_offer_v1* offer);
	void gotSend(ext_data_control_source_v1* source, const char* mime, int fd);
	void gotCancelled(ext_data_control_source_v1* source);

  private:
	void stop();
	void makeDevice();

	wl_display* m_display = nullptr;
	wl_registry* m_registry = nullptr;
	wl_seat* m_seat = nullptr;
	wl_keyboard* m_keyboard = nullptr;
	ext_data_control_manager_v1* m_manager = nullptr;
	ext_data_control_device_v1* m_device = nullptr;
	std::string m_keymap;

	// Offers the device announced, with their mime types, until a selection takes one of them.
	struct Pending
	{
		ext_data_control_offer_v1* offer;
		std::vector<std::string> mimes;
	};
	std::vector<Pending> m_pending;
	ext_data_control_offer_v1* m_selection = nullptr;
	std::vector<std::string> m_selMimes;
	ext_data_control_source_v1* m_source = nullptr;
};

} // namespace gliff
