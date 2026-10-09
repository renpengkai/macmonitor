# MacMonitor

极小体积的 macOS 菜单栏系统监控工具，适配 macOS 26+ 液态玻璃外观。

- **CPU**：总使用率、用户/系统占比、每核负载、60 点历史曲线
- **内存**：已用/总量（与活动监视器口径一致）、App 内存、联动、压缩、交换、内存压力
- **功率**：整机功耗（SMC `PSTR`）、电源输入、电池充放电功率与电量、适配器额定功率
- **温度**：CPU（平均/最高）、GPU、内存、固态硬盘、电池
- **风扇**：实时转速；手动/自动模式切换、目标转速调节、锁定转速（无风扇机型显示“被动散热”）

菜单栏可选择显示 CPU、内存、温度、功率、风扇转速，支持开机启动。

## 系统要求

- Apple Silicon Mac，macOS 13 及以上
- macOS 26 及以上自动使用液态玻璃界面，更早系统使用毛玻璃材质

## 安装

从 GitHub Actions 构建产物或 Release 下载 `MacMonitor-x.y.z.zip`，解压后把 `MacMonitor.app` 放进「应用程序」。

应用为 ad-hoc 签名，首次打开前需去掉隔离属性：

```bash
xattr -cr /Applications/MacMonitor.app
```

## 风扇控制

SMC 只接受 root 进程写入。首次在面板中点「启用风扇控制」时会弹出管理员授权，
把包内的 `mmfanctl` 以 setuid root 安装到
`/Library/PrivilegedHelperTools/io.github.renpengkai.macmonitor.fanctl`。
该工具只接受 `set <风扇> <转速>`、`auto <风扇>`、`reset` 三个经过校验的命令，转速会被限制在风扇的最小/最大值之间。

- 手动模式下可开启「锁定转速」：退出后仍保持该转速，下次启动自动恢复；未锁定的风扇在退出时恢复系统自动控制
- 若系统重新夺回风扇控制权，应用会把已锁定的转速重新写回
- M1~M4 通过 `Ftst` 解锁手动模式，切换需要约 3 秒；M5 起直接写模式键
- 在「设置 → 卸载风扇控制组件」可随时移除

## 构建

在 GitHub Actions（`xcode-27` runner，macOS 26+ SDK）上编译打包，见 `.github/workflows/build-macos.yml`：

- 推送到 `main`：生成构建产物（Artifacts）
- 推送 `v*` 标签：同时发布 Release

打包脚本 `scripts/package-app.sh` 使用 `-Osize` 编译、剥离符号，并把二进制的 SDK 版本标记改写为实际 SDK，
使液态玻璃在 macOS 26+ 上生效。

## 致谢

SMC 访问方式与风扇解锁流程参考 [exelban/stats](https://github.com/exelban/stats)（MIT License）。
