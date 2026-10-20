#ifndef BATTERYKEEPER_BRIDGE_H
#define BATTERYKEEPER_BRIDGE_H

#include <IOKit/IOKitLib.h>
#include <stdint.h>

// --- AppleSMC user client -------------------------------------------------------------
//
// The SMC is reached through the AppleSMC IOService's user client: one struct method
// (selector 2) that takes and returns the same 80-byte parameter block, with a command
// byte selecting "read key", "write key" or "key info". Reads need no privileges; writes
// need root.

#pragma clang assume_nonnull begin

/// Size, type (four-character code) and attribute bits of an SMC key.
typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t attributes;
} BKSMCKeyInfo;

/// Opens a connection to the AppleSMC user client.
kern_return_t bk_smc_open(io_connect_t *connection);

void bk_smc_close(io_connect_t connection);

/// Looks up a key. On kIOReturnSuccess, *smcResult is the SMC's own result code
/// (0 for success, 132 for "key not found", ...).
kern_return_t bk_smc_key_info(io_connect_t connection, uint32_t key, BKSMCKeyInfo *info, uint8_t *smcResult);

/// Reads a key's value into bytes (at most 32). *size receives the key's size.
kern_return_t bk_smc_read(io_connect_t connection, uint32_t key, uint8_t *bytes, uint32_t capacity,
                          uint32_t *size, uint8_t *smcResult);

/// Writes size bytes (at most 32, and exactly the key's size) to a key.
kern_return_t bk_smc_write(io_connect_t connection, uint32_t key, const uint8_t *bytes, uint32_t size,
                           uint8_t *smcResult);

#pragma clang assume_nonnull end

// --- PowerUI (private) -------------------------------------------------------------------

#ifdef __OBJC__
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The system's manual charge limit ("Charge Limit" in System Settings), reached through the
/// private PowerUI framework's PowerUISmartChargeClient, which is loaded at run time. Every
/// method fails with an error in BKPowerUIErrorDomain when the framework or a selector is
/// missing, so that a macOS update that changes the private API degrades instead of crashing.
@interface BKPowerUI : NSObject

/// The client, or nil when the framework or the class cannot be loaded.
+ (nullable BKPowerUI *)sharedClient;

/// Whether this Mac supports a manual charge limit.
@property (nonatomic, readonly) BOOL supportsManualChargeLimit;

/// The limits System Settings offers, in percent.
- (nullable NSArray<NSNumber *> *)availableLimitsAndReturnError:(NSError **)error;

/// The limit in percent, as the system stores it.
- (nullable NSNumber *)limitAndReturnError:(NSError **)error;

/// The enabled state as the system reports it: 0 off, 1 on; other values are passed on.
- (nullable NSNumber *)enabledStateAndReturnError:(NSError **)error;

- (BOOL)setLimit:(NSInteger)limit error:(NSError **)error;
- (BOOL)enableAndReturnError:(NSError **)error;
- (BOOL)disableAndReturnError:(NSError **)error;

/// "Charge to Full Now": lifts the limit until the system restores it.
- (BOOL)temporarilyDisableAndReturnError:(NSError **)error;

@end

extern NSErrorDomain const BKPowerUIErrorDomain;

NS_ASSUME_NONNULL_END

#endif // __OBJC__

#endif // BATTERYKEEPER_BRIDGE_H
