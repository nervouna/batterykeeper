#import "BatteryKeeperBridge.h"

#include <dlfcn.h>

#if !__has_feature(objc_arc)
#error "PowerUI.m must be compiled with ARC"
#endif

NSErrorDomain const BKPowerUIErrorDomain = @"io.damao.batterykeeper.PowerUI";

// The parts of PowerUISmartChargeClient this file uses. Declared on a protocol so that the
// compiler checks the calls; every selector is checked with -respondsToSelector: before use.
@protocol BKSmartChargeClient <NSObject>
- (instancetype)initWithClientName:(NSString *)name;
- (BOOL)isMCLSupported;
- (id)availableChargeLimitsWithError:(NSError **)error;
- (unsigned char)getMCLLimitWithError:(NSError **)error;
- (unsigned long long)isMCLCurrentlyEnabled:(NSError **)error;
- (BOOL)setMCLLimit:(unsigned char)limit error:(NSError **)error;
- (BOOL)enableMCL:(NSError **)error;
- (BOOL)disableMCL:(NSError **)error;
- (BOOL)temporarilyDisableMCL:(NSError **)error;
@end

static NSString *const kFrameworkPath = @"/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI";

@implementation BKPowerUI {
    id<BKSmartChargeClient> _client;
}

+ (BKPowerUI *)sharedClient {
    static BKPowerUI *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (dlopen(kFrameworkPath.fileSystemRepresentation, RTLD_NOW) == NULL) {
            return;
        }
        Class cls = NSClassFromString(@"PowerUISmartChargeClient");
        if (cls == Nil || ![cls instancesRespondToSelector:@selector(initWithClientName:)]) {
            return;
        }
        id<BKSmartChargeClient> client = [(id<BKSmartChargeClient>)[cls alloc] initWithClientName:@"io.damao.batterykeeper"];
        if (client == nil) {
            return;
        }
        shared = [[BKPowerUI alloc] initWithClient:client];
    });
    return shared;
}

- (instancetype)initWithClient:(id<BKSmartChargeClient>)client {
    if ((self = [super init])) {
        _client = client;
    }
    return self;
}

static NSError *missing(SEL selector) {
    return [NSError errorWithDomain:BKPowerUIErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey :
                                          [NSString stringWithFormat:@"PowerUI does not implement %@",
                                                                     NSStringFromSelector(selector)]}];
}

static NSError *failed(SEL selector) {
    return [NSError errorWithDomain:BKPowerUIErrorDomain
                               code:2
                           userInfo:@{NSLocalizedDescriptionKey :
                                          [NSString stringWithFormat:@"PowerUI %@ failed",
                                                                     NSStringFromSelector(selector)]}];
}

- (BOOL)supportsManualChargeLimit {
    if (![_client respondsToSelector:@selector(isMCLSupported)]) {
        return NO;
    }
    return [_client isMCLSupported];
}

- (NSArray<NSNumber *> *)availableLimitsAndReturnError:(NSError **)error {
    SEL selector = @selector(availableChargeLimitsWithError:);
    if (![_client respondsToSelector:selector]) {
        if (error) *error = missing(selector);
        return nil;
    }
    NSError *inner = nil;
    id result = [_client availableChargeLimitsWithError:&inner];
    if (![result isKindOfClass:[NSArray class]]) {
        if (error) *error = inner ?: failed(selector);
        return nil;
    }
    NSMutableArray<NSNumber *> *limits = [NSMutableArray array];
    for (id value in (NSArray *)result) {
        if ([value isKindOfClass:[NSNumber class]]) {
            [limits addObject:value];
        }
    }
    return limits;
}

- (NSNumber *)limitAndReturnError:(NSError **)error {
    SEL selector = @selector(getMCLLimitWithError:);
    if (![_client respondsToSelector:selector]) {
        if (error) *error = missing(selector);
        return nil;
    }
    NSError *inner = nil;
    unsigned char limit = [_client getMCLLimitWithError:&inner];
    if (inner != nil) {
        if (error) *error = inner;
        return nil;
    }
    return @(limit);
}

- (NSNumber *)enabledStateAndReturnError:(NSError **)error {
    SEL selector = @selector(isMCLCurrentlyEnabled:);
    if (![_client respondsToSelector:selector]) {
        if (error) *error = missing(selector);
        return nil;
    }
    NSError *inner = nil;
    unsigned long long state = [_client isMCLCurrentlyEnabled:&inner];
    if (inner != nil) {
        if (error) *error = inner;
        return nil;
    }
    return @(state);
}

- (BOOL)setLimit:(NSInteger)limit error:(NSError **)error {
    SEL selector = @selector(setMCLLimit:error:);
    if (![_client respondsToSelector:selector]) {
        if (error) *error = missing(selector);
        return NO;
    }
    if (limit < 0 || limit > 100) {
        if (error) *error = failed(selector);
        return NO;
    }
    NSError *inner = nil;
    BOOL ok = [_client setMCLLimit:(unsigned char)limit error:&inner];
    if (!ok && error) *error = inner ?: failed(selector);
    return ok;
}

- (BOOL)enableAndReturnError:(NSError **)error {
    SEL selector = @selector(enableMCL:);
    if (![_client respondsToSelector:selector]) {
        if (error) *error = missing(selector);
        return NO;
    }
    NSError *inner = nil;
    BOOL ok = [_client enableMCL:&inner];
    if (!ok && error) *error = inner ?: failed(selector);
    return ok;
}

- (BOOL)disableAndReturnError:(NSError **)error {
    SEL selector = @selector(disableMCL:);
    if (![_client respondsToSelector:selector]) {
        if (error) *error = missing(selector);
        return NO;
    }
    NSError *inner = nil;
    BOOL ok = [_client disableMCL:&inner];
    if (!ok && error) *error = inner ?: failed(selector);
    return ok;
}

- (BOOL)temporarilyDisableAndReturnError:(NSError **)error {
    SEL selector = @selector(temporarilyDisableMCL:);
    if (![_client respondsToSelector:selector]) {
        if (error) *error = missing(selector);
        return NO;
    }
    NSError *inner = nil;
    BOOL ok = [_client temporarilyDisableMCL:&inner];
    if (!ok && error) *error = inner ?: failed(selector);
    return ok;
}

@end
