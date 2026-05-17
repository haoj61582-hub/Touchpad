# Controller

把 iPad 变成 `MacBook / Windows` 的远程键盘和触控板，最可行的做法不是让电脑把 iPad 识别成原生蓝牙 HID，而是做成两端架构：

- `iPad App` 负责采集触摸和键盘输入
- `桌面 companion` 负责接收事件并注入到本机系统

这个仓库先把最关键的两层搭起来：

- `ControllerShared`
  - 跨端输入协议
  - JSON Lines 编解码
  - iPad 侧可复用的 TCP 客户端
- `MacCompanionCLI`
  - 在 macOS 上监听 TCP 连接
  - 把收到的事件转成鼠标、滚轮和键盘输入
  - 首次运行时可提示用户开启 Accessibility 权限

## 为什么先不做“原生蓝牙键盘/触控板”

公开的 `iPadOS` API 能让 App 成为 `BLE GATT peripheral`，但没有面向第三方 App 的公开系统级 `Bluetooth HID` 外设能力。  
所以如果你想把这个产品真正做出来，第一阶段最稳的路线是：

`iPad App + Mac companion + 局域网传输`

等协议和交互稳定后，再评估是否补 `BLE 自定义协议`。

## 仓库结构

- `Package.swift`
- `Sources/ControllerShared`
- `Sources/MacCompanionCLI`
- `Sources/iPadRemotePrototype`
- `Docs/iPadAppIntegration.md`
- `script/build_and_run.sh`

## 当前协议

现在已经定义好的输入事件有：

- `pointerMove(dx, dy)`
- `scroll(dx, dy)`
- `mouseButton(button, state)`
- `text(text)`
- `keyPress(namedKey, modifiers)`

传输层用的是 `TCP + JSON Lines`，主要是为了：

- 先把 MVP 跑通
- 便于调试抓包
- 未来 Windows 端可以很容易用 `C#` 重写 companion

当前 `iPad` 端已经支持通过 `Bonjour` 自动发现局域网里的 `Mac companion`，正常情况下不需要再手动输入 IP。  
同时会记住上次成功连接的 `Mac`，下次启动后会优先自动重连它。

## 运行 Mac companion

```bash
./script/build_and_run.sh
```

默认监听：

- host: `0.0.0.0`
- port: `38765`

启动后还会自动广播一个 `Bonjour` 服务：

- type: `_controller-remote._tcp`

你也可以手动运行：

```bash
swift run MacCompanionCLI --port 38765
```

如果 macOS 没响应输入事件，去这里授权：

`System Settings > Privacy & Security > Accessibility`

## iPad 端怎么继续

看这里：

- `Docs/iPadAppIntegration.md`

参考代码已经放好了：

- `Sources/iPadRemotePrototype/RemotePadView.swift`
- `Sources/iPadRemotePrototype/TextCaptureField.swift`

打开 App 后会先自动扫描同一局域网里正在运行 `MacCompanionCLI` 的设备，点一下设备名即可连接。  
一旦成功连接过一次，后续会记住这台 `Mac` 并在下次启动时自动尝试重连。  
只有在发现失败时，才需要展开手动连接作为兜底。

## Windows 端怎么接

这个仓库还没做 Windows companion，但协议已经尽量做成了跨语言友好的结构。  
下一步你可以用 `C# + WPF/WinUI` 做一个监听同样 JSON Lines 协议的桌面程序，然后用 `SendInput` 注入输入事件。

## 建议的开发顺序

1. 先把 `iPad -> Mac` 的 Wi‑Fi MVP 跑通。
2. 调整手势映射、灵敏度和滚动体验。
3. 加局域网自动发现和简单配对。
4. 再做 `Windows companion`。
5. 最后再考虑 BLE 自定义协议。
