#include "shortcutinhibit.h"

#include "keyboard-shortcuts-inhibit-unstable-v1-client-protocol.h"

#include <QGuiApplication>
#include <QWindow>
#include <qpa/qplatformnativeinterface.h>

#include <cstring>

namespace
{

// The compositor's inhibit manager, bound once from the registry on a queue of our own (so Qt's
// event loop never sees the registry), then moved to the default queue Qt dispatches.
zwp_keyboard_shortcuts_inhibit_manager_v1* manager(wl_display* display)
{
	static zwp_keyboard_shortcuts_inhibit_manager_v1* bound = nullptr;
	static bool tried = false;
	if (tried)
		return bound;
	tried = true;
	wl_event_queue* queue = wl_display_create_queue(display);
	wl_display* wrapped = static_cast<wl_display*>(wl_proxy_create_wrapper(display));
	wl_proxy_set_queue(reinterpret_cast<wl_proxy*>(wrapped), queue);
	wl_registry* registry = wl_display_get_registry(wrapped);
	static const wl_registry_listener listener = {
		[](void*, wl_registry* r, uint32_t name, const char* interface, uint32_t) {
			if (!bound && strcmp(interface, zwp_keyboard_shortcuts_inhibit_manager_v1_interface.name) == 0)
				bound = static_cast<zwp_keyboard_shortcuts_inhibit_manager_v1*>(
				    wl_registry_bind(r, name, &zwp_keyboard_shortcuts_inhibit_manager_v1_interface, 1));
		},
		[](void*, wl_registry*, uint32_t) {},
	};
	wl_registry_add_listener(registry, &listener, nullptr);
	wl_display_roundtrip_queue(display, queue);
	if (bound)
		wl_proxy_set_queue(reinterpret_cast<wl_proxy*>(bound), nullptr);
	wl_registry_destroy(registry);
	wl_proxy_wrapper_destroy(wrapped);
	wl_event_queue_destroy(queue);
	return bound;
}

} // namespace

bool ShortcutInhibit::inhibit(QWindow* window)
{
	if (m_inhibitor && m_window == window)
		return true;
	release();
	auto* app = qGuiApp->nativeInterface<QNativeInterface::QWaylandApplication>();
	QPlatformNativeInterface* native = QGuiApplication::platformNativeInterface();
	if (!app || !native || !window)
		return false;
	auto* surface = static_cast<wl_surface*>(native->nativeResourceForWindow("surface", window));
	wl_seat* seat = app->seat();
	zwp_keyboard_shortcuts_inhibit_manager_v1* m = manager(app->display());
	if (!surface || !seat || !m)
		return false;
	m_inhibitor = zwp_keyboard_shortcuts_inhibit_manager_v1_inhibit_shortcuts(m, surface, seat);
	m_window = window;
	wl_display_flush(app->display());
	return m_inhibitor != nullptr;
}

void ShortcutInhibit::release()
{
	if (!m_inhibitor)
		return;
	zwp_keyboard_shortcuts_inhibitor_v1_destroy(m_inhibitor);
	m_inhibitor = nullptr;
	m_window = nullptr;
	if (auto* app = qGuiApp->nativeInterface<QNativeInterface::QWaylandApplication>())
		wl_display_flush(app->display());
}
