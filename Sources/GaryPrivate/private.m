#import "GaryPrivate.h"
#include <dlfcn.h>

typedef void (*SetTimeLimit)(JSContextGroupRef group, double limit, GaryShouldTerminate callback, void *info);

bool gary_script_time_limit(JSGlobalContextRef context, double seconds, GaryShouldTerminate callback, void *info)
{
    static SetTimeLimit setTimeLimit;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *jsc = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_LAZY);
        if (jsc) setTimeLimit = dlsym(jsc, "JSContextGroupSetExecutionTimeLimit");
    });
    if (!setTimeLimit) return false;
    setTimeLimit(JSContextGetGroup(context), seconds, callback, info);
    return true;
}
