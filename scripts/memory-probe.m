#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <malloc/malloc.h>
#include <notify.h>

#define INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *replacement; const void *original; } interpose_##original \
        __attribute__((section("__DATA,__interpose"))) = {(const void *)replacement, (const void *)original};

extern int SLSSetMenuBarInsetAndAlpha(int, double, double, float);
extern int SLSSetDockRectWithOrientation(int, CGRect, int, int);
extern void CoreDockSetAutoHideEnabled(bool);
extern void IOBluetoothPreferenceSetControllerPowerState(int);
extern int DisplayServicesSetBrightness(int, float);
extern int IOAVServiceWriteI2C(void *, uint32_t, uint32_t, void *, uint32_t);
extern IOReturn IOHIDSetModifierLockState(io_connect_t, int, bool);
extern Boolean IOHIDServiceClientSetProperty(void *, CFStringRef, CFTypeRef);
extern JSObjectRef JSGetMemoryUsageStatistics(JSContextRef);
extern void JSSynchronousGarbageCollectForDebugging(JSContextRef);
extern void _ZN3WTF27releaseFastMallocFreeMemoryEv(void);
extern void _ZN3JSC12JSLockHolderC1ERNS_2VME(void *holder, void *vm);
extern void _ZN3JSC12JSLockHolderD1Ev(void *holder);
extern void _ZN3JSC2VM13deleteAllCodeENS_19DeleteAllCodeEffortE(void *vm, int effort);

static int probe_menu_bar(int connection, double inset, double unknown, float alpha) { return 0; }
static int probe_dock_rect(int connection, CGRect rect, int reason, int orientation) { return 0; }
static void probe_dock_autohide(bool hidden) {}
static void probe_bluetooth_power(int state) {}
static int probe_brightness(int display, float value) { return 0; }
static int probe_i2c_write(void *service, uint32_t chip, uint32_t offset, void *buffer, uint32_t length) { return 0; }
static IOReturn probe_caps_lock(io_connect_t connection, int selector, bool state) { return kIOReturnSuccess; }
static Boolean probe_hid_property(void *service, CFStringRef key, CFTypeRef value) { return true; }
static void probe_post(CGEventTapLocation tap, CGEventRef event) {}
static void probe_tap_enable(CFMachPortRef tap, bool enable) {}

static void probe_tap_callout(CFMachPortRef port, void *message, CFIndex size, void *info) {}

static CFMachPortRef probe_tap_create(CGEventTapLocation tap, CGEventTapPlacement place, CGEventTapOptions options, CGEventMask mask,
                                      CGEventTapCallBack callback, void *info)
{
    return CFMachPortCreate(NULL, probe_tap_callout, NULL, NULL);
}

static OSStatus probe_register_hotkey(UInt32 code, UInt32 modifiers, EventHotKeyID id, EventTargetRef target, OptionBits options,
                                      EventHotKeyRef *ref)
{
    static uintptr_t next = 0x1000;
    *ref = (EventHotKeyRef)(next += 16);
    return noErr;
}

static OSStatus probe_unregister_hotkey(EventHotKeyRef ref) { return noErr; }

static size_t probe_confstr(int name, char *buffer, size_t length)
{
    const char *directory = getenv("GARY_PROBE_TMPDIR");
    if (name != _CS_DARWIN_USER_TEMP_DIR || !directory) return confstr(name, buffer, length);
    if (buffer && length) strlcpy(buffer, directory, length);
    return strlen(directory) + 1;
}

INTERPOSE(probe_menu_bar, SLSSetMenuBarInsetAndAlpha)
INTERPOSE(probe_dock_rect, SLSSetDockRectWithOrientation)
INTERPOSE(probe_dock_autohide, CoreDockSetAutoHideEnabled)
INTERPOSE(probe_bluetooth_power, IOBluetoothPreferenceSetControllerPowerState)
INTERPOSE(probe_brightness, DisplayServicesSetBrightness)
INTERPOSE(probe_i2c_write, IOAVServiceWriteI2C)
INTERPOSE(probe_caps_lock, IOHIDSetModifierLockState)
INTERPOSE(probe_hid_property, IOHIDServiceClientSetProperty)
INTERPOSE(probe_post, CGEventPost)
INTERPOSE(probe_tap_enable, CGEventTapEnable)
INTERPOSE(probe_tap_create, CGEventTapCreate)
INTERPOSE(probe_register_hotkey, RegisterEventHotKey)
INTERPOSE(probe_unregister_hotkey, UnregisterEventHotKey)
INTERPOSE(probe_confstr, confstr)

