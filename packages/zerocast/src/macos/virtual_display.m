// CGVirtualDisplay management — creates and holds a virtual display alive
// in-process using a dedicated thread with its own NSApplication and CFRunLoop.
//
// All WindowServer interactions happen on the display thread to avoid
// conflicts with the main thread (which runs the Zig daemon event loop).

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AppKit/AppKit.h>
#import <stdint.h>
#import <pthread.h>

#include "virtual_display.h"

// ── Private API declarations ────────────────────────────────────────────

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) unsigned int hiDPI;
@property (retain, nonatomic) NSArray *modes;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) CGPoint whitePoint;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (retain, nonatomic) dispatch_queue_t queue;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

// ── Constants ───────────────────────────────────────────────────────────

// Max pixel dimensions for the virtual display descriptor.
// Set high to allow resize without recreating the display.
static const uint32_t MAX_DISPLAY_PIXELS = 7680; // 8K

// ── VirtualDisplay struct ───────────────────────────────────────────────

struct VirtualDisplay {
    CGVirtualDisplay *display;
    CGDirectDisplayID display_id;
    uint32_t width;
    uint32_t height;
    double refresh_rate;
    CFRunLoopRef run_loop;
    dispatch_semaphore_t ready;
    pthread_t thread;
    BOOL create_ok;
};

// ── Internal helpers ────────────────────────────────────────────────────

static BOOL applyMode(CGVirtualDisplay *display, uint32_t width, uint32_t height, double refresh_rate) {
    CGVirtualDisplayMode *mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc]
        initWithWidth:width height:height refreshRate:refresh_rate];
    CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = 0;
    settings.modes = @[mode];
    return [display applySettings:settings];
}

// ── Display thread ─────────────────────────────────────────────────────

static void *displayThread(void *ctx) {
    @autoreleasepool {
        VirtualDisplay *vd = (VirtualDisplay *)ctx;

        // NOTE: We do NOT initialize NSApplication here. It registers a
        // display-change notification handler that asserts [NSThread isMainThread],
        // crashing when CGCompleteDisplayConfiguration fires on this thread.
        // CGVirtualDisplay works without NSApplication — compositor support
        // comes from WindowServer, not from NSApp registration.

        Class cls = NSClassFromString(@"CGVirtualDisplay");
        if (!cls) {
            NSLog(@"CGVirtualDisplay not available (requires macOS 14+)");
            dispatch_semaphore_signal(vd->ready);
            return NULL;
        }

        // Create descriptor
        CGVirtualDisplayDescriptor *desc = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
        desc.name = @"Zerocast Virtual Display";
        desc.vendorID = 0x1234;
        desc.productID = 0x5678;
        desc.serialNum = 1;
        desc.maxPixelsWide = MAX_DISPLAY_PIXELS;
        desc.maxPixelsHigh = MAX_DISPLAY_PIXELS;
        desc.sizeInMillimeters = CGSizeMake(597, 336); // 27" display
        desc.whitePoint = CGPointMake(0.3125, 0.3291);
        desc.redPrimary = CGPointMake(0.6797, 0.3203);
        desc.greenPrimary = CGPointMake(0.2559, 0.6983);
        desc.bluePrimary = CGPointMake(0.1494, 0.0557);
        [desc setDispatchQueue:dispatch_get_main_queue()];

        vd->display = [[cls alloc] initWithDescriptor:desc];
        if (!vd->display) {
            NSLog(@"CGVirtualDisplay initWithDescriptor failed");
            dispatch_semaphore_signal(vd->ready);
            return NULL;
        }

        if (!applyMode(vd->display, vd->width, vd->height, vd->refresh_rate)) {
            NSLog(@"CGVirtualDisplay applySettings failed");
            vd->display = nil;
            dispatch_semaphore_signal(vd->ready);
            return NULL;
        }

        vd->display_id = vd->display.displayID;

        // Un-mirror: macOS may auto-mirror new displays.
        // Use kCGConfigureForAppOnly to minimize notification broadcast.
        CGDisplayConfigRef cgConfig;
        if (CGBeginDisplayConfiguration(&cgConfig) == kCGErrorSuccess) {
            CGConfigureDisplayMirrorOfDisplay(cgConfig, vd->display_id, kCGNullDirectDisplay);
            CGCompleteDisplayConfiguration(cgConfig, kCGConfigureForAppOnly);
        }

        vd->run_loop = CFRunLoopGetCurrent();
        vd->create_ok = YES;
        dispatch_semaphore_signal(vd->ready);

        // Run until stopped — display lives as long as this thread runs
        CFRunLoopRun();

        // Thread is ending — release the display
        vd->display = nil;
    }
    return NULL;
}

