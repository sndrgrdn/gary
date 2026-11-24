#import "GaryPrivate.h"
#include <dlfcn.h>

#define SKYLIGHT "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
#define DISPLAY_SERVICES "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
#define IOKIT_FRAMEWORK "/System/Library/Frameworks/IOKit.framework/IOKit"
#define TCC "/System/Library/PrivateFrameworks/TCC.framework/TCC"
#define JAVASCRIPT_CORE "/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore"

static const GaryPrivateSymbol symbols[] = {
    [GarySymbolExecutionTimeLimit] = {JAVASCRIPT_CORE, "JSContextGroupSetExecutionTimeLimit", "plugin script time limit"},
    [GarySymbolMainConnectionID] = {SKYLIGHT, "SLSMainConnectionID", "menubar hide and dock reserve"},
    [GarySymbolSetMenuBarInsetAndAlpha] = {SKYLIGHT, "SLSSetMenuBarInsetAndAlpha", "menubar hide"},
    [GarySymbolGetDockRect] = {SKYLIGHT, "SLSGetDockRectWithOrientation", "dock reserve"},
    [GarySymbolSetDockRect] = {SKYLIGHT, "SLSSetDockRectWithOrientation", "dock reserve"},
    [GarySymbolDockGetAutoHide] = {"/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", "CoreDockGetAutoHideEnabled", "dock hide"},
    [GarySymbolDockSetAutoHide] = {"/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", "CoreDockSetAutoHideEnabled", "dock hide"},
    [GarySymbolWindowListCreateImage] = {SKYLIGHT, "SLWindowListCreateImageFromArray", "tray icons"},
    [GarySymbolBluetoothSetPower] = {"/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", "IOBluetoothPreferenceSetControllerPowerState", "bluetooth power"},
    [GarySymbolGetBrightness] = {DISPLAY_SERVICES, "DisplayServicesGetBrightness", "brightness of built-in displays"},
    [GarySymbolSetBrightness] = {DISPLAY_SERVICES, "DisplayServicesSetBrightness", "brightness of built-in displays"},
    [GarySymbolRegisterBrightnessChanges] = {DISPLAY_SERVICES, "DisplayServicesRegisterForBrightnessChangeNotifications", "brightness change events"},
    [GarySymbolAVServiceCreate] = {IOKIT_FRAMEWORK, "IOAVServiceCreateWithService", "brightness of external displays"},
    [GarySymbolAVServiceReadI2C] = {IOKIT_FRAMEWORK, "IOAVServiceReadI2C", "brightness of external displays"},
    [GarySymbolAVServiceWriteI2C] = {IOKIT_FRAMEWORK, "IOAVServiceWriteI2C", "brightness of external displays"},
    [GarySymbolDisplayInfo] = {"/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", "CoreDisplay_DisplayCreateInfoDictionary", "brightness of external displays"},
    [GarySymbolTCCAccessPreflight] = {TCC, "TCCAccessPreflight", "System Audio Recording status"},
    [GarySymbolTCCAccessRequest] = {TCC, "TCCAccessRequest", "System Audio Recording prompt"},
    [GarySymbolLockEngine] = {JAVASCRIPT_CORE, "_ZN3JSC12JSLockHolderC1ERNS_2VME", "dropping plugin bytecode after startup"},
    [GarySymbolUnlockEngine] = {JAVASCRIPT_CORE, "_ZN3JSC12JSLockHolderD1Ev", "dropping plugin bytecode after startup"},
    [GarySymbolDeleteAllCode] = {JAVASCRIPT_CORE, "_ZN3JSC2VM13deleteAllCodeENS_19DeleteAllCodeEffortE", "dropping plugin bytecode after startup"},
    [GarySymbolCollectGarbage] = {JAVASCRIPT_CORE, "JSSynchronousGarbageCollectForDebugging", "dropping plugin bytecode after startup"},
    [GarySymbolReleaseFreeMemory] = {JAVASCRIPT_CORE, "_ZN3WTF27releaseFastMallocFreeMemoryEv", "dropping plugin bytecode after startup"},
};

size_t gary_private_symbol_count(void)
{
    return sizeof(symbols) / sizeof(symbols[0]);
}

GaryPrivateSymbol gary_private_symbol(size_t index)
{
    return symbols[index];
}

void *gary_private_resolve(size_t index)
{
    if (index >= gary_private_symbol_count()) return NULL;
    void *library = dlopen(symbols[index].library, RTLD_LAZY);
    return library ? dlsym(library, symbols[index].symbol) : NULL;
}

typedef void (*SetTimeLimit)(JSContextGroupRef group, double limit, GaryShouldTerminate callback, void *info);

bool gary_script_time_limit(JSGlobalContextRef context, double seconds, GaryShouldTerminate callback, void *info)
{
    static SetTimeLimit setTimeLimit;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        setTimeLimit = (SetTimeLimit)gary_private_resolve(GarySymbolExecutionTimeLimit);
    });
    if (!setTimeLimit) return false;
    setTimeLimit(JSContextGetGroup(context), seconds, callback, info);
    return true;
}

bool gary_drop_compiled_code(JSGlobalContextRef context)
{
    static void (*lock)(void *holder, JSContextGroupRef vm);
    static void (*unlock)(void *holder);
    static void (*deleteAllCode)(JSContextGroupRef vm, int effort);
    static void (*collect)(JSContextRef context);
    static void (*release)(void);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = gary_private_resolve(GarySymbolLockEngine);
        unlock = gary_private_resolve(GarySymbolUnlockEngine);
        deleteAllCode = gary_private_resolve(GarySymbolDeleteAllCode);
        collect = gary_private_resolve(GarySymbolCollectGarbage);
        release = gary_private_resolve(GarySymbolReleaseFreeMemory);
    });
    if (!lock || !unlock || !deleteAllCode || !collect || !release) return false;
    JSContextGroupRef vm = JSContextGetGroup(context);
    void *holder[2] = {NULL, NULL};
    lock(holder, vm);
    deleteAllCode(vm, 0);
    unlock(holder);
    collect(context);
    release();
    return true;
}

@interface GaryMappedScript : NSObject
+ (nullable instancetype)scriptOfType:(NSInteger)type memoryMappedFromASCIIFile:(NSURL *)file withSourceURL:(NSURL *)source andBytecodeCache:(nullable NSURL *)cache inVirtualMachine:(JSVirtualMachine *)machine error:(out NSError **)error;
@end

@interface JSContext (GaryMappedScript)
- (JSValue *)evaluateJSScript:(id)script;
@end

bool gary_evaluate_mapped(JSContext *context, NSURL *file)
{
    Class scripts = NSClassFromString(@"JSScript");
    if (![scripts respondsToSelector:@selector(scriptOfType:memoryMappedFromASCIIFile:withSourceURL:andBytecodeCache:inVirtualMachine:error:)]) return false;
    if (![context respondsToSelector:@selector(evaluateJSScript:)]) return false;
    id script = [scripts scriptOfType:0 memoryMappedFromASCIIFile:file withSourceURL:file andBytecodeCache:nil inVirtualMachine:context.virtualMachine error:nil];
    if (!script) return false;
    [context evaluateJSScript:script];
    return true;
}