static void replace(Class cls, SEL selector, id block)
{
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        fprintf(stderr, "memory-probe: no %s on %s\n", sel_getName(selector), class_getName(cls));
        return;
    }
    class_replaceMethod(cls, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method));
}

static IMP original(Class cls, SEL selector)
{
    return method_getImplementation(class_getInstanceMethod(cls, selector));
}

static void hideWindows(void)
{
    Class window = NSWindow.class;
    IMP setAlpha = original(window, @selector(setAlphaValue:));
    IMP setIgnores = original(window, @selector(setIgnoresMouseEvents:));
    void (^conceal)(NSWindow *) = ^(NSWindow *target) {
        ((void (*)(id, SEL, CGFloat))setAlpha)(target, @selector(setAlphaValue:), 0);
        ((void (*)(id, SEL, BOOL))setIgnores)(target, @selector(setIgnoresMouseEvents:), YES);
    };
    replace(window, @selector(setAlphaValue:), ^(NSWindow *self, CGFloat alpha) { conceal(self); });
    replace(window, @selector(setIgnoresMouseEvents:), ^(NSWindow *self, BOOL ignores) { conceal(self); });
    IMP orderFront = original(window, @selector(orderFront:));
    IMP orderRegardless = original(window, @selector(orderFrontRegardless));
    IMP orderWindow = original(window, @selector(orderWindow:relativeTo:));
    replace(window, @selector(orderFront:), ^(NSWindow *self, id sender) {
        conceal(self);
        ((void (*)(id, SEL, id))orderFront)(self, @selector(orderFront:), sender);
    });
    replace(window, @selector(makeKeyAndOrderFront:), ^(NSWindow *self, id sender) {
        conceal(self);
        ((void (*)(id, SEL, id))orderFront)(self, @selector(orderFront:), sender);
    });
    replace(window, @selector(orderFrontRegardless), ^(NSWindow *self) {
        conceal(self);
        ((void (*)(id, SEL))orderRegardless)(self, @selector(orderFrontRegardless));
    });
    replace(window, @selector(orderWindow:relativeTo:), ^(NSWindow *self, NSWindowOrderingMode mode, NSInteger other) {
        conceal(self);
        ((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))orderWindow)(self, @selector(orderWindow:relativeTo:), mode, other);
    });
    replace(window, @selector(makeKeyWindow), ^(NSWindow *self) {});
    replace(NSApplication.class, @selector(activateIgnoringOtherApps:), ^(NSApplication *self, BOOL flag) {});
    replace(NSApplication.class, @selector(activate), ^(NSApplication *self) {});
    replace(NSRunningApplication.class, @selector(activateWithOptions:), ^BOOL(NSRunningApplication *self, NSApplicationActivationOptions options) {
        return YES;
    });
    replace(NSRunningApplication.class, @selector(activateFromApplication:options:),
            ^BOOL(NSRunningApplication *self, NSRunningApplication *app, NSApplicationActivationOptions options) { return YES; });
    replace(NSWorkspace.class, @selector(setDesktopImageURL:forScreen:options:error:),
            ^BOOL(NSWorkspace *self, NSURL *url, NSScreen *screen, NSDictionary *options, NSError **error) { return YES; });
    replace(UNUserNotificationCenter.class, @selector(addNotificationRequest:withCompletionHandler:),
            ^(UNUserNotificationCenter *self, UNNotificationRequest *request, void (^done)(NSError *)) {
                if (done) done(nil);
            });
}

static NSHashTable<JSContext *> *contexts;
static NSMutableDictionary<NSValue *, NSNumber *> *machineOrder;
static NSLock *contextsLock;

