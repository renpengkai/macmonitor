//
// AppDelegate.swift
// MacMonitor
// 菜单栏图标、弹出面板与退出时的风扇恢复。
//

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let monitor = Monitor()
    private let fans = FanController()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: Settings.defaults)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageOnly
        }

        let host = NSHostingController(rootView: PopoverView().environmentObject(monitor).environmentObject(fans))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        monitor.onUpdate = { [weak self] in
            guard let self else { return }
            self.refreshStatus()
            self.fans.reinforce(using: self.monitor.snapshot.fans)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(refreshStatus),
                                               name: UserDefaults.didChangeNotification, object: nil)
        monitor.start()
        refreshStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        fans.resetNow()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // 菜单栏应用默认不是活跃应用, 需激活后 transient 弹窗才能在点击外部时自动关闭
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func refreshStatus() {
        let snap = monitor.snapshot
        let defaults = UserDefaults.standard
        var items: [(symbol: String, text: String)] = []
        if defaults.bool(forKey: Settings.barCPU) {
            items.append(("cpu", Format.percent(snap.cpu.total)))
        }
        if defaults.bool(forKey: Settings.barMemory) {
            items.append(("memorychip", Format.percent(snap.memory.usage)))
        }
        if defaults.bool(forKey: Settings.barTemp), let cpu = snap.temps.first(where: { $0.name == "CPU" }) {
            items.append(("thermometer.medium", Format.temp(cpu.average)))
        }
        if defaults.bool(forKey: Settings.barPower),
           let watts = snap.power.system ?? snap.power.battery.map({ abs($0) }) {
            items.append(("bolt.fill", Format.watts(watts)))
        }
        if defaults.bool(forKey: Settings.barFan), let fan = snap.fans.first {
            items.append(("fan", "\(Int(fan.current.rounded()))"))
        }
        statusItem.button?.image = StatusImage.render(items)
    }
}

/// 把菜单栏内容绘制成模板图片, 由系统按浅色/深色/液态玻璃菜单栏自动着色
enum StatusImage {

    static func render(_ items: [(symbol: String, text: String)]) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        guard !items.isEmpty else {
            let icon = NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: "MacMonitor")?
                .withSymbolConfiguration(config) ?? NSImage()
            icon.isTemplate = true
            return icon
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.black,
        ]
        let parts = items.map { item in
            (icon: NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config),
             text: NSAttributedString(string: item.text, attributes: attrs))
        }
        let height: CGFloat = 18
        let iconGap: CGFloat = 2
        let itemGap: CGFloat = 8
        var width: CGFloat = 0
        for (i, part) in parts.enumerated() {
            if i > 0 { width += itemGap }
            if let icon = part.icon { width += icon.size.width + iconGap }
            width += ceil(part.text.size().width)
        }

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (i, part) in parts.enumerated() {
                if i > 0 { x += itemGap }
                if let icon = part.icon {
                    let s = icon.size
                    icon.draw(in: NSRect(x: x, y: (height - s.height) / 2, width: s.width, height: s.height))
                    x += s.width + iconGap
                }
                let s = part.text.size()
                part.text.draw(at: NSPoint(x: x, y: (height - s.height) / 2))
                x += ceil(s.width)
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
