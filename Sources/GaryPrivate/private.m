#import "GaryPrivate.h"
#include <dlfcn.h>

enum { GaryExecutionTimeLimit };

static const GaryPrivateSymbol symbols[] = {
    [GaryExecutionTimeLimit] = {"/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", "JSContextGroupSetExecutionTimeLimit", "plugin script time limit"},
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
        setTimeLimit = (SetTimeLimit)gary_private_resolve(GaryExecutionTimeLimit);
    });
    if (!setTimeLimit) return false;
    setTimeLimit(JSContextGetGroup(context), seconds, callback, info);
    return true;
}
