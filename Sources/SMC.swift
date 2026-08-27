import Foundation
import IOKit

// SMC client adapted from MacsFan (MIT). Canonical SMCParamStruct layout.

private struct SMCVersion {
    var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0, length: UInt16 = 0
    var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private let kEmptyBytes: SMCBytes = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
)

private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = kEmptyBytes
}

private let kSMCHandleYPCEvent: UInt32 = 2
private let kSMCReadKey: UInt8 = 5
private let kSMCWriteKey: UInt8 = 6
private let kSMCGetKeyFromIndex: UInt8 = 8
private let kSMCGetKeyInfo: UInt8 = 9

final class SMC {
    struct KeyInfo {
        var dataSize: UInt32
        var dataType: UInt32
        var typeString: String { SMC.fourCCToString(dataType) }
    }

    private var conn: io_connect_t = 0
    var isOpen: Bool { conn != 0 }

    @discardableResult
    func open() -> Bool {
        guard conn == 0 else { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess
    }

    func close() {
        if conn != 0 {
            IOServiceClose(conn)
            conn = 0
        }
    }

    deinit { close() }

    static func fourCC(_ string: String) -> UInt32 {
        var result: UInt32 = 0
        for char in string.utf8.prefix(4) { result = (result << 8) | UInt32(char) }
        return result
    }

    static func fourCCToString(_ value: UInt32) -> String {
        let chars: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        return String(bytes: chars, encoding: .ascii) ?? "????"
    }

    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        guard conn != 0 else { return nil }
        var output = SMCParamStruct()
        let size = MemoryLayout<SMCParamStruct>.stride
        var outSize = size
        let ret = IOConnectCallStructMethod(conn, kSMCHandleYPCEvent, &input, size, &output, &outSize)
        return ret == kIOReturnSuccess ? output : nil
    }

    func keyInfo(_ key: String) -> KeyInfo? {
        var input = SMCParamStruct()
        input.key = SMC.fourCC(key)
        input.data8 = kSMCGetKeyInfo
        guard let out = call(&input), out.result == 0 else { return nil }
        return KeyInfo(dataSize: out.keyInfo.dataSize, dataType: out.keyInfo.dataType)
    }

    func readData(_ key: String) -> (info: KeyInfo, bytes: [UInt8])? {
        guard let info = keyInfo(key) else { return nil }
        var input = SMCParamStruct()
        input.key = SMC.fourCC(key)
        input.keyInfo.dataSize = info.dataSize
        input.keyInfo.dataType = info.dataType
        input.data8 = kSMCReadKey
        guard let out = call(&input), out.result == 0 else { return nil }
        let count = min(Int(info.dataSize), 32)
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(count)) }
        return (info, bytes)
    }

    @discardableResult
    func writeData(_ key: String, bytes: [UInt8]) -> Bool {
        guard let info = keyInfo(key) else { return false }
        var input = SMCParamStruct()
        input.key = SMC.fourCC(key)
        input.keyInfo.dataSize = info.dataSize
        input.keyInfo.dataType = info.dataType
        input.data8 = kSMCWriteKey
        withUnsafeMutableBytes(of: &input.bytes) { dst in
            for (i, b) in bytes.prefix(32).enumerated() { dst[i] = b }
        }
        guard let out = call(&input) else { return false }
        return out.result == 0
    }

    func keyCount() -> Int {
        guard let (_, bytes) = readData("#KEY"), bytes.count >= 4 else { return 0 }
        return Int(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
    }

    func key(atIndex index: Int) -> String? {
        var input = SMCParamStruct()
        input.data8 = kSMCGetKeyFromIndex
        input.data32 = UInt32(index)
        guard let out = call(&input), out.result == 0 else { return nil }
        return SMC.fourCCToString(out.key)
    }

    func readDouble(_ key: String) -> Double? {
        guard let (info, bytes) = readData(key) else { return nil }
        return SMC.decode(type: info.typeString, bytes: bytes)
    }

    static func decode(type: String, bytes: [UInt8]) -> Double? {
        func beInt(_ b: [UInt8]) -> UInt64 {
            b.reduce(0) { ($0 << 8) | UInt64($1) }
        }
        switch true {
        case type == "flt " && bytes.count >= 4:
            let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: raw))
        case type.hasPrefix("fp") && bytes.count >= 2:
            let frac = Int(String(type.suffix(1)), radix: 16) ?? 0
            return Double(beInt(Array(bytes.prefix(2)))) / Double(1 << frac)
        case type.hasPrefix("sp") && bytes.count >= 2:
            let frac = Int(String(type.suffix(1)), radix: 16) ?? 0
            let raw = Int16(bitPattern: UInt16(beInt(Array(bytes.prefix(2)))))
            return Double(raw) / Double(1 << frac)
        case type == "ui8 " && bytes.count >= 1:
            return Double(bytes[0])
        case type == "ui16" && bytes.count >= 2:
            return Double(beInt(Array(bytes.prefix(2))))
        case type == "ui32" && bytes.count >= 4:
            return Double(beInt(Array(bytes.prefix(4))))
        case type == "flag" && bytes.count >= 1:
            return Double(bytes[0])
        default:
            return nil
        }
    }

    func readUInt8(_ key: String) -> UInt8? {
        guard let (_, bytes) = readData(key), let first = bytes.first else { return nil }
        return first
    }

    @discardableResult
    func writeDouble(_ key: String, value: Double) -> Bool {
        guard let info = keyInfo(key) else { return false }
        let type = info.typeString
        var bytes = [UInt8](repeating: 0, count: max(Int(info.dataSize), 4))
        if type == "flt " {
            var f = Float(value)
            withUnsafeBytes(of: &f) { src in
                for i in 0..<4 { bytes[i] = src[i] }
            }
        } else if type.hasPrefix("fp") {
            let frac = Int(String(type.suffix(1)), radix: 16) ?? 0
            let raw = UInt16(max(0, min(65535, value * Double(1 << frac))))
            bytes[0] = UInt8(raw >> 8)
            bytes[1] = UInt8(raw & 0xFF)
        } else if type == "ui8 " || type == "flag" {
            bytes[0] = UInt8(max(0, min(255, value)))
        } else {
            return false
        }
        return writeData(key, bytes: Array(bytes.prefix(Int(info.dataSize))))
    }
}
