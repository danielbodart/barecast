// C API for CGVirtualDisplay (private API, macOS 14+).
// Creates a virtual display in-process for app isolation.
#ifndef ZEROCAST_VIRTUAL_DISPLAY_H
#define ZEROCAST_VIRTUAL_DISPLAY_H

#include <stdint.h>

typedef struct VirtualDisplay VirtualDisplay;

/// Create a virtual display at the given resolution.
/// Spawns a CFRunLoop thread to keep the display alive.
/// Returns NULL on failure (e.g. macOS < 14, API unavailable).
VirtualDisplay *vd_create(uint32_t width, uint32_t height, double refresh_rate);

/// Get the CGDirectDisplayID of the virtual display.
uint32_t vd_get_display_id(VirtualDisplay *vd);

/// Resize the virtual display by switching modes in-place.
/// No teardown — uses applySettings + CGDisplaySetDisplayMode.
/// Returns 0 on success, non-zero on failure.
int vd_resize(VirtualDisplay *vd, uint32_t width, uint32_t height);

/// Destroy the virtual display and free resources.
void vd_destroy(VirtualDisplay *vd);

/// Launch an application by bundle path (e.g. "/System/Applications/Calculator.app")
/// and move its first window onto the given display.
/// Returns the PID of the launched app, or -1 on failure.
/// If out_window_id is non-NULL, writes the CGWindowID of the app's window.
int64_t vd_launch_app(uint32_t display_id, const char *app_path, uint32_t *out_window_id);

#endif
