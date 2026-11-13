// 展示本机批次、保存进度和来源，提供打开清单与确认删除入口。
import SwiftUI
import UniformTypeIdentifiers

struct WorkflowBatchPicker: View {
    @ObservedObject var store: PhotoWorkflowStore
    @Environment(\.dismiss) private var dismiss
    @State private var records: [WorkflowBatchCatalog.Record] = []
    @State private var selection: URL?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var confirmingDeletion = false
    @State private var importingFile = false

    private var selected: WorkflowBatchCatalog.Record? { records.first { $0.id == selection } }
    private var canAct: Bool { store.canSwitchBatch && !isLoading }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("打开批次")
                .font(.title2.weight(.semibold))
                .padding(20)
                .accessibilityAddTraits(.isHeader)

            Divider()
            batchList
            Divider()
            if let selected { details(selected); Divider() }
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red)
                    .padding(.horizontal, 20).padding(.top, 12)
                    .textSelection(.enabled)
            }
            actions
        }
        .frame(width: 640)
        .interactiveDismissDisabled(store.busy)
        .task { await reload() }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): open(url)
            case .failure(let error): actionError = error.localizedDescription
            }
        }
        .alert("删除批次？", isPresented: $confirmingDeletion, presenting: selected) { record in
            Button("取消", role: .cancel) {}
            Button("删除批次", role: .destructive) { Task { await delete(record) } }
        } message: { record in
            Text("将删除「\(record.title)」的批次记录、恢复清单和临时缓存，无法从此批次继续。原始输入文件夹、工作 PSD 和已导出的成品会保留。")
        }
    }

    // MARK: - 列表与详情
    @ViewBuilder private var batchList: some View {
        if isLoading {
            ProgressView().accessibilityLabel("正在载入批次")
                .frame(maxWidth: .infinity, minHeight: 220)
        } else if let loadError {
            VStack(spacing: 8) {
                Text("无法载入批次").font(.headline)
                Text(loadError).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("重试") { Task { await reload() } }
            }
            .padding(20).frame(maxWidth: .infinity, minHeight: 220)
        } else if records.isEmpty {
            ContentUnavailableView("没有已保存的批次", systemImage: "photo.stack",
                                   description: Text("可以从文件打开已有的批次清单。"))
                .frame(height: 220)
        } else {
            List(selection: $selection) {
                ForEach(records) { record in
                    row(record).tag(record.id)
                }
            }
            .listStyle(.inset)
            .frame(height: 248)
            .contextMenu(forSelectionType: URL.self) { ids in
                if let record = records.first(where: { ids.contains($0.id) }), ids.count == 1 {
                    Button("打开所选批次") { open(record.id) }.disabled(!canAct || !record.canOpen)
                }
            } primaryAction: { ids in
                if ids.count == 1, let id = ids.first, records.first(where: { $0.id == id })?.canOpen == true {
                    open(id)
                }
            }
        }
    }

    private func row(_ record: WorkflowBatchCatalog.Record) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(record.specimenCount == 0 ? record.progress : "\(record.specimenCount) 只 · \(record.progress)")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 12)
            if let updated = record.updatedAt {
                Text(updated, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityLabel(Text("最近更新 \(updated.formatted())"))
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .help(record.title)
    }

    private func details(_ record: WorkflowBatchCatalog.Record) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let source = record.sourceDirectory {
                LabeledContent("原照片文件夹") {
                    Text(source.path).lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled).help(source.path)
                }
            }
            if !record.canOpen {
                Text(record.progress == "旧版清单" ? "此清单需要使用创建它的版本打开。" : "可通过「从文件打开…」选择另一份清单。")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("从文件打开…") { importingFile = true }.disabled(!store.canSwitchBatch)
            Button("删除批次…", role: .destructive) { confirmingDeletion = true }
                .disabled(!canAct || selected?.batchID == nil)
            Spacer()
            Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(store.busy)
            Button("打开所选批次") { if let selected { open(selected.id) } }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAct || selected?.canOpen != true)
        }
        .padding(20)
    }

    // MARK: - 批次操作
    private func open(_ url: URL) {
        guard store.canSwitchBatch else { return }
        dismiss()
        store.openBatch(url)
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            records = try await store.batchCatalog.list()
            loadError = nil
            if !records.contains(where: { $0.id == selection }) { selection = records.first?.id }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func delete(_ record: WorkflowBatchCatalog.Record) async {
        actionError = nil
        do {
            try await store.deleteBatch(record)
            await reload()
        } catch {
            actionError = error.localizedDescription
        }
    }
}
