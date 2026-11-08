// 原生 SwiftUI 裁剪面板：固定 10% 留白与居中，提供逐图翅顶选点、主体框和安全批量输出。
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SmartCropView: View {
    @State private var store = SmartCropStore()
    @State private var interaction: SmartCropInteraction = .none
    @State private var pendingTips: [CGPoint] = []
    @State private var zoom = 1.0
    @State private var showOverwriteConfirmation = false
    @State private var inputError: String?

    var body: some View {
        HSplitView {
            inspector.frame(minWidth: 245,idealWidth: 270,maxWidth: 310)
            detail.frame(minWidth: 620,maxWidth: .infinity,maxHeight: .infinity)
        }
        .frame(minWidth: 900,minHeight: 620)
        .navigationTitle("智能裁剪")
        .dropDestination(for: URL.self) { urls,_ in
            guard !store.processing else { return false }
            receive(urls); return true
        }
        .alert("无法选择图片",isPresented: Binding(get: { inputError != nil },set: { if !$0 { inputError = nil } })) {
            Button("好",role: .cancel) { inputError = nil }
        } message: { Text(inputError ?? "") }
        .alert("覆盖原照片？",isPresented: $showOverwriteConfirmation) {
            Button("取消",role: .cancel) {}
            Button("覆盖并开始",role: .destructive) { store.start() }
        } message: { Text("将替换所选照片，不另建备份。需人工确认或处理失败的照片会跳过。") }
        .onChange(of: store.currentURL) { interaction = .none; pendingTips = []; zoom = 1 }
        .onAppear { store.resumePanel() }
        .onDisappear { store.leavePanel() }
    }

    // MARK: - 原生分组表单
    private var inspector: some View {
        Form {
            Section("照片") {
                HStack {
                    Button("选择图片",systemImage: "photo") { chooseImages() }
                    Button("文件夹",systemImage: "folder") { chooseFolder() }
                }
                if store.files.isEmpty { Text("也可拖入 JPEG 或文件夹").foregroundStyle(.secondary) }
                else { LabeledContent("已选择",value: "\(store.files.count) 张") }
            }
            Section("构图") {
                Picker("比例",selection: Binding(get: { store.ratio },set: { store.setRatio($0) })) {
                    ForEach(CropRatio.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                Text("自动扶正 · 居中 · 目标留白 10%")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("当前照片") {
                Button(interaction == .tips ? "取消选点" : "手动选翅顶",systemImage: "point.topleft.down.to.point.bottomright.curvepath") { toggle(.tips) }
                Button(interaction == .bounds ? "取消框选" : "手动框定主体",systemImage: "rectangle.dashed") { toggle(.bounds) }
                Button("恢复自动建议",systemImage: "arrow.counterclockwise") {
                    interaction = .none; pendingTips = []; store.edit { $0 = SmartCropAdjustment() }
                }
                // 微调是人工修正入口，不作为默认构图参数展示。
                DisclosureGroup("角度微调") {
                    HStack {
                        Button { adjustAngle(-0.1) } label: { Image(systemName: "minus") }
                        Text(String(format: "%+.2f°",store.preview?.plan?.solution.angleDegrees ?? 0)).monospacedDigit()
                        Button { adjustAngle(0.1) } label: { Image(systemName: "plus") }
                    }
                    Button("设为 0°") { store.edit { $0.manualAngle = 0; $0.tips = [] } }
                }
            }.disabled(store.preview == nil || store.loading)
            Section("输出") {
                Picker("保存方式",selection: $store.overwrite) {
                    Text("另存到文件夹").tag(false)
                    Text("覆盖原照片").tag(true)
                }.labelsHidden()
                if !store.overwrite {
                    Button("选择输出文件夹…",systemImage: "folder") { chooseOutput() }
                    if let folder = store.outputFolder {
                        Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(store.processing)
    }

    // MARK: - 预览、诊断与批处理
    private var detail: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.currentURL?.lastPathComponent ?? "预览").font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { store.move(-1) } label: { Image(systemName: "chevron.left") }.help("上一张").disabled(store.index == 0)
                Text(store.files.isEmpty ? "0 / 0" : "\(store.index+1) / \(store.files.count)").monospacedDigit()
                Button { store.move(1) } label: { Image(systemName: "chevron.right") }.help("下一张").disabled(store.index+1 >= store.files.count)
            }.padding().disabled(store.processing)
            Divider()
            if let source = store.source {
                HStack(spacing: 1) {
                    VStack(spacing: 8) {
                        HStack {
                            Text("原图").font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            Menu { ForEach([1.0,2,4],id: \.self) { value in Button("\(Int(value))×") { zoom = value } } }
                                label: { Label("\(Int(zoom))×",systemImage: "plus.magnifyingglass") }
                                .menuStyle(.borderlessButton).fixedSize()
                        }
                        SmartCropSourceCanvas(image: source.image,sourceSize: source.size,solution: store.preview?.plan?.solution,
                            manualBounds: store.adjustment.manualBounds,tips: pendingTips.isEmpty ? store.adjustment.tips : pendingTips,
                            interaction: interaction,zoom: zoom,onPoint: pick,onBounds: { rect in
                                interaction = .none; store.edit { $0.manualBounds = rect }
                            })
                    }
                    Divider()
                    VStack(spacing: 8) {
                        Text("裁剪预览").font(.subheadline).foregroundStyle(.secondary)
                        if let image = store.preview?.cropped {
                            Image(decorative: image,scale: 1).resizable().scaledToFit().frame(maxWidth: .infinity,maxHeight: .infinity)
                        } else if store.loading {
                            ProgressView("正在计算裁剪效果…").frame(maxWidth: .infinity,maxHeight: .infinity)
                        } else {
                            ContentUnavailableView("构图待调整",systemImage: "crop",description: Text("请调整主体范围、翅顶或比例"))
                        }
                    }
                }.padding().frame(maxHeight: .infinity).disabled(store.processing)
                if let preview = store.preview { status(preview) }
                if let error = store.errorMessage {
                    HStack { Text(error).foregroundStyle(.orange); Button("重新载入") { store.reload() } }
                        .font(.caption).padding([.horizontal,.bottom])
                }
            } else if store.loading {
                ProgressView("正在载入原图…").frame(maxWidth: .infinity,maxHeight: .infinity)
            } else if let error = store.errorMessage {
                ContentUnavailableView {
                    Label("无法生成预览",systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: { Button("重新载入") { store.reload() } }
                    .frame(maxWidth: .infinity,maxHeight: .infinity)
            } else {
                ContentUnavailableView("选择照片开始",systemImage: "crop.rotate",description: Text("拖入 JPEG，自动扶正并居中裁剪"))
                    .frame(maxWidth: .infinity,maxHeight: .infinity)
            }
            if !store.files.isEmpty {
                Divider()
                thumbnailStrip
            }
            Divider()
            HStack(spacing: 16) {
                VStack(alignment: .leading,spacing: 5) {
                    ProgressView(value: Double(store.completed),total: Double(max(1,store.files.count)))
                    Text("\(store.completed) / \(store.files.count) · 成功 \(store.success) · 跳过 \(store.skipped) · 失败 \(store.failed)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }.frame(maxWidth: .infinity)
                if store.processing { Button("取消",role: .cancel) { store.cancel() } }
                else {
                    Button("开始裁剪",systemImage: "play.fill") {
                        interaction = .none; pendingTips = []
                        if store.overwrite { showOverwriteConfirmation = true } else { store.start() }
                    }.buttonStyle(.borderedProminent).disabled(store.files.isEmpty || store.loading)
                }
            }.padding()

        }
    }

    private var thumbnailStrip: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(Array(store.files.enumerated()),id: \.element) { index,url in
                        Button { store.selectIndex(index) } label: {
                            VStack(spacing: 4) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                                    if let source = store.thumbnails[url] {
                                        Image(decorative: source.image,scale: 1).resizable().scaledToFit()
                                    } else { Image(systemName: "photo").foregroundStyle(.secondary) }
                                }.frame(width: 88,height: 64).clipShape(RoundedRectangle(cornerRadius: 5))
                                Text(url.lastPathComponent).font(.caption2).lineLimit(1).truncationMode(.middle).frame(width: 88)
                                if let record = store.records[url],record.outcome != nil || record.plan != nil {
                                    Text(record.outcome == "已导出" ? "已导出" : record.outcome != nil ? "需检查" : record.plan?.needsReview == true || record.plan?.solution.isApplicable == false ? "待确认" : "已计算")
                                        .font(.caption2).foregroundStyle(.secondary)
                                } else { Text(" ").font(.caption2) }
                            }.padding(5)
                                .background(store.index == index ? Color.accentColor.opacity(0.12) : .clear,in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(store.index == index ? Color.accentColor : .clear,lineWidth: 2))
                        }.buttonStyle(.plain).id(url)
                            .help(store.records[url]?.outcome ?? url.lastPathComponent)
                            .accessibilityLabel("选择图片 \(url.lastPathComponent)")
                    }
                }.padding(10)
            }.frame(height: 140).disabled(store.processing)
                .onChange(of: store.currentURL) { if let url = store.currentURL { reader.scrollTo(url,anchor: .center) } }
        }
    }

    private func status(_ preview: SmartCropPreview) -> some View {
        VStack(alignment: .leading,spacing: 6) {
            if interaction == .tips { Text("在原图上点击两个翅顶（\(pendingTips.count)/2），可放大后选点。") }
            else if interaction == .bounds { Text("在原图上拖出矩形，包含触角、翅缘和尾突。") }
            else if let solution = preview.plan?.solution,solution.isApplicable {
                Text("\(Int(solution.outputSize.width)) × \(Int(solution.outputSize.height)) px · 扶正 \(String(format: "%+.2f°",solution.angleDegrees))\(store.adjustment.manualBounds == nil ? "" : " · 手动主体范围")")
                Text(String(format: "实际留白  左 %.1f%% · 右 %.1f%% · 上 %.1f%% · 下 %.1f%%",solution.actualMargins.left*100,solution.actualMargins.right*100,solution.actualMargins.top*100,solution.actualMargins.bottom*100)).foregroundStyle(.secondary)
            }
            if let message = preview.message { Text(message).foregroundStyle(.orange) }
            if preview.plan?.needsReview == true,preview.plan?.solution.isApplicable == true {
                Button("已检查范围与角度，使用此构图") { store.confirm() }.disabled(store.processing || store.loading)
            }
            if store.adjustment.confirmed { Text("此图构图已确认").foregroundStyle(.secondary) }
        }.font(.caption).frame(maxWidth: .infinity,alignment: .leading).padding([.horizontal,.bottom])
    }

    // MARK: - 选点与文件选择
    private func toggle(_ mode: SmartCropInteraction) {
        interaction = interaction == mode ? .none : mode; pendingTips = []
    }
    private func pick(_ p: CGPoint) {
        guard interaction == .tips else { return }
        pendingTips.append(p)
        if pendingTips.count == 2 {
            let points = pendingTips
            guard abs(points[0].x-points[1].x) > 1 else { pendingTips = []; inputError = "两个翅顶的横向位置太近，请重新选择。"; return }
            interaction = .none; pendingTips = []
            store.edit { $0.tips = points; $0.manualAngle = nil }
        }
    }
    private func adjustAngle(_ delta: Double) {
        let value = min(30,max(-30,(store.preview?.plan?.solution.angleDegrees ?? 0)+delta))
        store.edit { $0.manualAngle = value; $0.tips = [] }
    }
    private func chooseImages() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.jpeg]; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { receive(panel.urls) }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK,let url = panel.url { receive([url]) }
    }
    private func chooseOutput() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK { store.outputFolder = panel.url }
    }
    private func receive(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        do {
            let files: [URL],output: URL
            if urls.count == 1,(try urls[0].resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
                files = try FileManager.default.contentsOfDirectory(at: urls[0],includingPropertiesForKeys: [.isRegularFileKey],options: [.skipsHiddenFiles])
                    .filter { ButterflyCropProcessor.supportedExtensions.contains($0.pathExtension.lowercased()) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                output = urls[0].deletingLastPathComponent().appendingPathComponent(urls[0].lastPathComponent+"_智能裁剪")
            } else {
                guard urls.allSatisfy({ ButterflyCropProcessor.supportedExtensions.contains($0.pathExtension.lowercased()) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }) else {
                    inputError = "请选择 JPEG 图片或一个文件夹。"; return
                }
                files = urls; output = urls[0].deletingLastPathComponent().appendingPathComponent("智能裁剪输出")
            }
            guard !files.isEmpty else { inputError = "没有找到 JPEG 图片。"; return }
            interaction = .none; pendingTips = []; zoom = 1; store.select(files,output: output)
        } catch { inputError = error.localizedDescription }
    }
}