static void track(JSContext *context)
{
    if (!context) return;
    [contextsLock lock];
    [contexts addObject:context];
    NSValue *key = [NSValue valueWithPointer:(__bridge void *)context.virtualMachine];
    if (!machineOrder[key]) machineOrder[key] = @(machineOrder.count);
    [contextsLock unlock];
}

static void trackContexts(void)
{
    contexts = [NSHashTable weakObjectsHashTable];
    machineOrder = [NSMutableDictionary dictionary];
    contextsLock = [NSLock new];
    IMP initWithMachine = original(JSContext.class, @selector(initWithVirtualMachine:));
    replace(JSContext.class, @selector(initWithVirtualMachine:), ^id(JSContext *self, JSVirtualMachine *machine) {
        JSContext *context = ((id (*)(id, SEL, id))initWithMachine)(self, @selector(initWithVirtualMachine:), machine);
        track(context);
        return context;
    });
    IMP init = original(JSContext.class, @selector(init));
    replace(JSContext.class, @selector(init), ^id(JSContext *self) {
        JSContext *context = ((id (*)(id, SEL))init)(self, @selector(init));
        track(context);
        return context;
    });
}

static NSDictionary *heapStatistics(JSContext *context)
{
    JSObjectRef stats = JSGetMemoryUsageStatistics(context.JSGlobalContextRef);
    NSDictionary *all = [[JSValue valueWithJSValueRef:stats inContext:context] toDictionary];
    return @{
        @"heapSize": all[@"heapSize"] ?: @0,
        @"heapCapacity": all[@"heapCapacity"] ?: @0,
        @"extraMemorySize": all[@"extraMemorySize"] ?: @0,
        @"objectCount": all[@"objectCount"] ?: @0,
        @"globalObjectCount": all[@"globalObjectCount"] ?: @0,
    };
}

typedef NS_ENUM(NSInteger, ProbeAction) { ProbeStats, ProbeCollect, ProbeRelease, ProbeDeleteCode };

static void deleteCode(JSContext *context)
{
    void *vm = (void *)JSContextGetGroup(context.JSGlobalContextRef);
    void *holder[2] = {0};
    _ZN3JSC12JSLockHolderC1ERNS_2VME(holder, vm);
    _ZN3JSC2VM13deleteAllCodeENS_19DeleteAllCodeEffortE(vm, 0);
    _ZN3JSC12JSLockHolderD1Ev(holder);
}

static NSArray *machines(ProbeAction action)
{
    [contextsLock lock];
    NSArray<JSContext *> *live = contexts.allObjects;
    NSDictionary<NSValue *, NSNumber *> *order = [machineOrder copy];
    [contextsLock unlock];
    NSMutableDictionary<NSValue *, NSMutableArray<JSContext *> *> *byMachine = [NSMutableDictionary dictionary];
    for (JSContext *context in live) {
        NSValue *key = [NSValue valueWithPointer:(__bridge void *)context.virtualMachine];
        if (!byMachine[key]) byMachine[key] = [NSMutableArray array];
        [byMachine[key] addObject:context];
    }
    NSMutableArray *result = [NSMutableArray array];
    for (NSMutableArray<JSContext *> *group in byMachine.allValues) {
        JSContext *context = group.firstObject;
        NSMutableArray *names = [NSMutableArray array];
        for (JSContext *each in group) [names addObject:each.name ?: @""];
        NSValue *key = [NSValue valueWithPointer:(__bridge void *)context.virtualMachine];
        NSMutableDictionary *entry = [@{@"index": order[key] ?: @(-1), @"contexts": names, @"before": heapStatistics(context)} mutableCopy];
        if (action == ProbeDeleteCode) deleteCode(context);
        if (action != ProbeStats) {
            JSSynchronousGarbageCollectForDebugging(context.JSGlobalContextRef);
            entry[@"after"] = heapStatistics(context);
        }
        [result addObject:entry];
    }
    if (action == ProbeRelease || action == ProbeDeleteCode) {
        _ZN3WTF27releaseFastMallocFreeMemoryEv();
        malloc_zone_pressure_relief(NULL, 0);
    }
    return result;
}

