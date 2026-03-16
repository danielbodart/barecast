// C API for ScreenCaptureKit capture (implementation in screen_capture.m)
#ifndef ZEROCAST_SCREEN_CAPTURE_H
#define ZEROCAST_SCREEN_CAPTURE_H

#include <stdint.h>

typedef struct SCCapture SCCapture;

/// Capture result from a single frame.
typedef struct {
    void *pixel_buffer;     // CVPixelBufferRef — caller must release via sc_capture_release_frame()
    uint32_t width;
    uint32_t height;
    int is_new;             // 1 if content changed since last frame
} SCFrameResult;

/// Create a capture session for a specific window (by CGWindowID).
/// Captures the window content only — no title bar, no desktop.
/// Returns NULL on failure (e.g. no Screen Recording permission).
SCCapture *sc_capture_create_window(uint32_t window_id, uint32_t fps);

/// Start capturing. Returns 0 on success.
int sc_capture_start(SCCapture *cap);

/// Get the latest captured frame. The pixel_buffer is retained and must be
/// released by calling sc_capture_release_frame() after encoding is done.
/// Returns 0 on success, non-zero if no frame is available yet.
int sc_capture_get_frame(SCCapture *cap, SCFrameResult *result);

/// Release a pixel buffer obtained from sc_capture_get_frame().
void sc_capture_release_frame(void *pixel_buffer);

/// Stop capturing and release resources.
void sc_capture_destroy(SCCapture *cap);

/// Launch an app, move its window off-screen, and return its window ID.
/// Returns 0 on failure.
uint32_t sc_launch_app_offscreen(const char *app_path, int64_t *out_pid);

/// Resize a window by PID using AXUIElement.
/// Returns 0 on success, non-zero on failure.
int sc_resize_window(int64_t pid, uint32_t width, uint32_t height);

#endif
