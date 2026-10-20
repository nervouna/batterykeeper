import BatteryKeeperBridge
import Foundation
import IOKit

public struct SMCError: Error, CustomStringConvertible, Sendable {
    public var key: String
    /// The IOKit return code of the call.
    public var kernelResult: kern_return_t
    /// The SMC's own result code (132 is "key not found").
    public var smcResult: UInt8

    public init(key: String, kernelResult: kern_return_t, smcResult: UInt8) {
        self.key = key
        self.kernelResult = kernelResult
        self.smcResult = smcResult
    }

    public var description: String {
        "SMC key \(key): kern_return 0x\(String(UInt32(bitPattern: kernelResult), radix: 16)), SMC result \(smcResult)"
    }
}

public struct SMCKeyInfo: Sendable, Equatable {
    public var size: Int
    /// Four-character type code, such as "flt " or "hex_".
    public var type: String
    public var attributes: UInt8
}

/// A connection to the AppleSMC user client. Reads work for any user; writes need root.
/// Calls are serialized, so one client can be shared between threads.
public final class SMCClient: @unchecked Sendable {
    private let connection: io_connect_t
    private let lock = NSLock()

    public init() throws(SMCError) {
        var connection: io_connect_t = 0
        let result = bk_smc_open(&connection)
        guard result == kIOReturnSuccess else { throw SMCError(key: "", kernelResult: result, smcResult: 0) }
        self.connection = connection
    }

    deinit {
        bk_smc_close(connection)
    }

    public func keyInfo(_ key: String) throws(SMCError) -> SMCKeyInfo {
        var info = BKSMCKeyInfo()
        var smcResult: UInt8 = 0
        let result = lock.withLock { bk_smc_key_info(connection, Self.code(key), &info, &smcResult) }
        guard result == kIOReturnSuccess, smcResult == 0 else {
            throw SMCError(key: key, kernelResult: result, smcResult: smcResult)
        }
        return SMCKeyInfo(size: Int(info.dataSize), type: Self.string(info.dataType), attributes: info.attributes)
    }

    public func read(_ key: String) throws(SMCError) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        var size: UInt32 = 0
        var smcResult: UInt8 = 0
        let result = lock.withLock {
            bytes.withUnsafeMutableBufferPointer { buffer in
                bk_smc_read(connection, Self.code(key), buffer.baseAddress!, 32, &size, &smcResult)
            }
        }
        guard result == kIOReturnSuccess, smcResult == 0 else {
            throw SMCError(key: key, kernelResult: result, smcResult: smcResult)
        }
        return Array(bytes.prefix(Int(min(size, 32))))
    }

    public func write(_ key: String, _ bytes: [UInt8]) throws(SMCError) {
        var smcResult: UInt8 = 0
        let result = lock.withLock {
            bytes.withUnsafeBufferPointer { buffer in
                bk_smc_write(connection, Self.code(key), buffer.baseAddress!, UInt32(bytes.count), &smcResult)
            }
        }
        guard result == kIOReturnSuccess, smcResult == 0 else {
            throw SMCError(key: key, kernelResult: result, smcResult: smcResult)
        }
    }

    /// Reads a key of type "flt ": a 32-bit float, little-endian on Apple silicon.
    public func readFloat(_ key: String) throws(SMCError) -> Float {
        let bytes = try read(key)
        guard bytes.count == 4 else { throw SMCError(key: key, kernelResult: kIOReturnBadArgument, smcResult: 0) }
        let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        return Float(bitPattern: bits)
    }

    static func code(_ key: String) -> UInt32 {
        var value: UInt32 = 0
        for byte in key.utf8.prefix(4) { value = value << 8 | UInt32(byte) }
        return value
    }

    static func string(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
