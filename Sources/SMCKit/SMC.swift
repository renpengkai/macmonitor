//
// SMC.swift
// SMCKit
// AppleSMC 用户态访问: 读写键值、枚举键、解码常见数据类型。
// 结构体布局与命令号参考 exelban/stats (MIT), 并已在 Apple M5 上实测验证。
//

import Darwin
import IOKit

/// 与内核 AppleSMC 交换的 80 字节结构体, 字段偏移必须与 C 版 SMCKeyData_t 一致
struct SMCKeyData {
    typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct PLimit {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = Version()
    var pLimit = PLimit()
    var keyInfo = KeyInfo()
    // Swift 会把后续字段塞进 KeyInfo 的尾部填充, 手动占位让 result 落在偏移 40 (与 C 布局一致)
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

/// 一次读取得到的原始键值
public struct SMCValue {
    public let key: String
    /// 四字符类型码, 如 `flt `、`ui8 `、`sp78`
    public let type: String
    public let bytes: [UInt8]

    /// 按类型解码为数值; 未知类型返回 nil
    public var number: Double? {
        guard !bytes.isEmpty else { return nil }
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            // Apple Silicon 上 flt 为本机小端 IEEE754, 其余整数类型为大端
            return Double(Float(bitPattern: bigEndian(bytes[0..<4].reversed())))
        case "ui8 ", "flag":
            return Double(bytes[0])
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(bigEndian(bytes[0..<2]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(bigEndian(bytes[0..<4]))
        case "si16":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bigEndian(bytes[0..<2]))))
        default:
            return fixedPoint
        }
    }

    private func bigEndian<S: Sequence>(_ seq: S) -> UInt32 where S.Element == UInt8 {
        seq.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    /// `spXY` / `fpXY`: 大端 16 位定点数, Y (十六进制) 为小数位数, sp 有符号、fp 无符号
    private var fixedPoint: Double? {
        let chars = Array(type)
        guard chars.count == 4, bytes.count >= 2,
              chars[1] == "p", chars[0] == "s" || chars[0] == "f",
              let frac = Int(String(chars[3]), radix: 16) else { return nil }
        let raw = UInt16(bigEndian(bytes[0..<2]))
        let value = chars[0] == "s" ? Double(Int16(bitPattern: raw)) : Double(raw)
        return value / Double(1 << frac)
    }
}

public final class SMC {

    private enum Command: UInt8 {
        case readBytes = 5
        case writeBytes = 6
        case readIndex = 8
        case readKeyInfo = 9
    }

    private struct Info {
        let size: UInt32
        let type: UInt32
    }

    /// IOConnectCallStructMethod 的选择子 kSMCHandleYPCEvent; 具体命令放在 data8
    private static let selector: UInt32 = 2

    private var conn: io_connect_t = 0
    /// 键信息在系统运行期间不会变化, 缓存后每次读取只需一次内核调用
    private var infoCache: [UInt32: Info] = [:]
    private var missing: Set<UInt32> = []

    /// 打开 AppleSMC 连接; 虚拟机等没有 SMC 的环境返回 nil
    public init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }

    deinit {
        IOServiceClose(conn)
    }

    public static func fourCC(_ key: String) -> UInt32 {
        key.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    public static func string(_ code: UInt32) -> String {
        let bytes = [UInt8(code >> 24 & 0xff), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]
        return String(decoding: bytes, as: UTF8.self)
    }

    private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
        var output = SMCKeyData()
        var outSize = MemoryLayout<SMCKeyData>.stride
        let rc = IOConnectCallStructMethod(conn, SMC.selector, &input, MemoryLayout<SMCKeyData>.stride,
                                           &output, &outSize)
        // kern 返回成功但 SMC 自身 result 非 0 (如 0x84 键不存在) 同样视为失败
        guard rc == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private func info(_ code: UInt32) -> Info? {
        if let cached = infoCache[code] { return cached }
        if missing.contains(code) { return nil }
        var input = SMCKeyData()
        input.key = code
        input.data8 = Command.readKeyInfo.rawValue
        guard let out = call(&input), out.keyInfo.dataSize > 0, out.keyInfo.dataSize <= 32 else {
            missing.insert(code)
            return nil
        }
        let value = Info(size: out.keyInfo.dataSize, type: out.keyInfo.dataType)
        infoCache[code] = value
        return value
    }

    public func has(_ key: String) -> Bool {
        info(SMC.fourCC(key)) != nil
    }

    public func read(_ key: String) -> SMCValue? {
        let code = SMC.fourCC(key)
        guard let info = info(code) else { return nil }
        var input = SMCKeyData()
        input.key = code
        input.keyInfo.dataSize = info.size
        input.data8 = Command.readBytes.rawValue
        guard var out = call(&input) else { return nil }
        let bytes = withUnsafeBytes(of: &out.bytes) { Array($0.prefix(Int(info.size))) }
        return SMCValue(key: key, type: SMC.string(info.type), bytes: bytes)
    }

    public func number(_ key: String) -> Double? {
        read(key)?.number
    }

    /// 写入原始字节 (长度不足按 0 补齐到键的数据长度)。写操作需要 root
    @discardableResult
    public func write(_ key: String, _ bytes: [UInt8]) -> Bool {
        let code = SMC.fourCC(key)
        guard let info = info(code) else { return false }
        var input = SMCKeyData()
        input.key = code
        input.keyInfo.dataSize = info.size
        input.data8 = Command.writeBytes.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { buf in
            for (i, b) in bytes.prefix(Int(info.size)).enumerated() { buf[i] = b }
        }
        return call(&input) != nil
    }

    /// 枚举全部键名 (约 2~3 千个, 耗时数十毫秒, 调用方应缓存结果)
    public func allKeys() -> [String] {
        guard let count = number("#KEY"), count > 0 else { return [] }
        var keys: [String] = []
        keys.reserveCapacity(Int(count))
        for i in 0..<UInt32(count) {
            var input = SMCKeyData()
            input.data8 = Command.readIndex.rawValue
            input.data32 = i
            guard let out = call(&input), out.key != 0 else { continue }
            keys.append(SMC.string(out.key))
        }
        return keys
    }

    /// 键的类型码, 用于写入时选择编码
    public func dataType(_ key: String) -> String? {
        info(SMC.fourCC(key)).map { SMC.string($0.type) }
    }
}
