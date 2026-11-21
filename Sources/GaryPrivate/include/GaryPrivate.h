#pragma once
#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_OPTIONS(uint32_t, GaryCapability) {
    GaryCapabilityDisplaySpaces = 1 << 0,
    GaryCapabilityActiveSpace = 1 << 1,
    GaryCapabilitySpaceEvents = 1 << 2,
    GaryCapabilityScriptTimeLimit = 1 << 3,
};

GaryCapability gary_capabilities(void);

@interface GaryDisplaySpaces : NSObject
@property (nonatomic, copy) NSString *uuid;
@property (nonatomic) uint64_t currentSpaceID;
@property (nonatomic, copy) NSArray<NSNumber *> *userSpaceIDs;
@end

NSArray<GaryDisplaySpaces *> *gary_display_spaces(void);

uint64_t gary_active_space(void);

typedef NS_ENUM(uint32_t, GarySpaceEvent) {
    GarySpaceEventCreated = 1327,
    GarySpaceEventDestroyed = 1328,
    GarySpaceEventChanged = 1401,
};

typedef void (*GarySpaceEventCallback)(GarySpaceEvent event, void *_Nullable context);

bool gary_space_events_start(GarySpaceEventCallback callback, void *_Nullable context);

typedef bool (*GaryShouldTerminate)(JSContextRef context, void *_Nullable info);

bool gary_script_time_limit(JSGlobalContextRef context, double seconds, GaryShouldTerminate callback, void *_Nullable info);

NS_ASSUME_NONNULL_END
