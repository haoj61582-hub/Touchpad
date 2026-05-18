# Touchpad Controller

中文 / English bilingual README for the current MVP.

## 中文说明

### 项目简介

`Touchpad Controller` 是一个把 `iPad / iPhone` 变成 `MacBook` 远程键盘和触控板的项目。

这个项目当前采用的是：

- `iPad / iPhone App` 负责采集触摸和键盘输入
- `Mac companion` 负责接收事件并注入到 macOS

当前版本的重点是先把 `iPad -> Mac` 的远程控制体验跑通，而不是把 iPad 伪装成系统原生蓝牙 HID 外设。

### 当前功能

- 触控板模式
  - 单指移动光标
  - 单击左键
  - 单指双击打开文件和文件夹
  - 双指滚动
  - 双指轻点右键
  - 长按拖拽
  - 可切换纵向移动方向
- 键盘模式
  - Apple 风格的多功能屏幕键盘
  - `ABC / 123 / #+=` 层切换
  - `F1-F12`
  - 独立数字键盘
  - `Command / Option / Control / Shift`
  - 多语种切换入口
  - 按键音效与触觉反馈
- 连接体验
  - Bonjour 自动发现局域网内的 Mac
  - 自动记住上次连接的 Mac 并尝试重连
  - 手动输入 host / port 兜底
  - 二维码配对
- 界面体验
  - 键盘和触控板分离页面
  - 连接成功后自动收起连接区
  - 针对 iPad 和 iPhone 做了不同密度的自适应布局

### 当前架构

- `ControllerShared`
  - 跨端协议模型
  - `TCP + JSON Lines` 编解码
  - iOS 端复用客户端
- `MacCompanionCLI`
  - 监听 TCP 连接
  - Bonjour 广播
  - 键盘 / 鼠标 / 滚轮事件注入
- `ControlleriPad`
  - 触控板和多功能键盘 UI
  - 自动发现、手动连接、二维码扫描

### 为什么当前不用“原生蓝牙键盘/触控板”

公开的 `iPadOS` API 允许 App 做 `BLE GATT peripheral`，但没有面向第三方的公开系统级 `Bluetooth HID` 外设能力。  
因此当前最稳的方案仍然是：

`iPad App + Mac companion + 局域网传输`

### 仓库结构

- `Package.swift`
- `Apps/ControlleriPad`
- `Sources/ControllerShared`
- `Sources/MacCompanionCLI`
- `Sources/iPadRemotePrototype`
- `Docs/iPadAppIntegration.md`
- `script/build_and_run.sh`

### 运行 Mac companion

```bash
cd /Users/jiahao/Desktop/Controller
DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer swift run MacCompanionCLI --no-accessibility-prompt
```

默认监听：

- host: `0.0.0.0`
- port: `38765`

如果想显示二维码配对：

```bash
cd /Users/jiahao/Desktop/Controller
DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer swift run MacCompanionCLI --no-accessibility-prompt --show-qr
```

如果 macOS 没响应输入事件，需要到这里授权：

`System Settings > Privacy & Security > Accessibility`

### iPad / iPhone 测试

1. 用 Xcode 打开：
   `Apps/ControlleriPad/ControlleriPad.xcodeproj`
2. 选择真机 `iPad` 或 `iPhone`
3. 运行 App
4. 保证设备和 Mac 在同一局域网
5. 优先使用自动发现或二维码配对

### 当前状态

- `iPad / iPhone -> Mac` 主链路可用
- 自动发现、手动连接、二维码配对已接入
- 触控板与多功能键盘已接入
- `Windows companion` 还未正式实现

### 后续方向

1. 继续打磨触控板灵敏度和加速度
2. 继续压缩控制栏，让触控板更接近全屏
3. 补正式的 `Windows companion`
4. 评估后续是否需要自定义 BLE 协议

## English

### Overview

`Touchpad Controller` turns an `iPad / iPhone` into a remote keyboard and trackpad for `MacBook`.

The current product shape is:

- an `iPad / iPhone app` that captures touch and keyboard input
- a `Mac companion` that receives events and injects them into macOS

This repository focuses on making the `iPad -> Mac` control loop solid first instead of trying to emulate a native Bluetooth HID device.

### Current Features

- Trackpad mode
  - single-finger cursor movement
  - single tap for primary click
  - single-finger double tap to open files and folders
  - two-finger scrolling
  - two-finger tap for secondary click
  - long-press drag
  - reversible vertical direction
- Keyboard mode
  - Apple-inspired multifunction on-screen keyboard
  - `ABC / 123 / #+=` layers
  - `F1-F12`
  - dedicated number pad
  - `Command / Option / Control / Shift`
  - language switch entry point
  - key sound and haptic feedback
- Connection flow
  - Bonjour auto-discovery on the local network
  - remembers the last connected Mac and attempts auto reconnect
  - manual host / port fallback
  - QR pairing
- UI
  - separate keyboard and trackpad surfaces
  - setup area auto-collapses after connection
  - adaptive layouts for both iPad and iPhone

### Architecture

- `ControllerShared`
  - shared protocol models
  - `TCP + JSON Lines`
  - reusable iOS-side client
- `MacCompanionCLI`
  - TCP listener
  - Bonjour broadcasting
  - keyboard / mouse / scroll injection
- `ControlleriPad`
  - trackpad and multifunction keyboard UI
  - auto-discovery, manual connection, QR scanning

### Why Not Native Bluetooth HID

Public `iPadOS` APIs allow third-party apps to act as a `BLE GATT peripheral`, but do not expose a public system-level `Bluetooth HID` device role for third-party apps.  
For this reason, the most practical architecture right now is:

`iPad App + Mac companion + local network transport`

### Repository Layout

- `Package.swift`
- `Apps/ControlleriPad`
- `Sources/ControllerShared`
- `Sources/MacCompanionCLI`
- `Sources/iPadRemotePrototype`
- `Docs/iPadAppIntegration.md`
- `script/build_and_run.sh`

### Run the Mac Companion

```bash
cd /Users/jiahao/Desktop/Controller
DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer swift run MacCompanionCLI --no-accessibility-prompt
```

Default listener:

- host: `0.0.0.0`
- port: `38765`

To show a QR code for pairing:

```bash
cd /Users/jiahao/Desktop/Controller
DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer swift run MacCompanionCLI --no-accessibility-prompt --show-qr
```

If macOS ignores injected input, grant permission here:

`System Settings > Privacy & Security > Accessibility`

### Test on iPad / iPhone

1. Open `Apps/ControlleriPad/ControlleriPad.xcodeproj` in Xcode
2. Select a real `iPad` or `iPhone`
3. Run the app
4. Keep the device and Mac on the same local network
5. Prefer auto-discovery or QR pairing first

### Status

- `iPad / iPhone -> Mac` control path is working
- auto-discovery, manual connection, and QR pairing are integrated
- trackpad and multifunction keyboard are integrated
- a formal `Windows companion` is not implemented yet

### Roadmap

1. Continue refining trackpad sensitivity and acceleration
2. Compress the control chrome further to maximize trackpad space
3. Add a formal `Windows companion`
4. Evaluate whether a custom BLE protocol is worth adding later
