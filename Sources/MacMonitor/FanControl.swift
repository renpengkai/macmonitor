//
// FanControl.swift
// MacMonitor
// 风扇控制: 安装 setuid root 的 mmfanctl 并通过它写 SMC。
//

import AppKit
import SMCKit

enum FanHelper {

    /// 与 mmfanctl 内的 version 一致; 变更 mmfanctl 行为时同步递增, 旧版本会被提示重新安装
    static let version = "1"
    static let installPath = "/Library/PrivilegedHelperTools/io.github.renpengkai.macmonitor.fanctl"

    private static var bundledPath: String? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("mmfanctl").path
    }

    /// 已安装、属主为 root、带 setuid 位且版本匹配
    static var isReady: Bool {
        var st = stat()
        guard stat(installPath, &st) == 0, st.st_uid == 0, st.st_mode & 0o4000 != 0 else { return false }
        let result = run(["version"])
        return result.ok && result.output == version
    }

    @discardableResult
    static func run(_ args: [String]) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: installPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (false, error.localizedDescription)
        }
        // 先读完输出再等待退出, 避免输出填满管道缓冲导致双方互相等待
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus == 0, output)
    }

    /// 通过系统管理员授权对话框安装; 成功返回 nil, 否则返回错误描述 (用户取消也返回 nil 以外的值)
    static func install() -> String? {
        guard let src = bundledPath, FileManager.default.isExecutableFile(atPath: src) else {
            return "应用包内缺少 mmfanctl"
        }
        let dst = shellQuote(installPath)
        let script = [
            "mkdir -p /Library/PrivilegedHelperTools",
            "cp -f \(shellQuote(src)) \(dst)",
            // 去掉下载带来的隔离属性, 否则执行时会被 Gatekeeper 拦截
            "(xattr -c \(dst) || true)",
            "chown root:wheel \(dst)",
            "chmod 4755 \(dst)",
        ].joined(separator: " && ")
        return runPrivileged(script)
    }

    static func uninstall() -> String? {
        runPrivileged("rm -f \(shellQuote(installPath))")
    }

    private static func runPrivileged(_ shell: String) -> String? {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return nil }
        // -128: 用户在授权对话框点了取消
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return "已取消" }
        return error[NSAppleScript.errorMessage] as? String ?? "授权失败"
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

final class FanController: ObservableObject {

    enum Mode: Hashable {
        case auto
        case manual
    }

    /// 用户在界面上选择的模式; 未选择过的风扇沿用 SMC 报告的实际模式
    @Published var modes: [Int: Mode] = [:]
    @Published var targets: [Int: Double] = [:]
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var helperReady = false

    private let queue = DispatchQueue(label: "macmonitor.fanctl")
    /// 本次运行是否改动过风扇, 退出时据此决定是否恢复自动
    private var touched = false

    init() {
        queue.async {
            let ready = FanHelper.isReady
            DispatchQueue.main.async { self.helperReady = ready }
        }
    }

    func mode(of fan: FanInfo) -> Mode {
        modes[fan.id] ?? (fan.manual ? .manual : .auto)
    }

    func target(of fan: FanInfo) -> Double {
        let value = targets[fan.id] ?? (fan.target > 0 ? fan.target : fan.current)
        return min(max(value, fan.min), fan.max)
    }

    func setMode(_ mode: Mode, for fan: FanInfo) {
        modes[fan.id] = mode
        switch mode {
        case .manual:
            targets[fan.id] = target(of: fan)
            apply(fan.id)
        case .auto:
            run(["auto", "\(fan.id)"])
        }
    }

    func setTarget(_ rpm: Double, for fan: FanInfo) {
        targets[fan.id] = rpm
    }

    func apply(_ id: Int) {
        guard let rpm = targets[id] else { return }
        run(["set", "\(id)", "\(Int(rpm.rounded()))"])
    }

    func install() {
        message = nil
        // NSAppleScript 需在主线程执行; 授权对话框期间主线程阻塞属预期行为
        if let error = FanHelper.install() {
            message = error
        }
        helperReady = FanHelper.isReady
        if !helperReady && message == nil { message = "安装后校验失败" }
    }

    func uninstall() {
        resetNow()
        if let error = FanHelper.uninstall() { message = error }
        helperReady = FanHelper.isReady
        modes.removeAll()
    }

    /// 应用退出时同步恢复自动控制, 避免风扇停在手动转速
    func resetNow() {
        guard touched, helperReady else { return }
        FanHelper.run(["reset"])
        touched = false
    }

    private func run(_ args: [String]) {
        guard helperReady else {
            message = "请先安装风扇控制组件"
            return
        }
        touched = true
        busy = true
        message = nil
        queue.async {
            let result = FanHelper.run(args)
            DispatchQueue.main.async {
                self.busy = false
                if !result.ok { self.message = result.output.isEmpty ? "操作失败" : result.output }
            }
        }
    }
}
