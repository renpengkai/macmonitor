//
// Sampler.swift
// MacMonitor
// 采集 CPU、内存、功率、温度、风扇数据。仅在 Monitor 的串行队列上调用, 内部状态无需加锁。
//

import Foundation
import IOKit
import IOKit.ps
import SMCKit

struct CPUStat {
    var total = 0.0
    var user = 0.0
    var system = 0.0
    var cores: [Double] = []
}

struct MemoryStat {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var swap: UInt64 = 0
    /// kern.memorystatus_vm_pressure_level: 1 正常, 2 警告, 4 严重
    var pressure: Int32 = 1

    var usage: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct PowerStat {
    /// SMC `PSTR`: 整机功耗 (W)
    var system: Double?
    /// SMC `PDTR`: 外部电源输入功率 (W)
    var input: Double?
    /// 电池功率 (W), 正为充电、负为放电
    var battery: Double?
    var batteryLevel: Int?
    var charging = false
    var external = false
    /// 电源适配器额定功率 (W)
    var adapterWatts: Int?
}

struct Temperature: Identifiable {
    let name: String
    let average: Double
    let max: Double
    var id: String { name }
}

struct Snapshot {
    var cpu = CPUStat()
    var memory = MemoryStat()
    var power = PowerStat()
    var temps: [Temperature] = []
    var fans: [FanInfo] = []
}

final class Sampler {

    /// 按 SMC 温度键前两位归类 (Apple Silicon): Tp/Te/Tf 为 CPU 性能核/能效核, Tg 为 GPU
    private static let groups: [(name: String, prefixes: [String])] = [
        ("CPU", ["Tp", "Te", "Tf"]),
        ("GPU", ["Tg"]),
        ("内存", ["Tm"]),
        ("固态硬盘", ["TH"]),
        ("电池", ["TB"]),
    ]

    private let smc = SMC()
    private let host = mach_host_self()
    private var prevTicks: [[UInt32]] = []
    private var tempKeys: [(name: String, keys: [String])]?

    func sample() -> Snapshot {
        Snapshot(cpu: cpu(), memory: memory(), power: power(), temps: temperatures(), fans: smc?.fans() ?? [])
    }

    // MARK: - CPU

    private func cpu() -> CPUStat {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return CPUStat() }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        var ticks: [[UInt32]] = []
        for i in 0..<Int(count) {
            ticks.append((0..<states).map { UInt32(bitPattern: info[i * states + $0]) })
        }
        defer { prevTicks = ticks }
        // 首次采样没有基准, 核数变化 (理论上不会) 时也重新建立基准
        guard prevTicks.count == ticks.count else { return CPUStat() }

        var stat = CPUStat()
        var sumUser = 0.0, sumSystem = 0.0, sumAll = 0.0
        for (cur, old) in zip(ticks, prevTicks) {
            // 计数器是会回绕的 32 位值, 用回绕减法求增量
            let user = Double(cur[Int(CPU_STATE_USER)] &- old[Int(CPU_STATE_USER)])
                + Double(cur[Int(CPU_STATE_NICE)] &- old[Int(CPU_STATE_NICE)])
            let system = Double(cur[Int(CPU_STATE_SYSTEM)] &- old[Int(CPU_STATE_SYSTEM)])
            let idle = Double(cur[Int(CPU_STATE_IDLE)] &- old[Int(CPU_STATE_IDLE)])
            let all = user + system + idle
            stat.cores.append(all > 0 ? (user + system) / all : 0)
            sumUser += user
            sumSystem += system
            sumAll += all
        }
        if sumAll > 0 {
            stat.user = sumUser / sumAll
            stat.system = sumSystem / sumAll
            stat.total = stat.user + stat.system
        }
        return stat
    }

    // MARK: - 内存

    private func memory() -> MemoryStat {
        var stat = MemoryStat()
        stat.total = ProcessInfo.processInfo.physicalMemory

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let rc = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if rc == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            // 与「活动监视器」口径一致: 可被回收的可清除页与文件缓存 (external) 不计入已用
            let gross = UInt64(vm.active_count) + UInt64(vm.inactive_count) + UInt64(vm.speculative_count)
                + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)
            let reclaimable = UInt64(vm.purgeable_count) + UInt64(vm.external_page_count)
            stat.used = (gross > reclaimable ? gross - reclaimable : 0) * page
            let internalPages = UInt64(vm.internal_page_count)
            let purgeable = UInt64(vm.purgeable_count)
            stat.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            stat.wired = UInt64(vm.wire_count) * page
            stat.compressed = UInt64(vm.compressor_page_count) * page
        }

        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            stat.pressure = level
        }
        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            stat.swap = swap.xsu_used
        }
        return stat
    }

    // MARK: - 功率

    private func power() -> PowerStat {
        var stat = PowerStat()
        // 读数偶发为负或 0 (未上报), 只保留有意义的正值
        stat.system = smc?.number("PSTR").flatMap { $0 > 0 ? $0 : nil }
        stat.input = smc?.number("PDTR").flatMap { $0 > 0.5 ? $0 : nil }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            func prop(_ key: String) -> NSNumber? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSNumber
            }
            stat.external = prop("ExternalConnected")?.boolValue ?? false
            stat.charging = prop("IsCharging")?.boolValue ?? false
            if let cur = prop("CurrentCapacity")?.doubleValue, let max = prop("MaxCapacity")?.doubleValue, max > 0 {
                // Apple Silicon 上两者已是百分比 (Max 为 100); Intel 上是 mAh, 比值同样适用
                stat.batteryLevel = Int((cur / max * 100).rounded())
            }
            // 电流以有符号 64 位存储, 放电为负; 取 int64Value 以免被当作超大无符号数
            if let mv = prop("Voltage")?.doubleValue,
               let ma = (prop("InstantAmperage") ?? prop("Amperage"))?.int64Value {
                stat.battery = mv * Double(ma) / 1_000_000
            }
        }

        if let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
           let watts = details["Watts"] as? Int {
            stat.adapterWatts = watts
        }
        return stat
    }

    // MARK: - 温度

    /// 首次调用时枚举全部 SMC 键并按部件归类, 之后只读取这些键
    private func discoverTempKeys() -> [(name: String, keys: [String])] {
        guard let smc else { return [] }
        let candidates = smc.allKeys().filter { $0.hasPrefix("T") }
        var result: [(name: String, keys: [String])] = []
        for group in Sampler.groups {
            let keys = candidates.filter { key in
                guard group.prefixes.contains(where: { key.hasPrefix($0) }) else { return false }
                // 剔除未接入的传感器 (恒为 0 或异常大值)
                guard let v = smc.number(key) else { return false }
                return v > 1 && v < 130
            }
            if !keys.isEmpty { result.append((name: group.name, keys: keys)) }
        }
        return result
    }

    private func temperatures() -> [Temperature] {
        guard let smc else { return [] }
        if tempKeys == nil { tempKeys = discoverTempKeys() }
        return (tempKeys ?? []).compactMap { group -> Temperature? in
            let values = group.keys.compactMap { smc.number($0) }.filter { $0 > 1 && $0 < 130 }
            guard let peak = values.max() else { return nil }
            return Temperature(name: group.name, average: values.reduce(0, +) / Double(values.count), max: peak)
        }
    }
}
