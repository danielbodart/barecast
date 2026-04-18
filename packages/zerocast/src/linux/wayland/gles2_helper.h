#ifndef GLES2_HELPER_H
#define GLES2_HELPER_H

#include <GLES2/gl2.h>

struct wlr_renderer;
struct wlr_buffer;

/// Get the GL renderbuffer ID for a buffer that was rendered into by the
/// GLES2 renderer. Returns 0 if the buffer has no associated renderbuffer.
GLuint gles2_get_buffer_rbo(struct wlr_renderer *renderer, struct wlr_buffer *buffer);

/// Get the GL framebuffer object ID for a buffer rendered by the GLES2 renderer.
GLuint gles2_get_buffer_fbo(struct wlr_renderer *renderer, struct wlr_buffer *buffer);

#endif
