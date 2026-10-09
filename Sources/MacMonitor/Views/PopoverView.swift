//
// PopoverView.swift
// MacMonitor
// 点击菜单栏图标弹出的面板。
//

import AppKit
import ServiceManagement
import SMCKit
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject private var monitor: Monitor
    @EnvironmentObject private var fans: FanController

    var body: some View {
        let snap = monitor.snapshot
        VStack(spacing: 10) {
            header
            GlassStack {
                cpuCard(snap.cpu)
                memoryCard(snap.memory)
                powerCard(snap.power)
                tempCard(snap.temps)
                FanCard(fans: snap.fans)
            }
            SettingsBar()
        }
        .padding(12)
        .frame(width: 330)
    }

    private var header: some View {
        HStack {
            Text("MacMonitor").font(.headline)
            Spacer()
            Text(SystemInfo.chip).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private func cpuCard(_ cpu: CPUStat) -> some View {
        Card(title: "CPU", symbol: "cpu", value: Format.percent(cpu.total), valueColor: Format.loadColor(cpu.total)) {
            Sparkline(values: monitor.cpuHistory, ceiling: 1, color: .blue)
                .frame(height: 36)
            CoreBars(cores: cpu.cores)
            HStack {
                InfoRow(label: "用户", value: Format.percent(cpu.user))
                InfoRow(label: "系统", value: Format.percent(cpu.system))
            }
        }
    }

    private func memoryCard(_ mem: MemoryStat) -> some View {
        let pressure: (String, Color) = switch mem.pressure {
        case 4: ("严重", .red)
        case 2: ("警告", .orange)
        default: ("正常", .green)
        }
        return Card(title: "内存", symbol: "memorychip", value: Format.percent(mem.usage),
                    valueColor: Format.loadColor(mem.usage)) {
            Bar(value: mem.usage, color: Format.loadColor(mem.usage))
            InfoRow(label: "已用 / 总量", value: "\(Format.bytes(mem.used)) / \(Format.bytes(mem.total))")
            HStack {
                InfoRow(label: "App", value: Format.bytes(mem.app))
                InfoRow(label: "联动", value: Format.bytes(mem.wired))
            }
            HStack {
                InfoRow(label: "压缩", value: Format.bytes(mem.compressed))
                InfoRow(label: "交换", value: Format.bytes(mem.swap))
            }
            InfoRow(label: "内存压力", value: pressure.0, color: pressure.1)
        }
    }

    private func powerCard(_ power: PowerStat) -> some View {
        let headline = power.system ?? power.battery.map { abs($0) }
        return Card(title: "功率", symbol: "bolt.fill", value: headline.map(Format.watts)) {
            Sparkline(values: monitor.powerHistory, color: .orange)
                .frame(height: 36)
            if let input = power.input, power.external {
                InfoRow(label: "电源输入", value: Format.watts(input))
            }
            if let level = power.batteryLevel {
                let state = power.charging ? "充电中" : (power.external ? "已接电源" : "使用电池")
                InfoRow(label: "电池 \(level)%", value: state)
            }
            if let battery = power.battery, abs(battery) >= 0.05 {
                InfoRow(label: battery > 0 ? "充电功率" : "放电功率", value: Format.watts(abs(battery)),
                        color: battery > 0 ? .green : .primary)
            }
            if let adapter = power.adapterWatts, power.external {
                InfoRow(label: "电源适配器", value: "\(adapter) W")
            }
        }
    }

    private func tempCard(_ temps: [Temperature]) -> some View {
        let cpu = temps.first { $0.name == "CPU" }
        return Card(title: "温度", symbol: "thermometer.medium", value: cpu.map { Format.temp($0.average) },
                    valueColor: cpu.map { Format.tempColor($0.average) } ?? .primary) {
            if temps.isEmpty {
                Text("未读取到温度传感器").font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 6) {
                    ForEach(temps) { t in
                        InfoRow(label: t.name,
                                value: t.max - t.average >= 3
                                    ? "\(Format.temp(t.average)) / \(Format.temp(t.max))"
                                    : Format.temp(t.average),
                                color: Format.tempColor(t.max))
                    }
                }
                if temps.contains(where: { $0.max - $0.average >= 3 }) {
                    Text("平均 / 最高").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

private struct FanCard: View {
    let fans: [FanInfo]
    @EnvironmentObject private var control: FanController

    var body: some View {
        let summary = fans.first.map { "\(Int($0.current.rounded())) RPM" }
        Card(title: "风扇", symbol: "fan", value: summary) {
            if fans.isEmpty {
                Text("本机没有风扇 (被动散热)").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(fans, id: \.id) { fan in row(fan) }
                if !control.helperReady {
                    Button("启用风扇控制 (需管理员密码)") { control.install() }
                        .glassButton()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                }
            }
            if let message = control.message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func row(_ fan: FanInfo) -> some View {
        let mode = control.mode(of: fan)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(fans.count > 1 ? "风扇 \(fan.id + 1)" : "转速").font(.caption.weight(.medium))
                Spacer()
                if control.busy { ProgressView().controlSize(.mini) }
                Text("\(Int(fan.current.rounded())) RPM").font(.caption).monospacedDigit()
            }
            Bar(value: fan.max > 0 ? fan.current / fan.max : 0, color: .teal)
            if control.helperReady {
                Picker("模式", selection: Binding(get: { mode }, set: { control.setMode($0, for: fan) })) {
                    Text("自动").tag(FanController.Mode.auto)
                    Text("手动").tag(FanController.Mode.manual)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)

                if mode == .manual, fan.max > fan.min {
                    Slider(value: Binding(get: { control.target(of: fan) },
                                          set: { control.setTarget($0, for: fan) }),
                           in: fan.min...fan.max, step: 100,
                           onEditingChanged: { editing in
                               // 拖动结束才写入, 避免每一帧都调用特权工具
                               if !editing { control.apply(fan.id) }
                           })
                    .controlSize(.small)
                    InfoRow(label: "目标转速", value: "\(Int(control.target(of: fan))) RPM  (\(Int(fan.min))–\(Int(fan.max)))")
                    Toggle(isOn: Binding(
                        get: { control.isLocked(fan) },
                        set: { control.setLocked($0, for: fan) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("锁定转速")
                            Text("退出后保持, 下次启动自动恢复")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .controlSize(.small)
                    .toggleStyle(.switch)
                }
            }
        }
    }
}

private struct SettingsBar: View {
    @EnvironmentObject private var monitor: Monitor
    @EnvironmentObject private var fans: FanController
    @AppStorage(Settings.barCPU) private var barCPU = true
    @AppStorage(Settings.barMemory) private var barMemory = false
    @AppStorage(Settings.barTemp) private var barTemp = true
    @AppStorage(Settings.barPower) private var barPower = false
    @AppStorage(Settings.barFan) private var barFan = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        HStack {
            Menu {
                Section("菜单栏显示") {
                    Toggle("CPU 使用率", isOn: $barCPU)
                    Toggle("内存使用率", isOn: $barMemory)
                    Toggle("CPU 温度", isOn: $barTemp)
                    Toggle("功率", isOn: $barPower)
                    Toggle("风扇转速", isOn: $barFan)
                }
                Picker("刷新间隔", selection: $monitor.interval) {
                    Text("1 秒").tag(1.0)
                    Text("2 秒").tag(2.0)
                    Text("5 秒").tag(5.0)
                }
                .pickerStyle(.menu)
                Toggle("开机启动", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if fans.helperReady {
                    Divider()
                    Button("卸载风扇控制组件") { fans.uninstall() }
                }
            } label: {
                Label("设置", systemImage: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()

            Button("退出") { NSApp.terminate(nil) }
                .glassButton()
                .controlSize(.small)
        }
        .padding(.horizontal, 4)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("MacMonitor: 登录项设置失败 \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

enum SystemInfo {
    static let chip: String = {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0) == 0 else { return "" }
        return String(cString: buf)
    }()
}
