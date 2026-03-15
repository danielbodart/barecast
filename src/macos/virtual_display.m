// CGVirtualDisplay management — spawns a helper process that creates
// the virtual display and holds it alive.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AppKit/AppKit.h>
#import <stdint.h>
#import <signal.h>
#import <spawn.h>

#include "virtual_display.h"

extern char **environ;

// ── VirtualDisplay struct ───────────────────────────────────────────────

struct VirtualDisplay {
    pid_t helper_pid;
    uint32_t display_id;
    uint32_t width;
    uint32_t height;
    double refresh_rate;
};

// ── Helper path resolution ──────────────────────────────────────────────

static NSString *helperPath(void) {
    // Look for zerocast-vd next to the current executable
    NSString *execPath = [[NSProcessInfo processInfo] arguments][0];
    NSString *execDir = [execPath stringByDeletingLastPathComponent];
    NSString *path = [execDir stringByAppendingPathComponent:@"zerocast-vd"];
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:path]) return path;

    // Fallback: common install locations
    for (NSString *p in @[@"/usr/local/bin/zerocast-vd", @"dist/bin/zerocast-vd"]) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:p]) return p;
    }
    return nil;
}

// ── Public C API ────────────────────────────────────────────────────────

VirtualDisplay *vd_create(uint32_t width, uint32_t height, double refresh_rate) {
    NSString *path = helperPath();
    if (!path) {
        NSLog(@"zerocast-vd helper not found");
        return NULL;
    }

    // Create pipe for reading display ID from helper's stdout
    int pipefd[2];
    if (pipe(pipefd) != 0) return NULL;

    // Build argv
    char widthStr[16], heightStr[16], rateStr[16];
    snprintf(widthStr, sizeof(widthStr), "%u", width);
    snprintf(heightStr, sizeof(heightStr), "%u", height);
    snprintf(rateStr, sizeof(rateStr), "%.0f", refresh_rate);

    const char *helperPathC = [path UTF8String];
    char *argv[] = { (char *)helperPathC, widthStr, heightStr, rateStr, NULL };

    // Set up file actions: redirect stdout to pipe write end
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addclose(&actions, pipefd[0]); // close read end in child
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipefd[1]); // close original write fd

    pid_t pid = 0;
    int err = posix_spawn(&pid, helperPathC, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(pipefd[1]); // close write end in parent

    if (err != 0) {
        NSLog(@"posix_spawn failed: %s", strerror(err));
        close(pipefd[0]);
        return NULL;
    }

    // Read display ID from helper's stdout (with timeout)
    char buf[32] = {0};
    fd_set readfds;
    FD_ZERO(&readfds);
    FD_SET(pipefd[0], &readfds);
    struct timeval timeout = { .tv_sec = 5, .tv_usec = 0 };

    ssize_t n = 0;
    if (select(pipefd[0] + 1, &readfds, NULL, NULL, &timeout) > 0) {
        n = read(pipefd[0], buf, sizeof(buf) - 1);
    }
    close(pipefd[0]);

    if (n <= 0) {
        NSLog(@"Failed to read display ID from helper (pid %d)", pid);
        kill(pid, SIGTERM);
        waitpid(pid, NULL, 0);
        return NULL;
    }

    uint32_t displayID = (uint32_t)atoi(buf);
    if (displayID == 0) {
        NSLog(@"Invalid display ID from helper: %s", buf);
        kill(pid, SIGTERM);
        waitpid(pid, NULL, 0);
        return NULL;
    }

    VirtualDisplay *vd = calloc(1, sizeof(VirtualDisplay));
    if (!vd) {
        kill(pid, SIGTERM);
        waitpid(pid, NULL, 0);
        return NULL;
    }

    vd->helper_pid = pid;
    vd->display_id = displayID;
    vd->width = width;
    vd->height = height;
    vd->refresh_rate = refresh_rate;

    NSLog(@"Virtual display %u created via helper (pid %d)", displayID, pid);
    return vd;
}

