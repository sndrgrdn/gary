#pragma once
#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>

NS_ASSUME_NONNULL_BEGIN

typedef bool (*GaryShouldTerminate)(JSContextRef context, void *_Nullable info);

bool gary_script_time_limit(JSGlobalContextRef context, double seconds, GaryShouldTerminate callback, void *_Nullable info);

NS_ASSUME_NONNULL_END
