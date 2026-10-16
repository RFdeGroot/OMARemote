#pragma once

// Keyboard shortcuts inhibit (Wayland's keyboard-shortcuts-inhibit-unstable-v1): while a window
// holds an inhibitor, the compositor hands it every key, Super and Hyprland's own shortcuts
// included. Gliff tabs hold one while the picture has the focus, as Gliff's own client does.

class QWindow;
struct zwp_keyboard_shortcuts_inhibitor_v1;

class ShortcutInhibit
{
  public:
	~ShortcutInhibit() { release(); }

	// Inhibits the compositor's shortcuts for window; false when the compositor offers no
	// inhibitor (or this is not Wayland). Holding one already for the same window is a no-op.
	bool inhibit(QWindow* window);
	void release();
	bool held() const { return m_inhibitor != nullptr; }

  private:
	zwp_keyboard_shortcuts_inhibitor_v1* m_inhibitor = nullptr;
	QWindow* m_window = nullptr;
};
