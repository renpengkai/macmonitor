//
// Fans.swift
// SMCKit
// 风扇读取与控制。读取无需权限; 写入 (手动/自动切换、目标转速) 需要 root, 由 mmfanctl 执行。
//

import Darwin

public struct FanInfo: Equatable {
    public let id: Int
    /// 当前转速 (RPM)
    public let current: Double
    public let min: Double
    public let max: Double
    /// 目标转速; 自动模式下通常为 0 或系统设定值
    public let target: Double
    /// 是否处于手动 (强制) 模式
    public let manual: Bool
}

extension SMC {

    public var fanCount: Int {
        Int(number("FNum") ?? 0)
    }

    /// 部分 Apple Silicon 机型使用小写 `F0md` 作为模式键
    private func modeKey(_ id: Int) -> String {
        has("F\(id)md") ? "F\(id)md" : "F\(id)Md"
    }

    public func fans() -> [FanInfo] {
        (0..<fanCount).compactMap { id -> FanInfo? in
            guard let current = number("F\(id)Ac") else { return nil }
            return FanInfo(
                id: id,
                current: Swift.max(current, 0),
                min: number("F\(id)Mn") ?? 0,
                max: number("F\(id)Mx") ?? 0,
                target: number("F\(id)Tg") ?? 0,
                manual: (number(modeKey(id)) ?? 0) == 1
            )
        }
    }

    /// 刚交出控制权时 SMC 会短暂拒绝写入, 需重试
    private func writeRetry(_ key: String, _ bytes: [UInt8], attempts: Int = 10, delay: UInt32 = 50_000) -> Bool {
        for i in 0..<attempts {
            if write(key, bytes) { return true }
            if i < attempts - 1 { usleep(delay) }
        }
        return false
    }

    /// 切到手动模式。M5 起可直接写模式键; M1~M4 需先置 `Ftst`=1 让 thermalmonitord 让出控制权
    private func unlock(_ id: Int) -> Bool {
        let key = modeKey(id)
        if write(key, [1]) { return true }
        guard let ftst = read("Ftst") else { return false }
        if ftst.bytes.first != 1 {
            guard writeRetry("Ftst", [1], attempts: 100) else { return false }
            // thermalmonitord 需要数秒才会真正释放, 过早写模式键会一直失败
            usleep(3_000_000)
        }
        return writeRetry(key, [1], attempts: 300, delay: 100_000)
    }

    private func encodeRPM(_ key: String, _ rpm: Double) -> [UInt8]? {
        switch dataType(key) {
        case "flt ":
            let raw = Float(rpm).bitPattern
            return [UInt8(raw & 0xff), UInt8(raw >> 8 & 0xff), UInt8(raw >> 16 & 0xff), UInt8(raw >> 24 & 0xff)]
        case "fpe2":
            let v = UInt16(clamping: Int(rpm * 4))
            return [UInt8(v >> 8), UInt8(v & 0xff)]
        default:
            return nil
        }
    }

    /// 设置手动转速, 自动夹在该风扇的最小/最大转速之间
    public func setFan(_ id: Int, rpm: Double) -> Bool {
        guard id >= 0, id < fanCount else { return false }
        let lo = number("F\(id)Mn") ?? 0
        let hi = number("F\(id)Mx") ?? rpm
        let value = Swift.min(Swift.max(rpm, lo), hi)
        let target = "F\(id)Tg"
        guard let bytes = encodeRPM(target, value) else { return false }
        if (number(modeKey(id)) ?? 0) != 1, !unlock(id) { return false }
        return writeRetry(target, bytes)
    }

    /// 恢复单个风扇为系统自动控制; 所有风扇都自动后撤销 `Ftst` 解锁
    public func setFanAuto(_ id: Int) -> Bool {
        guard id >= 0, id < fanCount else { return false }
        var ok = writeRetry(modeKey(id), [0])
        if let zero = encodeRPM("F\(id)Tg", 0) { _ = writeRetry("F\(id)Tg", zero) }
        let anyManual = fans().contains { $0.manual }
        if !anyManual, let ftst = read("Ftst"), ftst.bytes.first == 1 {
            ok = writeRetry("Ftst", [0]) && ok
        }
        return ok
    }

    /// 全部风扇恢复自动, 应用退出时调用, 避免风扇停留在手动转速
    public func resetFans() -> Bool {
        var ok = true
        for id in 0..<fanCount where !setFanAuto(id) { ok = false }
        if let ftst = read("Ftst"), ftst.bytes.first == 1 {
            ok = writeRetry("Ftst", [0]) && ok
        }
        return ok
    }
}
