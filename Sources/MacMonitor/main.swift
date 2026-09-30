import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// 纯菜单栏应用: 不显示 Dock 图标 (Info.plist 的 LSUIElement 也会生效, 这里保证直接运行二进制时一致)
app.setActivationPolicy(.accessory)
app.run()
