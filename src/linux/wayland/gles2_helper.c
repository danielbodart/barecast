// Extract GL renderbuffer/framebuffer IDs from wlroots internal structs.
// This accesses wlr_gles2_buffer internals — we control the wlroots fork
// so the struct layout is stable for our version (0.17.4).

#define WLR_USE_UNSTABLE
#include <render/gles2.h>
#include <wayland-util.h>
#include "gles2_helper.h"

GLuint gles2_get_buffer_rbo(struct wlr_renderer *renderer, struct wlr_buffer *buffer) {
    struct wlr_gles2_renderer *gles2 = gles2_get_renderer(renderer);
    struct wlr_gles2_buffer *gles2_buf;
    wl_list_for_each(gles2_buf, &gles2->buffers, link) {
        if (gles2_buf->buffer == buffer) {
            return gles2_buf->rbo;
        }
    }
    return 0;
}

GLuint gles2_get_buffer_fbo(struct wlr_renderer *renderer, struct wlr_buffer *buffer) {
    struct wlr_gles2_renderer *gles2 = gles2_get_renderer(renderer);
    struct wlr_gles2_buffer *gles2_buf;
    wl_list_for_each(gles2_buf, &gles2->buffers, link) {
        if (gles2_buf->buffer == buffer) {
            return gles2_buf->fbo;
        }
    }
    return 0;
}
