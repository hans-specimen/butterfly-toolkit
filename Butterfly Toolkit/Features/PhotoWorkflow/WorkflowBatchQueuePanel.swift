// 显示保存顺序、当前查看和自动准备状态，提供单批与整队列操作。
import SwiftUI

struct WorkflowBatchQueuePanel: View {
    @ObservedObject var store: PhotoWorkflowStore
    let addSavedBatch: () -> Void
    let openBatch: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("批次队列").font(.headline)
                Spacer()
                Button("添加已有批次", systemImage: "plus", action: addSavedBatch)
                    .labelStyle(.iconOnly)
                    .help("添加已有批次")
                    .disabled(!store.canSwitchBatch)
            }
            .padding(12)

            Divider()
            if store.batchQueue.isEmpty {
                ContentUnavailableView("队列为空", systemImage: "list.bullet.rectangle",
                    description: Text("新建批次，或从已保存的批次中添加。"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(store.batchQueue) { entry in row(entry) }
                    }
                    .padding(8)
                }
                .frame(height: CGFloat(min(store.batchQueue.count, 6)) * 72 + 10)
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if store.isBatchQueueRunning {
                    Button(store.isPausingBatchQueue ? "正在暂停…" : "暂停队列") { store.pauseBatchQueue() }
                        .disabled(store.isPausingBatchQueue)
                    Text(store.runningBatch?.title ?? "正在准备批次")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Button(store.canContinueBatchQueue ? "继续队列" : "运行队列") { store.runBatchQueue() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.canRunBatchQueue)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }

    private func row(_ entry: WorkflowQueuedBatch) -> some View {
        let current = store.batch?.id == entry.id
        let running = store.runningBatch?.id == entry.id
        return HStack(alignment: .top, spacing: 4) {
            Button {
                openBatch(entry.manifest)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title).font(.callout.weight(.medium)).lineLimit(2)
                    Text(running ? "处理中" : store.batchQueueStatuses[entry.id] ?? "读取进度…")
                        .font(.caption)
                        .foregroundStyle(running ? Color.accentColor : .secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!store.canSwitchBatch)
            .accessibilityAddTraits(current ? .isSelected : [])
            .help(entry.title)

            Menu {
                Button("运行此批次") { store.runQueuedBatch(entry.id) }
                    .disabled(!store.canRunBatchQueue)
                Button("上移") { store.moveQueuedBatch(entry.id, by: -1) }
                    .disabled(running || !canMove(entry, by: -1))
                Button("下移") { store.moveQueuedBatch(entry.id, by: 1) }
                    .disabled(running || !canMove(entry, by: 1))
                Divider()
                Button("移出队列") { store.removeQueuedBatch(entry.id) }
                    .disabled(running)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("批次操作")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.top, 5)
            .padding(.trailing, 4)
        }
        .background(current ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private func canMove(_ entry: WorkflowQueuedBatch, by offset: Int) -> Bool {
        guard let index = store.batchQueue.firstIndex(of: entry),
              store.batchQueue.indices.contains(index + offset) else { return false }
        return store.batchQueue[index + offset].id != store.runningBatch?.id
    }
}
