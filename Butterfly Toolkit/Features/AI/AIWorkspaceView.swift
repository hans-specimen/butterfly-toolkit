import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AIWorkspaceView: View {
    @ObservedObject var store: AIWorkspaceStore
    let page: ToolPage
    var navigate: (ToolPage) -> Void
    @State private var inspector = true
    @State private var showImport = false

    var body: some View {
        VStack(spacing: 0) {
            if store.catalog == nil && !store.isLoading {
                ContentUnavailableView {
                    Label("连接 Butterfly AI", systemImage: "brain")
                } description: {
                    Text("选择已配置好的 AI 项目以连接本机模型。素材只从指定的 butterfly-ai-footage 素材库载入。")
                } actions: { Button("选择 AI 项目…", action: store.chooseEngine).buttonStyle(.borderedProminent) }
            } else if store.isLoading && store.catalog == nil {
                ProgressView("正在读取本机资料…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch page {
                case .aiCutout: AICutoutView(store: store)
                case .aiSamples: AISamplesView(store: store, navigate: navigate)
                case .aiTraining: AITrainingView(store: store)
                case .aiModels: AIModelsView(store: store, navigate: navigate)
                default: EmptyView()
                }
            }
            Divider()
            HStack(spacing: 8) {
                if store.busy { ProgressView().controlSize(.small) }
                else { Image(systemName: store.error == nil ? "desktopcomputer" : "exclamationmark.triangle").foregroundStyle(store.error == nil ? Color.secondary : .orange) }
                Text(store.status).lineLimit(1).help(store.status)
                Spacer()
                if store.processingID != nil { Button("取消", action: store.cancel) }
                Text("本机处理").foregroundStyle(.tertiary)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 32)
        }
        .background(.background)
        .navigationTitle(page.rawValue)
        .navigationSubtitle("Butterfly Toolkit")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("选择 AI 项目…", action: store.chooseEngine)
                    Button("刷新记录") { store.load() }.disabled(store.enginePath.isEmpty)
                    Divider()
                    Text(store.enginePath.isEmpty ? "尚未连接" : store.enginePath)
                } label: { Label("AI 项目", systemImage: "externaldrive.connected.to.line.below") }
                    .disabled(store.busy)
                if page == .aiCutout {
                    Button(action: store.chooseImages) { Label("添加待抠图片", systemImage: "plus") }
                        .disabled(store.catalog == nil || store.busy).help("添加 PNG 或 JPEG，可多选，无需人工答案")
                }
                if page == .aiSamples {
                    Menu {
                        Button("导入三层 PSD…") { store.choosePSDs() }
                        Button("读取 PS 修正…") { store.choosePSDs(correction: true) }
                        Divider()
                        Button("导入已有成对 PNG…") { showImport = true }
                    } label: { Label("导入素材", systemImage: "plus") }.disabled(store.catalog == nil || store.busy)
                }
                if page == .aiCutout {
                    Button("在 PS 中修正", action: store.editSelectedInPhotoshop).disabled(store.busy || store.selected?.prediction == nil)
                    Button("读取 PS 修正…") { store.choosePSDs(correction: true); navigate(.aiSamples) }.disabled(store.busy)
                    Button(action: store.exportSelected) { Label("另存结果", systemImage: "square.and.arrow.up") }
                        .disabled(store.selected?.prediction == nil)
                }
                Button { inspector.toggle() } label: { Label("检查器", systemImage: "sidebar.right") }.help("显示或隐藏检查器")
            }
        }
        .inspector(isPresented: $inspector) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    inspectorContent
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }.inspectorColumnWidth(min: 230, ideal: 260, max: 300)
        }
        .sheet(isPresented: $showImport) { AIImportSheet(store: store) }
        .alert("AI 工作区", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("好", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .task { store.loadOnce() }
    }

    @ViewBuilder private var inspectorContent: some View {
        switch page {
        case .aiCutout:
            Text("图片信息").font(.headline)
            if let sample = store.selected {
                Divider()
                Text("文件").fontWeight(.semibold)
                AIInfoRow("尺寸", sample.dimensions)
                AIInfoRow("颜色", sample.color)
                AIInfoRow("参考答案", sample.reference == nil ? "无需答案，可直接抠图" : store.record(for: sample).referenceKind)
                if sample.alignment != "aligned" && sample.alignment != "not_applicable" {
                    Label(sample.reference == nil ? "原图需要重新添加" : sample.alignmentTitle, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(sample.alignmentNote).font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("处理").fontWeight(.semibold)
                Text(store.catalog?.model.name ?? "未连接模型")
                AIInfoRow("状态", store.processingID == sample.id ? "处理中" : (sample.prediction == nil ? "尚未处理" : "已有结果"))
                AIInfoRow("输出", "原尺寸透明 PNG")
                if let note = sample.resultNote, sample.prediction == nil { Text(note).font(.caption).foregroundStyle(.orange) }
                Picker("抠图模型", selection: $store.inferenceModelID) {
                    Text("预训练基础模型").tag("base")
                    ForEach(store.trainedModels) { run in Text(run.name).tag(run.id) }
                }.disabled(store.busy)
                Picker("计算设备", selection: $store.device) { Text("Mac GPU").tag("mps"); Text("CPU").tag("cpu") }.disabled(store.busy)
                Button(sample.prediction == nil ? "开始抠图" : "重新抠图", action: store.runInference)
                    .buttonStyle(.borderedProminent).disabled(store.busy || store.catalog?.model.available != true)
                Divider()
                Text("细节检查").fontWeight(.semibold)
                Text(store.catalog?.model.qualitySummary ?? "尚无质量记录").font(.callout).foregroundStyle(.secondary)
                Text("重点查看触角、白色缘毛、尾突与翅缘。拖动任一侧同步平移，双击回到整图。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("输出位置").fontWeight(.semibold)
                Button("在访达显示结果") { store.reveal(sample.prediction) }.disabled(sample.prediction == nil)
                Button("另存所选结果…", action: store.exportSelected).disabled(sample.prediction == nil)
            }
        case .aiSamples:
            Text("素材检查").font(.headline)
            if let sample = store.selected, sample.reference != nil {
                Divider()
                Text(sample.name).fontWeight(.medium)
                AIInfoRow("尺寸", sample.dimensions)
                AIInfoRow("标注", store.record(for: sample).referenceKind)
                Button("显示原图") { store.reveal(sample.original) }
                Button("显示人工答案") { store.reveal(sample.reference) }.disabled(sample.reference == nil)
                Divider()
                Label(sample.alignmentTitle, systemImage: sample.alignment == "aligned" ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(sample.alignment == "aligned" ? Color.secondary : .orange)
                Text(sample.alignmentNote).font(.callout).foregroundStyle(.secondary)
                if sample.alignment != "aligned" { Text("检查未通过，不能选入训练。请修正 PSD 后重新导入。").font(.caption).foregroundStyle(.orange) }
                if store.pendingAnswerCount > 0 {
                    Text("审阅所选素材后，点击确认答案；检查通过的素材即可用于训练。")
                        .font(.caption).foregroundStyle(.secondary)
                    AIConfirmAnswersButton(store: store)
                }
            }
        case .aiTraining:
            Text("训练准备").font(.headline)
            Divider()
            Text("本轮目标").fontWeight(.semibold)
            Text("用已确认的素材微调抠图模型，新版本单独保存。").foregroundStyle(.secondary)
            Divider()
            AIInfoRow("基础模型", store.catalog?.model.available == true ? "本机文件可用" : "未就绪")
            AIInfoRow("人工答案", "\(store.samples.filter { $0.reference != nil }.count) 份")
            AIInfoRow("对齐正常", "\(store.alignedCount) 份")
            AIInfoRow("可选训练素材", "\(store.trainingCandidates.count) 份")
            AIInfoRow("本次已选", "\(store.trainingSelection.count) 份")
            Divider()
            Label(store.isTraining ? "训练中" : "训练已接入", systemImage: store.isTraining ? "clock" : "checkmark.circle").foregroundStyle(.secondary)
            Text("使用 CPU 训练；新模型保存在 butterfly-matte/models，任务记录保存在项目 outputs/training。成功后，素材库中未变化的 PSD 会移入“已训练PSD”。")
                .font(.callout).foregroundStyle(.secondary)
        case .aiModels:
            Text("模型信息").font(.headline)
            Divider()
            Text(store.catalog?.model.name ?? "未连接").fontWeight(.medium)
            AIInfoRow("类型", "预训练基础模型")
            AIInfoRow("存储", "本机")
            Divider()
            Text("固定版本").fontWeight(.semibold)
            Text(store.catalog?.model.revision ?? "—").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Divider()
            Text("验证范围").fontWeight(.semibold)
            Text("数值对照仅说明 CPU 与 GPU 的计算一致性。白色缘毛质量尚未达到人工精修标准。")
                .font(.callout).foregroundStyle(.secondary)
            if let path = store.catalog?.model.numericCheckPath { Button("显示数值验证记录") { store.reveal(path) } }
        default: EmptyView()
        }
    }
}

struct AIInfoRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
    var body: some View {
        HStack(alignment: .top, spacing: 12) { Text(label).foregroundStyle(.secondary); Spacer(minLength: 2); Text(value).multilineTextAlignment(.trailing) }.font(.callout)
    }
}

struct AIImportSheet: View {
    @ObservedObject var store: AIWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var original: URL?
    @State private var reference: URL?
    @State private var kind = "人工精扣"
    @State private var confirmed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("导入成对训练素材").font(.title2).fontWeight(.semibold)
            Text("将已有 PNG 无损复制到素材库。PSD 请优先使用“三层 PSD”入口自动提取并检查。此 PNG 入口的内容对齐由你核对。")
                .foregroundStyle(.secondary)
            HStack { Button("选择原图 PNG…") { original = choosePNG("选择原图 PNG") }; Text(original?.lastPathComponent ?? "未选择").lineLimit(1) }
            HStack { Button("选择人工答案 PNG…") { reference = choosePNG("选择带透明度的人工答案 PNG") }; Text(reference?.lastPathComponent ?? "未选择").lineLimit(1) }
            Picker("答案来源", selection: $kind) { Text("人工精扣").tag("人工精扣"); Text("AI 结果经人工修正").tag("AI 结果经人工修正") }
            Toggle("我已逐像素检查对齐，并确认人工答案可作为标准答案", isOn: $confirmed)
            Text("未确认时可以导入供检查，但不能选入训练。AI 原始结果不能直接作为标准答案。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("取消", role: .cancel) { dismiss() }.disabled(store.busy)
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
                Button("复制并导入") {
                    guard let original, let reference else { return }
                    Task { if await store.importPair(original: original, reference: reference, kind: kind, confirmed: confirmed) { dismiss() } }
                }.buttonStyle(.borderedProminent).disabled(original == nil || reference == nil || store.busy)
            }
        }.padding(26).frame(width: 560)
    }
    private func choosePNG(_ title: String) -> URL? {
        let panel = NSOpenPanel(); panel.title = title; panel.allowedContentTypes = [.png]
        return panel.runModal() == .OK ? panel.url : nil
    }
}
