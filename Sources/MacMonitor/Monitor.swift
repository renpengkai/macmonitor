//
// Monitor.swift
// MacMonitor
// 定时采样并向界面发布最新快照与历史曲线。
//

import Foundation

final class Monitor: ObservableObject {

    static let historyLength = 60

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var powerHistory: [Double] = []

    @Published var interval: Double {
        didSet {
            UserDefaults.standard.set(interval, forKey: Settings.interval)
            timer?.schedule(deadline: .now() + interval, repeating: interval)
        }
    }

    /// 每次发布新快照后在主线程回调, 用于刷新菜单栏
    var onUpdate: (() -> Void)?

    private let queue = DispatchQueue(label: "macmonitor.sampler", qos: .utility)
    private let sampler = Sampler()
    private var timer: DispatchSourceTimer?

    init() {
        let saved = UserDefaults.standard.double(forKey: Settings.interval)
        interval = saved > 0 ? saved : 2
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // 允许系统合并唤醒, 降低菜单栏常驻的能耗
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let snap = self.sampler.sample()
            DispatchQueue.main.async { self.publish(snap) }
        }
        timer.resume()
        self.timer = timer
    }

    private func publish(_ snap: Snapshot) {
        snapshot = snap
        cpuHistory = Monitor.append(cpuHistory, snap.cpu.total)
        if let watts = snap.power.system ?? snap.power.battery.map({ abs($0) }) {
            powerHistory = Monitor.append(powerHistory, watts)
        }
        onUpdate?()
    }

    private static func append(_ history: [Double], _ value: Double) -> [Double] {
        var h = history
        h.append(value)
        if h.count > historyLength { h.removeFirst(h.count - historyLength) }
        return h
    }
}

enum Settings {
    static let interval = "interval"
    static let barCPU = "bar.cpu"
    static let barMemory = "bar.memory"
    static let barTemp = "bar.temp"
    static let barPower = "bar.power"
    static let barFan = "bar.fan"
    /// 锁定的风扇转速: UserDefaults 存 `[String: Double]`, key 为风扇编号
    static let fanLocks = "fan.locks"

    static let defaults: [String: Any] = [
        barCPU: true,
        barMemory: false,
        barTemp: true,
        barPower: false,
        barFan: false,
    ]
}
