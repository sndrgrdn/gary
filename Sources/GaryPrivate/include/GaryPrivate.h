#pragma once
#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, GarySymbol) {
    GarySymbolExecutionTimeLimit,
    GarySymbolMainConnectionID,
    GarySymbolSetMenuBarInsetAndAlpha,
    GarySymbolGetDockRect,
    GarySymbolSetDockRect,
    GarySymbolDockGetAutoHide,
    GarySymbolDockSetAutoHide,
    GarySymbolWindowListCreateImage,
    GarySymbolBluetoothSetPower,
    GarySymbolGetBrightness,
    GarySymbolSetBrightness,
    GarySymbolRegisterBrightnessChanges,
    GarySymbolAVServiceCreate,
    GarySymbolAVServiceReadI2C,
    GarySymbolAVServiceWriteI2C,
    GarySymbolDisplayInfo,
    GarySymbolTCCAccessPreflight,
    GarySymbolTCCAccessRequest,
};

typedef struct {
    const char *library;
    const char *symbol;
    const char *feature;
} GaryPrivateSymbol;

size_t gary_private_symbol_count(void);
GaryPrivateSymbol gary_private_symbol(size_t index);
void *_Nullable gary_private_resolve(size_t index);

typedef bool (*GaryShouldTerminate)(JSContextRef context, void *_Nullable info);

bool gary_script_time_limit(JSGlobalContextRef context, double seconds, GaryShouldTerminate callback, void *_Nullable info);

NS_ASSUME_NONNULL_END
