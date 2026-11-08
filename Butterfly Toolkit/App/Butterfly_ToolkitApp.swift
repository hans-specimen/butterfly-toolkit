// 应用入口：创建主窗口、挂载工具导航页，并设置窗口的默认尺寸。
// 由 Hans 创建于 2026/8/4。

import SwiftUI

// MARK: - 应用与主窗口

@main
struct Butterfly_ToolkitApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1440, height: 920)
    }
}
