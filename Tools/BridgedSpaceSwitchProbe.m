#import <Cocoa/Cocoa.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <signal.h>

// An isolated probe, not part of Rectangle's application target. The published
// header declares the setter synchronous; macOS 27.0 (26A428) implements all
// four operations below as asynchronous operations with a void perform method.
@protocol RectangleBridgedSpaceOperation
- (instancetype)initWithDisplayIdentifier:(NSString *)identifier spaceID:(uint64_t)spaceID;
- (instancetype)initWithSpaces:(NSArray<NSNumber *> *)spaces;
- (void)performWithWMBridgeDelegate;
@end

typedef int32_t (*MainConnection)(void);
typedef CFArrayRef (*CopyDisplays)(int32_t);
typedef CFArrayRef (*CopyWindowSpaces)(int32_t, int32_t, CFArrayRef);
typedef CFStringRef (*CopyDisplayAtPoint)(int32_t, CGPoint);

static int32_t connection;
static CopyDisplays copyDisplays;
static CopyWindowSpaces copyWindowSpaces;
static NSUInteger notifications;
static volatile sig_atomic_t interrupted;

static void interruptProbe(int signalNumber) {
    interrupted = signalNumber;
}

static uint64_t currentSpace(NSString *identifier) {
    NSArray *displays = CFBridgingRelease(copyDisplays(connection));
    for (NSDictionary *display in displays) {
        if ([display[@"Display Identifier"] isEqual:identifier]) {
            return [display[@"Current Space"][@"id64"] unsignedLongLongValue];
        }
    }
    return 0;
}

static NSDictionary<NSString *, NSSet<NSNumber *> *> *residentWindows(
    uint64_t source, uint64_t target, CGWindowListOption options
) {
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(
        options | kCGWindowListExcludeDesktopElements, kCGNullWindowID
    ));
    if (!windows) return nil;
    NSMutableSet *onSource = [NSMutableSet new], *onTarget = [NSMutableSet new];
    for (NSDictionary *window in windows) {
        if ([window[(id)kCGWindowLayer] intValue] != 0
            || [window[(id)kCGWindowAlpha] doubleValue] <= 0) continue;
        NSNumber *windowID = window[(id)kCGWindowNumber];
        if (!windowID) continue;
        NSArray *spaces = CFBridgingRelease(copyWindowSpaces(
            connection, 7, (__bridge CFArrayRef)@[windowID]
        ));
        // Windows assigned to all desktops cannot prove that a switch occurred.
        if (spaces.count != 1) continue;
        uint64_t spaceID = [spaces[0] unsignedLongLongValue];
        if (spaceID == source) [onSource addObject:windowID];
        if (spaceID == target) [onTarget addObject:windowID];
    }
    return @{@"source": [onSource copy], @"target": [onTarget copy]};
}

static void report(NSString *stage, NSString *display, uint64_t source, uint64_t target) {
    NSDictionary *visible = residentWindows(source, target, kCGWindowListOptionOnScreenOnly);
    printf("%s: current=%llu sourceVisible=%lu targetVisible=%lu notifications=%lu frontmostPID=%d\n",
           stage.UTF8String, (unsigned long long)currentSpace(display),
           (unsigned long)[visible[@"source"] count], (unsigned long)[visible[@"target"] count],
           (unsigned long)notifications, NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier);
    fflush(stdout);
}

static BOOL hasMethod(Class cls, NSString *name, const char *encoding) {
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
    return method && strcmp(method_getTypeEncoding(method), encoding) == 0;
}

static BOOL operationsAvailable(void) {
    for (NSString *name in @[@"SLSBridgedManagedDisplaySetCurrentSpaceOperation",
                             @"SLSBridgedWillSwitchSpacesOperation",
                             @"SLSBridgedShowSpacesOperation", @"SLSBridgedHideSpacesOperation"]) {
        Class cls = NSClassFromString(name);
        if (!cls || !hasMethod(cls, @"performWithWMBridgeDelegate", "v16@0:8")) return NO;
        if ([name isEqualToString:@"SLSBridgedManagedDisplaySetCurrentSpaceOperation"]) {
            if (!hasMethod(cls, @"initWithDisplayIdentifier:spaceID:", "@32@0:8@16Q24")) return NO;
        } else if (!hasMethod(cls, @"initWithSpaces:", "@24@0:8@16")) {
            return NO;
        }
    }
    return YES;
}

static BOOL setCurrent(NSString *display, uint64_t spaceID) {
    Class cls = NSClassFromString(@"SLSBridgedManagedDisplaySetCurrentSpaceOperation");
    id<RectangleBridgedSpaceOperation> operation = [(id<RectangleBridgedSpaceOperation>)[cls alloc]
        initWithDisplayIdentifier:display spaceID:spaceID];
    if (!operation) return NO;
    [operation performWithWMBridgeDelegate];
    return YES; // Submission only; these operations have no completion/result.
}

static BOOL spacesOperation(NSString *name, uint64_t spaceID) {
    Class cls = NSClassFromString(name);
    id<RectangleBridgedSpaceOperation> operation = [(id<RectangleBridgedSpaceOperation>)[cls alloc]
        initWithSpaces:@[@(spaceID)]];
    if (!operation) return NO;
    [operation performWithWMBridgeDelegate];
    return YES;
}