// ── Public C API ────────────────────────────────────────────────────────

VirtualDisplay *vd_create(uint32_t width, uint32_t height, double refresh_rate) {
    VirtualDisplay *vd = calloc(1, sizeof(VirtualDisplay));
    if (!vd) return NULL;

    vd->width = width;
    vd->height = height;
    vd->refresh_rate = refresh_rate;
    vd->ready = dispatch_semaphore_create(0);
    vd->create_ok = NO;

    // Create the display on a dedicated thread with its own run loop
    pthread_create(&vd->thread, NULL, displayThread, vd);
    dispatch_semaphore_wait(vd->ready, DISPATCH_TIME_FOREVER);

    if (!vd->create_ok) {
        pthread_join(vd->thread, NULL);
        free(vd);
        return NULL;
    }

    NSLog(@"Virtual display %u created (%ux%u @%.0fHz)", vd->display_id, width, height, refresh_rate);
    return vd;
}

uint32_t vd_get_display_id(VirtualDisplay *vd) {
    if (!vd) return 0;
    return vd->display_id;
}

int vd_resize(VirtualDisplay *vd, uint32_t width, uint32_t height) {
    if (!vd || !vd->display) return -1;
    if (vd->width == width && vd->height == height) return 0;

    // Dispatch resize onto the display thread's run loop
    __block int result = -1;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);

    CFRunLoopPerformBlock(vd->run_loop, kCFRunLoopDefaultMode, ^{
        // applySettings declares the new mode and switches to it in one step
        // for virtual displays — no separate CGDisplaySetDisplayMode needed.
        if (!applyMode(vd->display, width, height, vd->refresh_rate)) {
            NSLog(@"vd_resize: applySettings failed for %ux%u", width, height);
            dispatch_semaphore_signal(done);
            return;
        }

        vd->width = width;
        vd->height = height;
        result = 0;
        NSLog(@"Virtual display %u resized to %ux%u", vd->display_id, width, height);
        dispatch_semaphore_signal(done);
    });
    CFRunLoopWakeUp(vd->run_loop);
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return result;
}

void vd_destroy(VirtualDisplay *vd) {
    if (!vd) return;

    // Stop the run loop — this causes the thread to release the display and exit
    CFRunLoopStop(vd->run_loop);
    pthread_join(vd->thread, NULL);
    free(vd);
}

int64_t vd_launch_app(uint32_t display_id, const char *app_path, uint32_t *out_window_id) {
    @autoreleasepool {
        // Poll for display bounds — WindowServer may need a moment after creation
        CGRect displayBounds = CGRectZero;
        for (int attempt = 0; attempt < 20; attempt++) {
            displayBounds = CGDisplayBounds(display_id);
            if (!CGRectIsEmpty(displayBounds)) break;
            usleep(100000); // 100ms
        }
        if (CGRectIsEmpty(displayBounds)) {
            NSLog(@"Failed to get bounds for display %u after 2s", display_id);
            return -1;
        }

        // Launch the app
        NSURL *appURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:app_path]];
        NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
        config.activates = NO;

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
        CGWindowID windowID = 0;
        for (int attempt = 0; attempt < 50; attempt++) {
            usleep(100000);

            CFArrayRef windowList = CGWindowListCopyWindowInfo(
                kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements,
                kCGNullWindowID);
            if (!windowList) continue;

            for (CFIndex i = 0; i < CFArrayGetCount(windowList); i++) {
                NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(windowList, i);
                NSNumber *ownerPID = info[(NSString *)kCGWindowOwnerPID];
                NSNumber *windowLayer = info[(NSString *)kCGWindowLayer];

                if (ownerPID && ownerPID.intValue == appPID &&
                    windowLayer && windowLayer.intValue == 0) {
                    NSNumber *wid = info[(NSString *)kCGWindowNumber];
                    if (wid) windowID = wid.unsignedIntValue;
                    break;
                }
            }
            CFRelease(windowList);
            if (windowID != 0) break;
        }

        if (windowID == 0) {
            NSLog(@"No window found for pid %d after 5s", appPID);
            return -1;
        }
        if (out_window_id) *out_window_id = windowID;

        // Move and size window to fill the virtual display
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

                NSLog(@"Window moved to virtual display at (%.0f, %.0f) size %.0fx%.0f",
                      pos.x, pos.y, size.width, size.height);

                CFRelease(windows);
            }
            CFRelease(appElement);
        }

        return (int64_t)appPID;
    }
}
