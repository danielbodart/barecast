// zerocast-vd: Virtual display helper process.
// Creates a CGVirtualDisplay, writes the display ID to stdout, and stays
// alive until SIGTERM (display disappears when process exits).
//
// Usage: zerocast-vd <width> <height> <refresh_rate>
// Output: display ID as decimal string on stdout

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AppKit/AppKit.h>
#import <signal.h>
#import <stdint.h>

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

// ── Globals ─────────────────────────────────────────────────────────────

static CGVirtualDisplay *g_display = nil;
static volatile sig_atomic_t g_should_exit = 0;

static void handleSignal(int sig) {
    (void)sig;
    g_should_exit = 1;
    CFRunLoopStop(CFRunLoopGetMain());
}

// ── Main ────────────────────────────────────────────────────────────────

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) {
            fprintf(stderr, "usage: zerocast-vd <width> <height> <refresh_rate>\n");
            return 1;
        }

        unsigned int width = (unsigned int)atoi(argv[1]);
        unsigned int height = (unsigned int)atoi(argv[2]);
        double refreshRate = atof(argv[3]);

        if (width == 0 || height == 0 || refreshRate <= 0) {
            fprintf(stderr, "invalid arguments: %ux%u @%.0fHz\n", width, height, refreshRate);
            return 1;
        }

        // Initialize NSApplication — required for WindowServer registration
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];

        // Check API availability
        Class cls = NSClassFromString(@"CGVirtualDisplay");
        if (!cls) {
            fprintf(stderr, "CGVirtualDisplay not available (requires macOS 14+)\n");
            return 2;
        }

        // Create descriptor
        CGVirtualDisplayDescriptor *desc = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
        desc.name = @"Zerocast Virtual Display";
        desc.vendorID = 0x1234;
        desc.productID = 0x5678;
        desc.serialNum = 1;
        desc.maxPixelsWide = width;
        desc.maxPixelsHigh = height;
        desc.sizeInMillimeters = CGSizeMake(597, 336); // 27" display
        desc.whitePoint = CGPointMake(0.3125, 0.3291);
        desc.redPrimary = CGPointMake(0.6797, 0.3203);
        desc.greenPrimary = CGPointMake(0.2559, 0.6983);
        desc.bluePrimary = CGPointMake(0.1494, 0.0557);
        [desc setDispatchQueue:dispatch_get_main_queue()];
        desc.terminationHandler = ^(id a, id b) {
            (void)a; (void)b;
            fprintf(stderr, "zerocast-vd: display terminated by system\n");
            g_should_exit = 1;
        };

        // Create display
        g_display = [[cls alloc] initWithDescriptor:desc];
        if (!g_display) {
            fprintf(stderr, "CGVirtualDisplay initWithDescriptor failed\n");
            return 3;
        }

        // Apply mode
        CGVirtualDisplayMode *mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc]
            initWithWidth:width height:height refreshRate:refreshRate];
        CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
        settings.hiDPI = 0;
        settings.modes = @[mode];

        if (![g_display applySettings:settings]) {
            fprintf(stderr, "CGVirtualDisplay applySettings failed\n");
            return 4;
        }

        CGDirectDisplayID displayID = g_display.displayID;

        // Un-mirror: macOS may auto-mirror new displays
        CGDisplayConfigRef cgConfig;
        if (CGBeginDisplayConfiguration(&cgConfig) == kCGErrorSuccess) {
            CGConfigureDisplayMirrorOfDisplay(cgConfig, displayID, kCGNullDirectDisplay);
            CGCompleteDisplayConfiguration(cgConfig, kCGConfigureForSession);
        }

        // TODO: Position the display far off-screen via SkyLight if available.
        // For now the display may appear adjacent to the main display in
        // System Settings → Displays, but is not visible as a physical monitor.

        // Write display ID to stdout (parent reads this)
        printf("%u\n", displayID);
        fflush(stdout);

        fprintf(stderr, "zerocast-vd: display %u created (%ux%u @%.0fHz)\n",
                displayID, width, height, refreshRate);

        // Install signal handlers
        signal(SIGTERM, handleSignal);
        signal(SIGINT, handleSignal);

        // Run until signaled — display lives as long as we do
        while (!g_should_exit) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
        }

        fprintf(stderr, "zerocast-vd: shutting down display %u\n", displayID);
        g_display = nil; // ARC releases → display removed
        return 0;
    }
}
