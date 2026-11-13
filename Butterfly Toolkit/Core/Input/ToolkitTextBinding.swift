// 在保留系统文本编辑行为的同时，把非表格字段写入的 Tab 转成空格。
import SwiftUI

extension Binding where Value == String {
    var replacingTabs: Binding<String> {
        Binding(get: { wrappedValue }, set: { wrappedValue = ToolkitTextInput.replacingTabs($0) })
    }
}
