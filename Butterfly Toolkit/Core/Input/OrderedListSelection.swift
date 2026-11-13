// 按点选顺序保留当前预览，并按屏幕上的列表顺序扩展连续选择。
import AppKit

nonisolated enum OrderedListSelection {
    static func clicked(_ id: UUID, modifiers: NSEvent.ModifierFlags, selected: [UUID], visible: [UUID]) -> [UUID] {
        guard let target = visible.firstIndex(of: id) else { return selected }
        let extending = modifiers.contains(.command)
        if modifiers.contains(.shift), let first = selected.first, let anchor = visible.firstIndex(of: first) {
            let range = visible[min(anchor, target)...max(anchor, target)]
            let starting = extending ? selected : [first]
            return appending(Array(range), to: starting)
        }
        if extending {
            return selected.contains(id) ? selected.filter { $0 != id } : selected + [id]
        }
        return [id]
    }

    static func appending(_ ids: [UUID], to selected: [UUID]) -> [UUID] {
        let existing = Set(selected)
        return selected + ids.filter { !existing.contains($0) }
    }
}
