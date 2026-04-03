// ScreenCaptureKit capture — window-level capture only.
// Delivers just the window content (no title bar, no desktop).

#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreVideo/CoreVideo.h>
#import <AppKit/AppKit.h>
#import <dispatch/dispatch.h>
#import <stdint.h>
#import <os/lock.h>

#include "screen_capture.h"

// ── Frame output delegate ───────────────────────────────────────────────

@interface ZCStreamOutput : NSObject <SCStreamOutput> {
    @public
    CVPixelBufferRef _latestBuffer;
    CVPixelBufferRef _prevBuffer;
    BOOL _hasNew;
    os_unfair_lock _lock;
}
@end

@implementation ZCStreamOutput

- (instancetype)init {
    self = [super init];
    if (self) {
        self->_latestBuffer = NULL;
        self->_prevBuffer = NULL;
        self->_hasNew = NO;
        self->_lock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
               ofType:(SCStreamOutputType)type {
    (void)stream;

    if (type != SCStreamOutputTypeScreen) return;

    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pb) return;

    CVPixelBufferRetain(pb);

    os_unfair_lock_lock(&self->_lock);
    if (self->_prevBuffer) CVPixelBufferRelease(self->_prevBuffer);
    self->_prevBuffer = self->_latestBuffer;
    self->_latestBuffer = pb;
    self->_hasNew = YES;
    os_unfair_lock_unlock(&self->_lock);
}

- (void)dealloc {
    if (self->_latestBuffer) CVPixelBufferRelease(self->_latestBuffer);
    if (self->_prevBuffer) CVPixelBufferRelease(self->_prevBuffer);
}

@end

// ── SCCapture struct ────────────────────────────────────────────────────

struct SCCapture {
    SCStream *stream;
    SCStreamConfiguration *config;
    SCContentFilter *filter;
    ZCStreamOutput *output;
    dispatch_queue_t queue;
    uint32_t fps;
};

// ── Internal: finalize capture setup (shared by window + display) ───────

static SCCapture *finalizeCaptureSetup(SCCapture *cap, SCContentFilter *filter,
                                        uint32_t width, uint32_t height) {
    cap->config = [[SCStreamConfiguration alloc] init];
    cap->config.width = width;
    cap->config.height = height;
    cap->config.minimumFrameInterval = CMTimeMake(1, (int32_t)cap->fps);
    cap->config.pixelFormat = kCVPixelFormatType_32BGRA;
    cap->config.showsCursor = NO;
    cap->config.queueDepth = 3;

    cap->filter = filter;
    cap->stream = [[SCStream alloc] initWithFilter:filter configuration:cap->config delegate:nil];
    cap->output = [[ZCStreamOutput alloc] init];
    cap->queue = dispatch_queue_create("com.zerocast.capture", DISPATCH_QUEUE_SERIAL);

    NSError *addErr = nil;
    [cap->stream addStreamOutput:cap->output type:SCStreamOutputTypeScreen sampleHandlerQueue:cap->queue error:&addErr];
    if (addErr) {
        NSLog(@"addStreamOutput error: %@", addErr);
        sc_capture_destroy(cap);
        return NULL;
    }

    return cap;
}

// ── Internal: get shareable content synchronously ───────────────────────

static SCShareableContent *getShareableContent(void) {
    __block SCShareableContent *content = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *c, NSError *err) {
        if (err) NSLog(@"SCShareableContent error: %@", err);
        if (!err) content = c;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

    return content;
}

// ── Public C API ────────────────────────────────────────────────────────

int sc_check_screen_recording_permission(void) {
    if (CGPreflightScreenCaptureAccess()) {
        return 1;
    }
    // Triggers the system permission dialog
    CGRequestScreenCaptureAccess();
    // Re-check after request (user may have pre-granted)
    return CGPreflightScreenCaptureAccess() ? 1 : 0;
}

SCCapture *sc_capture_create_window(uint32_t window_id, uint32_t fps) {
    SCCapture *cap = calloc(1, sizeof(SCCapture));
    if (!cap) return NULL;
    cap->fps = fps;

    SCShareableContent *content = getShareableContent();
    if (!content) { free(cap); return NULL; }

    // Find the window by ID
    SCWindow *targetWindow = nil;
    for (SCWindow *w in content.windows) {
        if (w.windowID == window_id) {
            targetWindow = w;
            break;
        }
    }

    if (!targetWindow) {
        NSLog(@"Window %u not found in shareable content", window_id);
        free(cap);
        return NULL;
    }

    // Desktop-independent window capture — no title bar, no desktop background
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:targetWindow];

    // Use the window's content size
    CGRect frame = targetWindow.frame;
    uint32_t width = (uint32_t)frame.size.width;
    uint32_t height = (uint32_t)frame.size.height;

    if (width == 0 || height == 0) {
        NSLog(@"Window %u has zero size", window_id);
        free(cap);
        return NULL;
    }

    NSLog(@"Capturing window %u (%ux%u)", window_id, width, height);
    return finalizeCaptureSetup(cap, filter, width, height);
}

