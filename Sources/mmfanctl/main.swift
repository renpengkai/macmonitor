//
// main.swift
// mmfanctl
// 风扇控制特权工具。SMC 写入只接受 root 进程, 该工具以 setuid root 安装到
// /Library/PrivilegedHelperTools, 由 MacMonitor 调用。只接受以下经过校验的命令:
//   mmfanctl version
//   mmfanctl set <fan> <rpm>
//   mmfanctl auto <fan>
//   mmfanctl reset
//

import Darwin
import SMCKit

/// 与 App 内 FanHelper.version 保持一致; 升级 App 后据此判断是否需要重新安装
let version = "1"

func fail(_ message: String, _ code: Int32 = 1) -> Never {
    fputs("mmfanctl: \(message)\n", stderr)
    exit(code)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("usage: mmfanctl version | set <fan> <rpm> | auto <fan> | reset", 64) }

if command == "version" {
    print(version)
    exit(0)
}

// 真实 uid 也切成 root, 避免 IOKit 按真实 uid 判定权限
guard geteuid() == 0, setuid(0) == 0 else { fail("需要 root (setuid) 权限", 77) }
guard let smc = SMC() else { fail("无法打开 AppleSMC") }

func fanArg(_ index: Int) -> Int {
    guard args.count > index, let id = Int(args[index]), id >= 0, id < smc.fanCount else {
        fail("无效的风扇编号", 64)
    }
    return id
}

let ok: Bool
switch command {
case "set":
    let id = fanArg(1)
    guard args.count == 3, let rpm = Double(args[2]), rpm.isFinite, rpm >= 0 else { fail("无效的转速", 64) }
    ok = smc.setFan(id, rpm: rpm)
case "auto":
    ok = smc.setFanAuto(fanArg(1))
case "reset":
    ok = smc.resetFans()
default:
    fail("未知命令 \(command)", 64)
}
exit(ok ? 0 : 1)
