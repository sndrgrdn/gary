#import "GaryPrivate.h"
#include <dlfcn.h>

#define SKYLIGHT "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
#define DISPLAY_SERVICES "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
#define IOKIT_FRAMEWORK "/System/Library/Frameworks/IOKit.framework/IOKit"

static const GaryPrivateSymbol symbols[] = {
    [GarySymbolExecutionTimeLimit] = {"/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", "JSContextGroupSetExecutionTimeLimit", "plugin script time limit"},
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