int sc_capture_start(SCCapture *cap) {
    if (!cap || !cap->stream) return -1;

    __block int result = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [cap->stream startCaptureWithCompletionHandler:^(NSError *err) {
        if (err) {
            NSLog(@"startCapture error: %@", err);
            result = (int)err.code;
        }
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

    return result;
}

int sc_capture_get_frame(SCCapture *cap, SCFrameResult *result) {
    if (!cap || !cap->output || !result) return -1;

    os_unfair_lock_lock(&cap->output->_lock);

    CVPixelBufferRef pb = cap->output->_latestBuffer;
    if (!pb) {
        os_unfair_lock_unlock(&cap->output->_lock);
        return -1;
    }

    // Retain so it survives callback replacement while the caller encodes.
    CVPixelBufferRetain(pb);

    result->pixel_buffer = (void *)pb;
    result->width = (uint32_t)CVPixelBufferGetWidth(pb);
    result->height = (uint32_t)CVPixelBufferGetHeight(pb);
    result->is_new = cap->output->_hasNew ? 1 : 0;
    cap->output->_hasNew = NO;

    os_unfair_lock_unlock(&cap->output->_lock);
    return 0;
}

void sc_capture_release_frame(void *pixel_buffer) {
    if (pixel_buffer) CVPixelBufferRelease((CVPixelBufferRef)pixel_buffer);
}

void sc_capture_destroy(SCCapture *cap) {
    if (!cap) return;

    if (cap->stream) {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [cap->stream stopCaptureWithCompletionHandler:^(NSError *err) {
            (void)err;
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        cap->stream = nil;
    }

    cap->config = nil;
    cap->filter = nil;
    cap->output = nil;
    cap->queue = nil;
    free(cap);
}

// ── App launcher ────────────────────────────────────────────────────────

uint32_t sc_launch_app_offscreen(const char *app_path, int64_t *out_pid) {
    @autoreleasepool {
        // Launch the app
        NSURL *appURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:app_path]];
        NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
        config.activates = NO; // Don't steal focus

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

        if (appPID < 0) return 0;
        if (out_pid) *out_pid = (int64_t)appPID;

        NSLog(@"Launched %s (pid %d), waiting for window...", app_path, appPID);

        // Poll for the app's window (up to 5 seconds)
        CGWindowID targetWindowID = 0;
        for (int attempt = 0; attempt < 50; attempt++) {
            usleep(100000); // 100ms

            CFArrayRef windowList = CGWindowListCopyWindowInfo(
                kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                kCGNullWindowID);
            if (!windowList) continue;

            for (CFIndex i = 0; i < CFArrayGetCount(windowList); i++) {
                NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(windowList, i);
                NSNumber *ownerPID = info[(NSString *)kCGWindowOwnerPID];
                NSNumber *windowLayer = info[(NSString *)kCGWindowLayer];

                if (ownerPID && ownerPID.intValue == appPID &&
                    windowLayer && windowLayer.intValue == 0) {
                    NSNumber *windowID = info[(NSString *)kCGWindowNumber];
                    if (windowID) {
                        targetWindowID = windowID.unsignedIntValue;
                        break;
                    }
                }
            }
            CFRelease(windowList);
            if (targetWindowID != 0) break;
        }

        if (targetWindowID == 0) {
            NSLog(@"No window found for pid %d after 5s", appPID);
            return 0;
        }

        NSLog(@"Found window %u for pid %d, moving off-screen", targetWindowID, appPID);

        // Move window far off-screen using AXUIElement
        AXUIElementRef appElement = AXUIElementCreateApplication(appPID);
        if (appElement) {
            CFArrayRef windows = NULL;
            AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute, (CFTypeRef *)&windows);
            if (windows && CFArrayGetCount(windows) > 0) {
                AXUIElementRef window = (AXUIElementRef)CFArrayGetValueAtIndex(windows, 0);

                // Move to far off-screen coordinates
                CGPoint pos = CGPointMake(-16000, 0);
                AXValueRef posValue = AXValueCreate(kAXValueCGPointType, &pos);
                AXUIElementSetAttributeValue(window, kAXPositionAttribute, posValue);
                CFRelease(posValue);

                NSLog(@"Window %u moved off-screen", targetWindowID);
                CFRelease(windows);
            }
            CFRelease(appElement);
        }

        return targetWindowID;
    }
}

// ── Window resize ───────────────────────────────────────────────────────

int sc_resize_window(int64_t pid, uint32_t width, uint32_t height) {
    @autoreleasepool {
        AXUIElementRef appElement = AXUIElementCreateApplication((pid_t)pid);
        if (!appElement) return -1;

        CFArrayRef windows = NULL;
        AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute, (CFTypeRef *)&windows);
        if (!windows || CFArrayGetCount(windows) == 0) {
            if (windows) CFRelease(windows);
            CFRelease(appElement);
            return -1;
        }

        AXUIElementRef window = (AXUIElementRef)CFArrayGetValueAtIndex(windows, 0);
        CGSize size = CGSizeMake((CGFloat)width, (CGFloat)height);
        AXValueRef sizeValue = AXValueCreate(kAXValueCGSizeType, &size);
        AXError err = AXUIElementSetAttributeValue(window, kAXSizeAttribute, sizeValue);
        CFRelease(sizeValue);
        CFRelease(windows);
        CFRelease(appElement);

        if (err != kAXErrorSuccess) {
            NSLog(@"AXUIElement resize failed: %d", (int)err);
            return -1;
        }

        NSLog(@"Resized window for pid %lld to %ux%u", (long long)pid, width, height);
        return 0;
    }
}

// ── Window position query ───────────────────────────────────────────────

int sc_get_window_position(int64_t pid, double *out_x, double *out_y) {
    @autoreleasepool {
        AXUIElementRef appElement = AXUIElementCreateApplication((pid_t)pid);
        if (!appElement) return -1;

        CFArrayRef windows = NULL;
        AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute, (CFTypeRef *)&windows);
        if (!windows || CFArrayGetCount(windows) == 0) {
            if (windows) CFRelease(windows);
            CFRelease(appElement);
            return -1;
        }

        AXUIElementRef window = (AXUIElementRef)CFArrayGetValueAtIndex(windows, 0);
        AXValueRef posValue = NULL;
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute, (CFTypeRef *)&posValue);
        if (!posValue) {
            CFRelease(windows);
            CFRelease(appElement);
            return -1;
        }

        CGPoint pos;
        Boolean ok = AXValueGetValue(posValue, kAXValueCGPointType, &pos);
        CFRelease(posValue);
        if (!ok) {
            CFRelease(windows);
            CFRelease(appElement);
            return -1;
        }
        CFRelease(windows);
        CFRelease(appElement);

        if (out_x) *out_x = pos.x;
        if (out_y) *out_y = pos.y;
        return 0;
    }
}