static NSArray *windows(void)
{
    __block NSMutableArray *result = [NSMutableArray array];
    dispatch_sync(dispatch_get_main_queue(), ^{
        for (NSWindow *window in NSApp.windows) {
            [result addObject:@{
                @"class": NSStringFromClass(window.class),
                @"visible": @(window.isVisible),
                @"occluded": @(!(window.occlusionState & NSWindowOcclusionStateVisible)),
                @"alpha": @(window.alphaValue),
                @"width": @(window.frame.size.width),
                @"height": @(window.frame.size.height),
            }];
        }
    });
    return result;
}

static void report(ProbeAction action)
{
    NSString *directory = [NSString stringWithUTF8String:getenv("GARY_PROBE_DIR")];
    NSDictionary *output = @{@"machines": machines(action), @"windows": windows()};
    NSData *data = [NSJSONSerialization dataWithJSONObject:output options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    NSString *path = [directory stringByAppendingPathComponent:@"probe.json"];
    NSString *partial = [path stringByAppendingString:@".partial"];
    [data writeToFile:partial atomically:NO];
    rename(partial.fileSystemRepresentation, path.fileSystemRepresentation);
}

static void listenForReports(void)
{
    if (!getenv("GARY_PROBE_DIR")) return;
    dispatch_queue_t queue = dispatch_queue_create("gary.memory-probe", DISPATCH_QUEUE_SERIAL);
    NSDictionary<NSString *, NSNumber *> *actions = @{@"stats": @(ProbeStats), @"gc": @(ProbeCollect), @"release": @(ProbeRelease), @"code": @(ProbeDeleteCode)};
    for (NSString *name in actions) {
        int token;
        ProbeAction action = actions[name].integerValue;
        NSString *key = [NSString stringWithFormat:@"gary.memory-probe.%d.%@", getpid(), name];
        notify_register_dispatch(key.UTF8String, &token, queue, ^(int t) { report(action); });
    }
}

static void serveCachedFetches(void)
{
    const char *directory = getenv("GARY_PROBE_FETCH_CACHE");
    if (!directory) return;
    NSString *root = [NSString stringWithUTF8String:directory];
    Class session = NSURLSession.class;
    SEL selector = @selector(dataTaskWithRequest:completionHandler:);
    IMP make = original(session, selector);
    replace(session, selector, ^NSURLSessionDataTask *(NSURLSession *self, NSURLRequest *request, void (^done)(NSData *, NSURLResponse *, NSError *)) {
        NSString *path = [root stringByAppendingPathComponent:request.URL.host ?: @""];
        if (![NSFileManager.defaultManager fileExistsAtPath:path])
            return ((NSURLSessionDataTask * (*)(id, SEL, id, id)) make)(self, selector, request, done);
        NSURL *asked = request.URL;
        fprintf(stderr, "memory-probe: served %s from the fetch cache\n", asked.host.UTF8String);
        void (^served)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *ok = [[NSHTTPURLResponse alloc] initWithURL:asked statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
            done(data, error ? response : ok, error);
        };
        return ((NSURLSessionDataTask * (*)(id, SEL, id, id)) make)(self, selector, [NSURLRequest requestWithURL:[NSURL fileURLWithPath:path]], served);
    });
}

static void *volatile ballast;

static void addDeliberateCosts(void)
{
    const char *megabytes = getenv("GARY_PROBE_ALLOC_MB");
    if (megabytes) {
        size_t size = (size_t)(atof(megabytes) * 1024 * 1024);
        ballast = malloc(size);
        memset(ballast, 1, size);
    }
    const char *busy = getenv("GARY_PROBE_BUSY_MS");
    if (!busy) return;
    double seconds = atof(busy) / 1000;
    void (^spin)(void) = ^{
        NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
        while (until.timeIntervalSinceNow > 0) {}
    };
    SEL selector = @selector(orderFrontRegardless);
    IMP front = original(NSWindow.class, selector);
    replace(NSWindow.class, selector, ^(NSWindow *self) {
        spin();
        ((void (*)(id, SEL))front)(self, selector);
    });
}

__attribute__((constructor)) static void start(void)
{
    @autoreleasepool {
        hideWindows();
        trackContexts();
        listenForReports();
        serveCachedFetches();
        addDeliberateCosts();
    }
}
