# iPad App Integration

这个仓库目前给你两块可复用内容：

1. `ControllerShared`
   - 输入协议
   - TCP JSON Lines 编解码
   - `RemoteClient`
2. `Sources/iPadRemotePrototype`
   - 一个可直接搬进 iPad target 的参考界面
   - 触控板手势和文本输入采集方式

## 在 Xcode 里怎么接

1. 新建一个 `iPadOS App`。
2. 把这个仓库作为 `Swift Package Dependency` 加进去。
3. 在你的 iPad target 里复制下面两个参考文件：
   - `Sources/iPadRemotePrototype/RemotePadView.swift`
   - `Sources/iPadRemotePrototype/TextCaptureField.swift`
4. 在 `ContentView` 里先直接放：

```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        RemotePadView()
    }
}
```

## Info.plist 建议

如果你后面要自动发现局域网里的 Mac：

- 加 `NSLocalNetworkUsageDescription`
- 如果要走 Bonjour，再补 `NSBonjourServices`

第一版 MVP 可以先手动输入 Mac 的 IP 和端口，不必一开始就做自动发现。

## 下一步最值得补的功能

- 指针灵敏度和滚动灵敏度设置
- 连接码配对，而不是只填 IP
- 双击、三指手势、拖拽锁定
- 剪贴板同步
- 局域网自动发现
- 端到端加密和配对持久化

