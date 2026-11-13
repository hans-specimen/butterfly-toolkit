// 组装 AI 工作区页面、工具栏和检查器，并提供标本分组设置及成对训练素材导入界面。

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 工作区容器与页面路由

struct AIWorkspaceView: View {
    @ObservedObject var store: AIWorkspaceStore
    let page: ToolPage
    var navigate: (ToolPage) -> Void
    @State private var inspector = true
    @State private var showImport = false
    @State private var showCuration = false

    var body: some View {
        VStack(spacing: 0) {
            if store.catalog == nil && !store.isLoading {
                ContentUnavailableView {
                    Label("连接 Butterfly AI", systemImage: "brain")
                } description: {
                    Text("选择已配置好的 AI 项目文件夹，载入本机模型与已有测试结果。Toolkit 与 AI 项目保持独立。")
                } actions: { Button("选择 AI 项目…", action: store.chooseEngine).buttonStyle(.borderedProminent) }
            } else if store.isLoading && store.catalog == nil {
                ProgressView("正在读取本机资料…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 共用一个工作区状态，切换页面时保留样本选择和处理进度。
                switch page {
                case .aiCutout: AICutoutView(store: store)
                case .aiSamples: AISamplesView(store: store)
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
                    Button("载入测试批次…", action: store.chooseRun).disabled(store.enginePath.isEmpty)
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
                    Button { showImport = true } label: { Label("导入训练素材", systemImage: "plus") }
                        .disabled(store.catalog == nil || store.busy).help("导入原图与人工答案 PNG")
                }
                if page == .aiCutout {
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
        .sheet(isPresented: $showCuration) { if let sample = store.selected { AICurationSheet(store: store, sample: sample) } }
        .alert("AI 工作区", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("好", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .task { store.loadOnce() }
    }

    // MARK: - 当前页面检查器

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
                if sample.alignment != "aligned" { Text("对齐问题处理并重新核对前，不能选入训练。请导入修正后的成对 PNG。").font(.caption).foregroundStyle(.orange) }
                Divider()
                Text("训练用途").fontWeight(.semibold)
                AIInfoRow("标本组", store.record(for: sample).specimenGroup.isEmpty ? "待确认" : store.record(for: sample).specimenGroup)
                AIInfoRow("用途", store.curation.use(for: sample.id).rawValue)
                Text("同一只标本的正反面及所有裁切共用标本组；修改用途会作用于整组。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("设置标本组与用途…") { showCuration = true }
            }
        case .aiTraining:
            Text("训练准备").font(.headline)
            Divider()
            Text("本轮目标").fontWeight(.semibold)
            Text("从少量人工精扣样本验证模型能否学会保留细毛。真实训练需后续接入。").foregroundStyle(.secondary)
            Divider()
            AIInfoRow("基础模型", store.catalog?.model.available == true ? "本机文件可用" : "未就绪")
            AIInfoRow("人工答案", "\(store.samples.filter { $0.reference != nil }.count) 份")
            AIInfoRow("对齐正常", "\(store.alignedCount) 份")
            AIInfoRow("可选训练素材", "\(store.trainingCandidates.count) 份")
            AIInfoRow("本次已选", "\(store.trainingSelection.count) 份")
            Divider()
            Label("训练后端未接入", systemImage: "pause.circle").foregroundStyle(.secondary)
            Text("尚无真实训练任务、进度或训练结果。当前设置只用于准备，不会运行训练。")
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

// MARK: - 检查器信息行

struct AIInfoRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
    var body: some View {
        HStack(alignment: .top, spacing: 12) { Text(label).foregroundStyle(.secondary); Spacer(minLength: 2); Text(value).multilineTextAlignment(.trailing) }.font(.callout)
    }
}

// MARK: - 标本组与用途设置

struct AICurationSheet: View {
    @ObservedObject var store: AIWorkspaceStore
    let sample: AISample
    @Environment(\.dismiss) private var dismiss
    @State private var group = ""
    @State private var confirmed = false
    @State private var use: AISampleUse = .unassigned
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("标本组与用途").font(.title2).fontWeight(.semibold)
            Text(sample.name).foregroundStyle(.secondary)
            TextField("标本编号（同只标本使用同一编号）", text: $group.replacingTabs)
            if let message = ToolkitTextInput.singleLineError(group) {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            Toggle("我已确认：此编号涵盖同一只标本的正反面与所有裁切", isOn: $confirmed)
            Picker("整组用途", selection: $use) { ForEach(AISampleUse.allCases) { Text($0.rawValue).tag($0) } }
            Text("这只保存分组信息，不启动训练。对齐异常的图片即使属于训练组，也无法选入训练任务。")
                .font(.callout).foregroundStyle(.secondary)
            // 保存操作交由工作区按标本组更新用途，同时清理不再合格的训练选择。
            HStack { Button("取消", role: .cancel) { dismiss() }; Spacer(); Button("保存") {
                store.updateCuration(sample: sample, group: group, confirmed: confirmed, use: use); dismiss()
            }.buttonStyle(.borderedProminent).disabled(group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !confirmed || ToolkitTextInput.singleLineError(group) != nil) }
        }.padding(26).frame(width: 500)
            .onAppear { let record = store.record(for: sample); group = record.specimenGroup; confirmed = record.groupConfirmed; use = store.curation.use(for: sample.id) }
    }
}

// MARK: - 成对素材导入

struct AIImportSheet: View {
    @ObservedObject var store: AIWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var original: URL?
    @State private var reference: URL?
    @State private var group = ""
    @State private var kind = "人工精扣"
    @State private var confirmed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("导入成对训练素材").font(.title2).fontWeight(.semibold)
            Text("无损复制到 AI 项目的派生素材目录，原始文件保持不变。请先从 PSD 导出同尺寸、同位置的 PNG。")
                .foregroundStyle(.secondary)
            HStack { Button("选择原图 PNG…") { original = choosePNG("选择原图 PNG") }; Text(original?.lastPathComponent ?? "未选择").lineLimit(1) }
            HStack { Button("选择人工答案 PNG…") { reference = choosePNG("选择带透明度的人工答案 PNG") }; Text(reference?.lastPathComponent ?? "未选择").lineLimit(1) }
            Picker("答案来源", selection: $kind) { Text("人工精扣").tag("人工精扣"); Text("AI 结果经人工修正").tag("AI 结果经人工修正") }
            TextField("标本组编号（同只标本使用同一编号）", text: $group.replacingTabs)
            if let message = ToolkitTextInput.singleLineError(group) {
                Text(message).font(.caption).foregroundStyle(.red)
            }
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
                    // 仅成功导入后关闭弹窗；失败时保留选择，便于查看错误并重试。
                    Task { if await store.importPair(original: original, reference: reference, group: group, kind: kind, confirmed: confirmed) { dismiss() } }
                }.buttonStyle(.borderedProminent).disabled(original == nil || reference == nil || store.busy || ToolkitTextInput.singleLineError(group) != nil || (confirmed && group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }.padding(26).frame(width: 560)
    }
    private func choosePNG(_ title: String) -> URL? {
        let panel = NSOpenPanel(); panel.title = title; panel.allowedContentTypes = [.png]
        return panel.runModal() == .OK ? panel.url : nil
    }
}
