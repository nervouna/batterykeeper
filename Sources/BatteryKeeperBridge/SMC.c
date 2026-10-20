#include "BatteryKeeperBridge.h"

#include <string.h>

// The parameter block of the AppleSMC user client. The layout is fixed by the kernel
// extension; the static assert below guards it.
typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyInfoData;

typedef struct {
    uint32_t key;
    SMCVersion version;
    SMCPLimitData pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParamStruct;

_Static_assert(sizeof(SMCParamStruct) == 80, "SMCParamStruct must be 80 bytes");

enum {
    kSMCUserClientSelector = 2,
    kSMCCommandReadKey = 5,
    kSMCCommandWriteKey = 6,
    kSMCCommandGetKeyInfo = 9,
};

static kern_return_t smc_call(io_connect_t connection, SMCParamStruct *input, SMCParamStruct *output) {
    size_t outputSize = sizeof(SMCParamStruct);
    return IOConnectCallStructMethod(connection, kSMCUserClientSelector, input, sizeof(SMCParamStruct),
                                     output, &outputSize);
}

kern_return_t bk_smc_open(io_connect_t *connection) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) {
        return kIOReturnNotFound;
    }
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, connection);
    IOObjectRelease(service);
    return result;
}

void bk_smc_close(io_connect_t connection) {
    IOServiceClose(connection);
}

kern_return_t bk_smc_key_info(io_connect_t connection, uint32_t key, BKSMCKeyInfo *info, uint8_t *smcResult) {
    SMCParamStruct input, output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = key;
    input.data8 = kSMCCommandGetKeyInfo;
    kern_return_t result = smc_call(connection, &input, &output);
    if (result != kIOReturnSuccess) {
        return result;
    }
    *smcResult = output.result;
    info->dataSize = output.keyInfo.dataSize;
    info->dataType = output.keyInfo.dataType;
    info->attributes = output.keyInfo.dataAttributes;
    return kIOReturnSuccess;
}

kern_return_t bk_smc_read(io_connect_t connection, uint32_t key, uint8_t *bytes, uint32_t capacity,
                          uint32_t *size, uint8_t *smcResult) {
    BKSMCKeyInfo info;
    kern_return_t result = bk_smc_key_info(connection, key, &info, smcResult);
    if (result != kIOReturnSuccess || *smcResult != 0) {
        return result;
    }
    SMCParamStruct input, output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = key;
    input.keyInfo.dataSize = info.dataSize;
    input.data8 = kSMCCommandReadKey;
    result = smc_call(connection, &input, &output);
    if (result != kIOReturnSuccess) {
        return result;
    }
    *smcResult = output.result;
    uint32_t n = info.dataSize < 32 ? info.dataSize : 32;
    if (n > capacity) {
        n = capacity;
    }
    memcpy(bytes, output.bytes, n);
    *size = info.dataSize;
    return kIOReturnSuccess;
}

kern_return_t bk_smc_write(io_connect_t connection, uint32_t key, const uint8_t *bytes, uint32_t size,
                           uint8_t *smcResult) {
    if (size > 32) {
        return kIOReturnBadArgument;
    }
    SMCParamStruct input, output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = key;
    input.keyInfo.dataSize = size;
    input.data8 = kSMCCommandWriteKey;
    memcpy(input.bytes, bytes, size);
    kern_return_t result = smc_call(connection, &input, &output);
    if (result != kIOReturnSuccess) {
        return result;
    }
    *smcResult = output.result;
    return kIOReturnSuccess;
}