static BOOL switchDisplay(NSString *display, uint64_t source, uint64_t target) {
    return spacesOperation(@"SLSBridgedWillSwitchSpacesOperation", target)
        && spacesOperation(@"SLSBridgedShowSpacesOperation", target)
        && spacesOperation(@"SLSBridgedHideSpacesOperation", source)
        && setCurrent(display, target);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL setterOnly = argc == 2 && strcmp(argv[1], "--setter-only") == 0;
        BOOL roundTrip = argc == 2 && strcmp(argv[1], "--round-trip") == 0;
        if (argc > 1 && !setterOnly && !roundTrip) {
            fprintf(stderr, "Usage: %s [--setter-only | --round-trip]\nNo argument: inspect only.\n", argv[0]);
            return 2;
        }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        void *framework = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW);
        if (!framework) return 3;
        MainConnection mainConnection = (MainConnection)dlsym(framework, "SLSMainConnectionID");
        copyDisplays = (CopyDisplays)dlsym(framework, "SLSCopyManagedDisplaySpaces");
        copyWindowSpaces = (CopyWindowSpaces)dlsym(framework, "SLSCopySpacesForWindows");
        CopyDisplayAtPoint displayAtPoint = (CopyDisplayAtPoint)dlsym(framework, "SLSCopyBestManagedDisplayForPoint");
        if (!mainConnection || !copyDisplays || !copyWindowSpaces || !displayAtPoint || !operationsAvailable()) {
            fputs("Required symbols or method signatures unavailable; no switch performed.\n", stderr);
            return 3;
        }
        connection = mainConnection();
        CGEventRef event = CGEventCreate(NULL);
        if (!event) return 4;
        CGPoint cursor = CGEventGetLocation(event);
        CFRelease(event);
        NSString *identifier = CFBridgingRelease(displayAtPoint(connection, cursor));
        NSArray *displays = CFBridgingRelease(copyDisplays(connection));
        uint64_t source = currentSpace(identifier), target = 0;
        for (NSDictionary *display in displays) {
            if (![display[@"Display Identifier"] isEqual:identifier]) continue;
            if ([display[@"Current Space"][@"type"] intValue] != 0) break;
            for (NSDictionary *space in display[@"Spaces"]) {
                uint64_t candidate = [space[@"id64"] unsignedLongLongValue];
                if (!candidate || candidate == source || [space[@"type"] intValue] != 0) continue;
                NSDictionary *windows = residentWindows(source, candidate, kCGWindowListOptionAll);
                if ([windows[@"target"] count] > 0) { target = candidate; break; }
            }
        }
        NSDictionary *before = residentWindows(source, target, kCGWindowListOptionOnScreenOnly);
        if (!source || !target || !before || [before[@"source"] count] == 0 || [before[@"target"] count] != 0) {
            fputs("A populated source and hidden normal destination are required; no switch performed.\n", stderr);
            return 4;
        }
        printf("macOS=%s source=%llu target=%llu AXTrusted=%d\n",
               NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String,
               (unsigned long long)source, (unsigned long long)target, AXIsProcessTrusted());
        id observer = [NSWorkspace.sharedWorkspace.notificationCenter
            addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                (void)note;
                notifications++;
            }];
        report(@"before", identifier, source, target);
        if (!setterOnly && !roundTrip) {
            [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:observer];
            return 0;
        }

        signal(SIGINT, interruptProbe);
        signal(SIGTERM, interruptProbe);
        __block BOOL destinationVerified = NO, restored = NO;
        // NSWorkspace's notification delivery requires AppKit to process events.
        // Spinning NSRunLoop alone produced zero notifications even for a normal
        // Dock gesture, which was an invalid control for the setter experiment.
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL submitted = setterOnly ? setCurrent(identifier, target) : switchDisplay(identifier, source, target);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                report(@"destination", identifier, source, target);
                NSDictionary *visible = residentWindows(source, target, kCGWindowListOptionOnScreenOnly);
                destinationVerified = submitted && currentSpace(identifier) == target && visible
                    && [visible[@"source"] count] == 0 && [visible[@"target"] count] > 0;
                printf("Destination visibility verified: %s\n", destinationVerified ? "yes" : "no");
                // The setter alone can show both Spaces. Merely setting the old
                // ID back does not undo that: restore the visibility explicitly.
                BOOL restoreSubmitted = switchDisplay(identifier, target, source);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                    report(@"restored", identifier, source, target);
                    NSDictionary *original = residentWindows(source, target, kCGWindowListOptionOnScreenOnly);
                    restored = restoreSubmitted && currentSpace(identifier) == source && [original isEqual:before];
                    printf("Original Space and window visibility restored: %s\n", restored ? "yes" : "no");
                    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:observer];
                    [NSApp stop:nil];
                    [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined
                        location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil
                        subtype:0 data1:0 data2:0] atStart:NO];
                });
            });
        });
        [NSApp run];
        // Visibility is only one part of a real switch. Notification delivery,
        // wallpaper, Dock/Mission Control state, focus, and input need separate
        // verification alongside the visibility check.
        if (!restored) return 5;
        if (interrupted) return 128 + interrupted;
        return destinationVerified ? 0 : 1;
    }
}
