#import "GaryPrivate.h"
#import <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>

typedef void (*NotifyProc)(uint32_t type, void *data, size_t length, void *context);

static struct {
    int (*mainConnectionID)(void);
    CFArrayRef (*copyManagedDisplaySpaces)(int cid);
    uint64_t (*getActiveSpace)(int cid);
    CGError (*registerNotifyProc)(NotifyProc handler, uint32_t type, void *context);
    void (*setTimeLimit)(JSContextGroupRef group, double limit, GaryShouldTerminate callback, void *info);
    GaryCapability capabilities;
    int cid;
} sym;

static void resolve(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        void *jsc = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_LAZY);
        if (skylight) {
            sym.mainConnectionID = dlsym(skylight, "SLSMainConnectionID");
            sym.copyManagedDisplaySpaces = dlsym(skylight, "SLSCopyManagedDisplaySpaces");
            sym.getActiveSpace = dlsym(skylight, "SLSGetActiveSpace");
            sym.registerNotifyProc = dlsym(skylight, "SLSRegisterNotifyProc");
        }
        if (jsc) sym.setTimeLimit = dlsym(jsc, "JSContextGroupSetExecutionTimeLimit");
        if (sym.mainConnectionID) sym.cid = sym.mainConnectionID();
        if (sym.cid && sym.copyManagedDisplaySpaces) sym.capabilities |= GaryCapabilityDisplaySpaces;
        if (sym.cid && sym.getActiveSpace) sym.capabilities |= GaryCapabilityActiveSpace;
        if (sym.registerNotifyProc) sym.capabilities |= GaryCapabilitySpaceEvents;
        if (sym.setTimeLimit) sym.capabilities |= GaryCapabilityScriptTimeLimit;
    });
}

GaryCapability gary_capabilities(void)
{
    resolve();
    return sym.capabilities;
}

@implementation GaryDisplaySpaces
@end

static uint64_t u64(id value)
{
    return [value isKindOfClass:[NSNumber class]] ? [value unsignedLongLongValue] : 0;
}

static NSString *display_uuid(NSString *identifier)
{
    if (![identifier isEqualToString:@"Main"]) return identifier;
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID());
    if (!uuid) return identifier;
    NSString *string = CFBridgingRelease(CFUUIDCreateString(NULL, uuid));
    CFRelease(uuid);
    return string;
}

NSArray<GaryDisplaySpaces *> *gary_display_spaces(void)
{
    if (!(gary_capabilities() & GaryCapabilityDisplaySpaces)) return @[];
    NSArray *managed = CFBridgingRelease(sym.copyManagedDisplaySpaces(sym.cid));
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *entry in managed) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSString *identifier = entry[@"Display Identifier"];
        if (![identifier isKindOfClass:[NSString class]]) continue;
        GaryDisplaySpaces *display = [GaryDisplaySpaces new];
        display.uuid = display_uuid(identifier);
        NSDictionary *current = entry[@"Current Space"];
        display.currentSpaceID = [current isKindOfClass:[NSDictionary class]] ? u64(current[@"id64"]) : 0;
        NSMutableArray *spaces = [NSMutableArray array];
        for (NSDictionary *space in entry[@"Spaces"]) {
            if (![space isKindOfClass:[NSDictionary class]]) continue;
            if (u64(space[@"type"]) == 0 && u64(space[@"id64"])) [spaces addObject:@(u64(space[@"id64"]))];
        }
        display.userSpaceIDs = spaces;
        [result addObject:display];
    }
    return result;
}

uint64_t gary_active_space(void)
{
    return (gary_capabilities() & GaryCapabilityActiveSpace) ? sym.getActiveSpace(sym.cid) : 0;
}

static GarySpaceEventCallback space_callback = NULL;
static void *space_context = NULL;

static void space_handler(uint32_t type, void *data, size_t length, void *context)
{
    if (space_callback) space_callback((GarySpaceEvent)type, space_context);
}

bool gary_space_events_start(GarySpaceEventCallback callback, void *context)
{
    if (!(gary_capabilities() & GaryCapabilitySpaceEvents)) return false;
    space_callback = callback;
    space_context = context;
    bool ok = true;
    for (uint32_t event = GarySpaceEventCreated; event <= GarySpaceEventDestroyed; event++) {
        ok = sym.registerNotifyProc(space_handler, event, NULL) == kCGErrorSuccess && ok;
    }
    return sym.registerNotifyProc(space_handler, GarySpaceEventChanged, NULL) == kCGErrorSuccess && ok;
}

bool gary_script_time_limit(JSGlobalContextRef context, double seconds, GaryShouldTerminate callback, void *info)
{
    if (!(gary_capabilities() & GaryCapabilityScriptTimeLimit)) return false;
    sym.setTimeLimit(JSContextGetGroup(context), seconds, callback, info);
    return true;
}