uint32_t vd_get_display_id(VirtualDisplay *vd) {
    if (!vd) return 0;
    return vd->display_id;
}

int vd_resize(VirtualDisplay *vd, uint32_t width, uint32_t height) {
    if (!vd) return -1;

    double rate = vd->refresh_rate;

    // Kill old helper
    if (vd->helper_pid > 0) {
        kill(vd->helper_pid, SIGTERM);
        waitpid(vd->helper_pid, NULL, 0);
        vd->helper_pid = 0;
    }

    // Small delay for WindowServer cleanup
    usleep(500000);

    // Recreate via new helper
    VirtualDisplay *new_vd = vd_create(width, height, rate);
    if (!new_vd) return -1;

    vd->helper_pid = new_vd->helper_pid;
    vd->display_id = new_vd->display_id;
    vd->width = width;
    vd->height = height;
    free(new_vd);
    return 0;
}

void vd_destroy(VirtualDisplay *vd) {
    if (!vd) return;
    if (vd->helper_pid > 0) {
        kill(vd->helper_pid, SIGTERM);
        waitpid(vd->helper_pid, NULL, 0);
    }
    free(vd);
}

int64_t vd_launch_app(uint32_t display_id, const char *app_path) {
    @autoreleasepool {
        CGRect displayBounds = CGDisplayBounds(display_id);
        if (CGRectIsEmpty(displayBounds)) {
            NSLog(@"Failed to get bounds for display %u", display_id);
            return -1;
        }

        // Launch the app
        NSURL *appURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:app_path]];
        NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
        config.activates = YES;

        __block pid_t appPID = -1;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);

        [[NSWorkspace sharedWorkspace] openApplicationAtURL:appURL
                                              configuration:config
                                          completionHandler:^(NSRunningApplication *app, NSError *error) {
            if (error) {
                NSLog(@"Failed to launch %s: %@", app_path, error);
            } else if (app) {
                appPID = app.processIdentifier;
            }
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

        if (appPID < 0) return -1;

        NSLog(@"Launched %s (pid %d), waiting for window...", app_path, appPID);

        // Poll for the app's window (up to 5 seconds)
        for (int attempt = 0; attempt < 50; attempt++) {
            usleep(100000);

            CFArrayRef windowList = CGWindowListCopyWindowInfo(
                kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                kCGNullWindowID);
            if (!windowList) continue;

            BOOL found = NO;
            for (CFIndex i = 0; i < CFArrayGetCount(windowList); i++) {
                NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(windowList, i);
                NSNumber *ownerPID = info[(NSString *)kCGWindowOwnerPID];
                NSNumber *windowLayer = info[(NSString *)kCGWindowLayer];

                if (ownerPID && ownerPID.intValue == appPID &&
                    windowLayer && windowLayer.intValue == 0) {
                    found = YES;
                    break;
                }
            }
            CFRelease(windowList);
            if (found) break;
        }

        // Move window to virtual display using AXUIElement
        AXUIElementRef appElement = AXUIElementCreateApplication(appPID);
        if (appElement) {
            CFArrayRef windows = NULL;
            AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute, (CFTypeRef *)&windows);
            if (windows && CFArrayGetCount(windows) > 0) {
                AXUIElementRef window = (AXUIElementRef)CFArrayGetValueAtIndex(windows, 0);

                CGPoint pos = displayBounds.origin;
                AXValueRef posValue = AXValueCreate(kAXValueCGPointType, &pos);
                AXUIElementSetAttributeValue(window, kAXPositionAttribute, posValue);
                CFRelease(posValue);

                CGSize size = CGSizeMake(displayBounds.size.width, displayBounds.size.height);
                AXValueRef sizeValue = AXValueCreate(kAXValueCGSizeType, &size);
                AXUIElementSetAttributeValue(window, kAXSizeAttribute, sizeValue);
                CFRelease(sizeValue);

                NSLog(@"Window moved to virtual display at (%.0f, %.0f)", pos.x, pos.y);

                CFRelease(windows);
            }
            CFRelease(appElement);
        }

        return (int64_t)appPID;
    }
}
