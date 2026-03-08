// fpscap.c — LD_PRELOAD frame rate cap for OpenGL apps on headless displays.
// Hooks glXSwapBuffers to insert a clock_nanosleep, capping frame rate to $FPS.
// Without hardware vsync (UseDisplayDevice "none"), OpenGL apps spin at 100% CPU.
// This provides software-based frame pacing via wall clock timing.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <time.h>
#include <stdlib.h>

static long target_ns = 33333333; // default 30fps
static int initialized = 0;
static struct timespec last;

static void init(void) {
    if (initialized) return;
    initialized = 1;
    const char *fps = getenv("FPS");
    if (fps) {
        int f = atoi(fps);
        if (f > 0) target_ns = 1000000000L / f;
    }
    clock_gettime(CLOCK_MONOTONIC, &last);
}

void glXSwapBuffers(void *dpy, unsigned long drawable) {
    init();
    static void (*real)(void*, unsigned long) = NULL;
    if (!real) real = dlsym(RTLD_NEXT, "glXSwapBuffers");

    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    long elapsed = (now.tv_sec - last.tv_sec) * 1000000000L + (now.tv_nsec - last.tv_nsec);
    if (elapsed < target_ns) {
        struct timespec rem = { .tv_sec = 0, .tv_nsec = target_ns - elapsed };
        clock_nanosleep(CLOCK_MONOTONIC, 0, &rem, NULL);
    }
    clock_gettime(CLOCK_MONOTONIC, &last);

    real(dpy, drawable);
}
