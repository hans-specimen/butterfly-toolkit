// 构建照片工作流的批次准备、标本队列、正反面预览和参数检查界面，将操作交给状态存储执行。

import SwiftUI
import UniformTypeIdentifiers
import ImageIO

// MARK: - 阶段与状态显示
extension WorkflowStage {
    var title: String {
        switch self { case .stack: "景深合成"; case .matte: "PS 抠图"; case .geometry: "旋转裁切"; case .hd: "堆栈原图"; case .png4k: "4K PNG"; case .derivatives: "派生图片" }
    }
}
extension WorkflowStatus {
    var title: String {
        switch self { case .pending: "待处理"; case .running: "处理中"; case .waitingReview: "等待检查"; case .completed: "已完成"; case .failed: "失败"; case .excluded: "已排除" }
    }
}

// MARK: - 工作流页面
struct PhotoWorkflowView: View {
    @ObservedObject var store: PhotoWorkflowStore
    @State private var selectedDraftID: UUID?
    @State private var singleFace = false
    @State private var exportScope = "此图"
    @State private var reprocessStage: WorkflowStage?
    @State private var cleanupReports: [UUID: (version: String,report: MaskCleanupReport?)] = [:]
    @State private var showCleanupRegions = false
    @Environment(\.colorScheme) private var colorScheme
    private var panelBackground: Color { colorScheme == .dark ? Color(white: 0.16) : Color(nsColor: .windowBackgroundColor) }
    private var canvasBackground: Color { colorScheme == .dark ? Color(white: 0.13) : Color(nsColor: .textBackgroundColor) }
    private let queueWidth: CGFloat = 210
    private let inspectorWidth: CGFloat = 300
    private func stageTitle(_ stage: WorkflowStage) -> String {
        if store.usesFinalization && stage == .geometry { return "旋转矫正" }
        if store.usesFinalization && stage == .hd { return "人工检查" }
        if store.usesFinalization && stage == .png4k { return "导出" }
        return stage == .stack && store.currentTask?.sources.isPSD == true ? "已有 PSD" : stage.title
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("照片工作流").font(.title2.bold())
                    Text("收藏标本 · 正面 D / 反面 V").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("打开批次清单…") { chooseFile(types: [.json]) { store.openBatch($0) } }.disabled(store.busy || store.manualTaskID != nil)
                if store.batch != nil {
                    Button("关闭批次／新建") { store.closeBatch() }.disabled(store.busy || store.manualTaskID != nil)
                    Menu("查看文件") {
                        if let url = store.workingPSDDirectory { Button("工作 PSD") { NSWorkspace.shared.open(url) } }
                        if let url = store.exportDirectory(for: .hd) { Button("堆栈原图") { NSWorkspace.shared.open(url) } }
                        if let url = store.exportDirectory(for: .png4k) { Button("PNG4K") { NSWorkspace.shared.open(url) } }
                        if let url = store.batch?.outputDirectory { Button("批次记录") { NSWorkspace.shared.open(url) } }
                    }
                }
            }.padding(.horizontal,24).padding(.vertical,20)
            Divider()
            if store.batch == nil { setup.disabled(store.busy) }
            else { execution }
            if let notice = store.notice { HStack { Text(notice).font(.caption); Spacer(); Button("关闭") { store.notice = nil } }.padding(10) }
            if let error = store.error { HStack { Image(systemName: "exclamationmark.triangle.fill"); Text(error).textSelection(.enabled); Spacer(); Button("关闭") { store.error = nil } }.foregroundStyle(.red).padding(10).background(.red.opacity(0.07)) }
        }
        .background(panelBackground)
        .frame(minWidth: 980,minHeight: 640)
        .onChange(of: store.currentSpecimenID) { store.cancelMove(); store.prepareSelected() }
        .onChange(of: store.selectedSpecimens) { store.prepareSelected() }
        .onChange(of: store.face) { store.cancelMove(); store.refreshVisibleImage() }
        .onDisappear { store.cancelMove() }
    }
    // MARK: - 批次准备与固定槽位核对
    private var setup: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                draftQueue.frame(width: queueWidth)
                Divider()
                draftPreview.frame(maxWidth: .infinity,maxHeight: .infinity)
                Divider()
                ScrollView { setupInspector.padding(20) }
                    .frame(width: inspectorWidth)
                    .background(panelBackground)
            }
            Divider()
            HStack(spacing: 12) {
                Image(systemName: "photo.stack").foregroundStyle(.secondary)
                Text(store.draft.map { "\($0.groups.filter { !$0.excluded }.count) 只待处理 · \($0.inputMode == .psd ? "正反面各一份 PSD" : "正反面各三张")" } ?? "选择输入文件夹，开始建立收藏批次")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(store.busy ? "正在准备批次…" : (store.inputMode == .psd ? "从 PS 抠图开始" : "开始处理")) { store.start() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(store.busy || !store.canStart)
            }.padding(.horizontal,24).padding(.vertical,14)
        }
    }
    private var selectedDraftIndex: Int? {
        guard let groups = store.draft?.groups,!groups.isEmpty else { return nil }
        return groups.firstIndex { $0.id == selectedDraftID } ?? 0
    }
    private func draftName(_ index: Int) -> String {
        let names = store.names.components(separatedBy: .newlines)
        if names.indices.contains(index),!names[index].trimmingCharacters(in: .whitespaces).isEmpty { return names[index] }
        return String(format: "标本 %02d",index+1)
    }
    private var draftQueue: some View {
        VStack(alignment: .leading,spacing: 0) {
            HStack { Text("待处理蝴蝶").font(.headline); Spacer(); Text("\(store.draft?.groups.count ?? 0)").foregroundStyle(.secondary) }.padding(18)
            Divider()
            ScrollView {
                LazyVStack(spacing: 8) {
                    if let draft = store.draft {
                        ForEach(Array(draft.groups.enumerated()),id: \.element.id) { index,group in
                            Button { selectedDraftID = group.id } label: {
                                HStack(spacing: 10) {
                                    WorkflowFileThumbnail(url: group.files.first ?? nil)
                                        .frame(width: 46,height: 46).clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading,spacing: 5) {
                                        Text(draftName(index)).font(.body.weight(.medium)).lineLimit(1)
                                        Text(group.excluded ? "已排除" : "等待处理").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(10).frame(maxWidth: .infinity,alignment: .leading)
                                    .background(selectedDraftIndex == index ? Color.accentColor.opacity(0.16) : .clear,in: RoundedRectangle(cornerRadius: 9))
                                    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(selectedDraftIndex == index ? Color.accentColor.opacity(0.35) : .clear) }
                                    .opacity(group.excluded ? 0.5 : 1)
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(10)
            }
            Text("选择标本查看正反面").font(.caption).foregroundStyle(.secondary).padding(18)
        }.background(panelBackground)
    }
    private var draftPreview: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 24) {
                if let index = selectedDraftIndex,let group = store.draft?.groups[index] {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading,spacing: 7) {
                            Text(draftName(index)).font(.title2.bold())
                            Text("共 \(store.draft?.photoCount ?? 0) \(store.inputMode == .psd ? "份 PSD" : "张照片") · 核对分组与正反面").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(group.excluded ? "已排除" : "待处理").font(.caption.weight(.medium)).padding(.horizontal,10).padding(.vertical,6)
                            .background(Color.accentColor.opacity(0.12),in: Capsule())
                    }
                    ForEach(0..<2) { side in
                        VStack(alignment: .leading,spacing: 12) {
                            HStack { Text(side == 0 ? "正面 D" : "反面 V").font(.headline); Spacer(); Text(store.inputMode == .psd ? "已合成 PSD" : "3 张原图").font(.caption).foregroundStyle(.secondary) }
                            HStack(alignment: .top,spacing: 12) {
                                ForEach(0..<store.inputMode.filesPerSide,id: \.self) { offset in
                                    // 每面的槽位固定；移除或替换不会重新排列其他输入。
                                    let slot = side*store.inputMode.filesPerSide+offset
                                    VStack(alignment: .leading,spacing: 8) {
                                        WorkflowFileThumbnail(url: group.files[slot]).aspectRatio(1.2,contentMode: .fit)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                        Text(group.files[slot]?.lastPathComponent ?? "缺图：需要替换").font(.caption).lineLimit(1).truncationMode(.middle)
                                        HStack(spacing: 10) {
                                            Button("替换") { chooseFile(types: store.inputMode == .psd ? [UTType(filenameExtension: "psd") ?? .data] : [.jpeg]) { store.draft?.groups[index].files[slot] = $0 } }
                                            Button("移除") { store.draft?.groups[index].files[slot] = nil }
                                        }.font(.caption).buttonStyle(.borderless)
                                    }.frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                    Divider()
                    HStack {
                        Button("交换正反面",systemImage: "arrow.up.arrow.down") { store.draft?.groups[index].swapFaces() }
                        Spacer()
                        Toggle("排除整组",isOn: Binding(get: { store.draft?.groups[index].excluded ?? false },set: { store.draft?.groups[index].excluded = $0 })).toggleStyle(.checkbox)
                    }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 42,weight: .light)).foregroundStyle(.tertiary)
                        Text(store.inputMode == .psd ? "导入已合成的 PSD" : "导入第一批蝴蝶照片").font(.title3.weight(.semibold))
                        Text(store.inputMode == .psd ? "按 文件名_D.psd / 文件名_V.psd 配对。\n复制工作 PSD 后，继续 PS 抠图和裁切矫正。" : "每只蝴蝶六张照片，正反面各三张。\n导入后在左侧选择标本，在这里核对原图。")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("选择输入文件夹…",systemImage: "folder") { chooseFolder { store.scan($0) } }.controlSize(.large)
                    }.frame(maxWidth: .infinity).padding(.vertical,100)
                }
                if let draft = store.draft {
                    if !draft.remainder.isEmpty {
                        VStack(alignment: .leading,spacing: 8) {
                            Toggle(draft.inputMode == .psd ? "排除这 \(draft.remainder.count) 份未配对或后缀不明的 PSD" : "明确排除剩余 \(draft.remainder.count) 张试拍",isOn: Binding(get: { store.draft?.ignoreRemainder ?? false },set: { store.draft?.ignoreRemainder = $0 }))
                            Text(draft.remainder.map(\.lastPathComponent).joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !draft.otherFiles.isEmpty { Text(draft.inputMode == .psd ? "\(draft.otherFiles.count) 个非 PSD 文件未参与处理" : "其他格式未参与：\(draft.otherFiles.map(\.lastPathComponent).joined(separator: "、"))").font(.caption).foregroundStyle(.secondary) }
                }
            }.padding(24).frame(maxWidth: 1040).frame(maxWidth: .infinity,alignment: .topLeading)
        }.background(canvasBackground)
    }
    private var setupInspector: some View {
        VStack(alignment: .leading,spacing: 24) {
            inspectorSection("开始阶段",icon: "play.circle") {
                Picker("开始阶段",selection: $store.inputMode) {
                    ForEach(WorkflowInputMode.allCases,id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().pickerStyle(.menu)
            }
            Divider()
            inspectorSection("批次目录",icon: "folder") {
                directoryControl(store.inputMode == .psd ? "已合成 PSD" : "原始照片",url: store.draft?.directory,placeholder: store.inputMode == .psd ? "选择包含 D/V 配对 PSD 的文件夹" : "选择 JPG / JPEG 文件夹") { chooseFolder { store.scan($0) } }
                Text(store.inputMode == .psd ? "处理结果直接保存回原 PSD，首次写入前保留原始快照。" : "PSD 自动保存在原照片文件夹内的「原文件夹名_psd」子文件夹。").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            inspectorSection("名称清单",icon: "text.alignleft") {
                TextEditor(text: $store.names).font(.body).scrollContentBackground(.hidden)
                    .padding(8).frame(height: 112)
                    .background(Color(nsColor: .textBackgroundColor),in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary) }
                Text(store.inputMode == .psd ? "已从 PSD 文件名填入；改名仅影响导出名称，不改原 PSD 文件名。" : "每只一行，与左侧顺序对应；排除整组时保留原行。").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            inspectorSection("人工检查",icon: "checkmark.circle") { Text("每面自动完成 PS 抠图与矫正后进入待检查，继续处理下一面。检查确认后可单独或批量导出。").font(.caption).foregroundStyle(.secondary) }
            Divider()
            exportLocations
            Divider()
            inspectorSection("PS 抠图",icon: "sparkles") {
                Text("选择主体 → 保留原始蒙版 → 副本色阶 15 / 1.00 / 240").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity,alignment: .leading).toggleStyle(.checkbox)
    }
    private func directoryControl(_ title: String,url: URL?,placeholder: String,action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading,spacing: 6) {
            HStack { Text(title).font(.callout); Spacer(); Button(url == nil ? "选择…" : "更改…",action: action).font(.caption) }
            Text(url.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? placeholder).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                .help(url?.path ?? placeholder)
        }
    }
    private func inspectorSection<Content: View>(_ title: String,icon: String,@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading,spacing: 14) {
            Label(title,systemImage: icon).font(.subheadline.weight(.semibold))
            content()
        }.frame(maxWidth: .infinity,alignment: .leading)
    }
    @ViewBuilder private func exportLocation(_ kind: WorkflowAssetKind) -> some View {
        directoryControl(kind == .hd ? "堆栈原图 JPEG（Stack）" : "透明 PNG4K（Keying_Level）",url: store.exportDirectory(for: kind),placeholder: "请选择导出文件夹") {
            chooseFolder { store.selectExportDirectory($0,kind: kind) }
        }.disabled(store.busy || store.manualTaskID != nil)
    }
    private var exportLocations: some View {
        inspectorSection("导出位置", icon: "square.and.arrow.down") {
            exportLocation(.hd)
            exportLocation(.png4k)
            Text(store.batch == nil || store.usesFinalization ? "默认在输入文件夹内创建输出目录，也可分别更改。" : "两个目录可分别指定，流程在 PNG4K 导出后结束。").font(.caption).foregroundStyle(.secondary)
        }
    }
    // MARK: - 执行队列与正反面对照
    private var execution: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                queue.frame(width: queueWidth)
                Divider()
                executionPreview.frame(maxWidth: .infinity,maxHeight: .infinity)
                Divider()
                ScrollView { parameters.padding(20) }.frame(width: inspectorWidth)
                    .background(panelBackground)
            }
            Divider()
            HStack(spacing: 12) {
                if store.busy { ProgressView().controlSize(.small); Text(store.runningDescription ?? "正在安全处理，请勿在 PS 中同时编辑").font(.caption) }
                else if store.batch?.allSucceeded == true { Label("全部输出已完成",systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                else { Text(store.batch?.isPaused == true ? "已暂停 · 保存并刷新后继续" : store.batchSummary).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Menu("更多操作") {
                    Button("重试自动处理失败项") { store.retry() }
                    Button("暂不处理所选标本") { store.excludeSelected() }.disabled(store.busy || store.manualTaskID != nil || store.selectedSpecimens.isEmpty)
                }.fixedSize()
                if store.canResumeAutomatic { Button(store.usesFinalization ? (store.stage == .png4k ? "继续导出" : "继续自动准备") : "明确继续批处理") { store.resume() }.disabled(store.busy) }
                else if store.busy { Button("暂停") { store.pause() } }
                Button("批量导出") { exportScope = "全部已确认"; store.stage = .png4k }
                Button(primaryTitle) { if store.stage == .png4k { store.exportImages(scope: exportScope) } else { store.primary() } }.buttonStyle(.borderedProminent).controlSize(.large).disabled(primaryDisabled)
            }.padding(.horizontal,24).padding(.vertical,14)
        }
    }
    private var executionPreview: some View {
        VStack(alignment: .leading,spacing: 20) {
            HStack {
                VStack(alignment: .leading,spacing: 6) {
                    Text(store.currentSpecimen?.baseName ?? "请选择标本").font(.title2.bold())
                    Text(store.batchSummary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if store.runningTask != nil { Button("定位正在处理") { store.locateRunning() }.font(.caption) }
                if let task = store.currentTask {
                    Text(store.summaryRecord(task).state.title).font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
                        .padding(.horizontal,10).padding(.vertical,6).background(Color.accentColor.opacity(0.12),in: Capsule())
                }
            }
            ScrollView(.horizontal,showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(WorkflowStage.processingStages.enumerated()),id: \.element) { index,stage in
                        Button { store.stage = stage } label: {
                            HStack(spacing: 5) {
                                Text("\(index+1)").font(.caption2.bold()).frame(width: 18,height: 18).background(store.stage == stage ? Color.accentColor : Color.secondary.opacity(0.14),in: Circle()).foregroundStyle(store.stage == stage ? .white : .secondary)
                                VStack(alignment: .leading,spacing: 3) {
                                    Text(stageTitle(stage)).font(.caption).fixedSize()
                                    Text(panelStatus(stage)).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }.padding(.horizontal,8).padding(.vertical,8)
                                .background(store.stage == stage ? Color.accentColor.opacity(0.1) : .clear,in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                    }
                }
            }
            Divider()
            HStack {
                Text(stageTitle(store.stage)).font(.headline)
                Spacer()
                Button { singleFace.toggle() } label: { Label(singleFace ? "正反面对照" : "单面放大",systemImage: singleFace ? "rectangle.split.2x1" : "arrow.up.left.and.arrow.down.right") }.buttonStyle(.borderless).font(.caption)
            }
            if let specimen = store.currentSpecimen {
                HStack(alignment: .top,spacing: 16) {
                    if !singleFace || store.face == .front { facePreview(specimen.front) }
                    if !singleFace || store.face == .back { facePreview(specimen.back) }
                }.frame(maxWidth: .infinity,maxHeight: 560)
                HStack(spacing: 10) {
                    Picker("当前编辑面",selection: $store.face) { Text("正面 D").tag(WorkflowSide.front); Text("反面 V").tag(WorkflowSide.back) }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 148)
                    Spacer(minLength: 4)
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Slider(value: $store.zoom,in: 0.5...4).frame(width: 80)
                    Text("\(Int(store.zoom*100))%").monospacedDigit().font(.caption).frame(width: 36)
                }
                HStack {
                    Text("点击正面或反面，切换右侧参数").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(store.currentDetailReady ? "返回快速预览" : "加载原图细节") { if store.currentDetailReady { store.useQuickPreview() } else { store.loadCurrentDetail() } }
                        .font(.caption).buttonStyle(.borderless).disabled((store.manualTaskID != nil && !store.usesFinalization) || store.currentTask?.roleImages == nil)
                }
                Spacer(minLength: 0)
            } else { ContentUnavailableView("请选择标本",systemImage: "photo").frame(maxHeight: .infinity) }
        }.padding(24).background(canvasBackground)
    }
    private func cleanupReport(for task: WorkflowSideTask) -> MaskCleanupReport? {
        guard let snapshot = task.snapshot,snapshot.cleanupSnapshotVersion == snapshot.contentVersion,
              cleanupReports[task.id]?.version == snapshot.contentVersion else { return nil }
        return cleanupReports[task.id]?.report
    }
    private func cleanupRegions(for task: WorkflowSideTask) -> [CGRect] {
        guard let report = cleanupReport(for: task),let snapshot = task.snapshot else { return [] }
        return report.regions.filter { $0.decision == .uncertain }.map { snapshot.cleanupDisplayBounds($0.bounds) }
    }
    @ViewBuilder private func cleanupSummary(for task: WorkflowSideTask) -> some View {
        let report = cleanupReport(for: task)
        if let solution = task.geometrySolution {
            let applied = store.usesFinalization || task[.geometry].state == .completed
            Text(applied || !solution.isApplicable ? WorkflowCleanupStatus.title(solution: solution,report: report,targetMargin: task.geometryRequest.targetMargin) : "裁切方案待确认")
                .font(.caption).foregroundStyle(solution.isApplicable ? Color.secondary : Color.primary)
        }
        if let report,let snapshot = task.snapshot {
            let regions = report.regions.filter { $0.decision != .retainedDetail }
            if !regions.isEmpty {
                DisclosureGroup("蒙版清理详情 · 已清理 \(report.removedPixelCount) 像素") {
                    VStack(alignment: .leading,spacing: 6) {
                        if regions.contains(where: { $0.decision == .uncertain }) {
                            Toggle("标出待检查区域",isOn: $showCleanupRegions).toggleStyle(.checkbox)
                        }
                        ForEach(Array(regions.enumerated()),id: \.offset) { _,region in
                            Text(WorkflowCleanupStatus.message(region: region,bounds: snapshot.cleanupDisplayBounds(region.bounds),size: snapshot.pixelSize))
                                .foregroundStyle(region.decision == .uncertain ? Color.primary : Color.secondary)
                        }
                    }.padding(.top,4)
                }.font(.caption)
            }
        } else if let cached = cleanupReports[task.id],cached.version == task.snapshot?.contentVersion,task.snapshot?.cleanupReportURL != nil {
            Text("清理报告暂不可用，请以当前 PSD 为准").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func facePreview(_ task: WorkflowSideTask) -> some View {
        let active = store.face == task.side
        return VStack(alignment: .leading,spacing: 10) {
            Button { store.face = task.side } label: {
                HStack {
                    Text(task.side == .front ? "正面" : "反面").font(.headline)
                    Spacer()
                    Text(task.side.fileSuffix).font(.caption)
                }.foregroundStyle(active ? Color.accentColor : Color.secondary)
            }.buttonStyle(.plain)
            Group {
                if let roles = task.roleImages {
                    WorkflowGeometryPreview(image: store.displayImage(for: task),source: roles,
                        solution: active ? store.currentPreviewSolution : store.solutions[task.id] ?? task.geometrySolution,
                        square: store.stage == .png4k ? (active ? store.currentPreviewLayout : store.layouts[task.id] ?? task.squareLayout) : nil,
                        zoom: store.zoom,background: store.previewBackground,showSafeFrame: store.showSafeFrame,savedCanvasOnly: store.usesFinalization,
                        cleanupRegions: showCleanupRegions ? cleanupRegions(for: task) : [],
                        interactionStarted: store.previewInteractionStarted[task.id],onSourcePoint: store.pickTip,onMoveChanged: store.updateMove,onMoveEnded: store.commitMove)
                        .allowsHitTesting(active)
                        .overlay(alignment: .topLeading) {
                            if store.loading.contains(task.id) { ProgressView().controlSize(.small).padding(10).background(.regularMaterial,in: RoundedRectangle(cornerRadius: 6)) }
                        }
                } else { WorkflowFileThumbnail(url: task.stackPNG?.pngURL ?? task.snapshot?.snapshotURL ?? task.sources.first.url) }
            }.frame(maxWidth: .infinity,maxHeight: .infinity).frame(minHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(active ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.2),lineWidth: active ? 2 : 1) }
                .overlay { if !active { Color.clear.contentShape(Rectangle()).onTapGesture { store.face = task.side } } }
            cleanupSummary(for: task)
                .task(id: task.snapshot) {
                    guard let snapshot = task.snapshot,snapshot.cleanupSnapshotVersion == snapshot.contentVersion else {
                        cleanupReports[task.id] = nil; return
                    }
                    let report = await Task.detached(priority: .utility) { try? snapshot.validatedCleanupReport() }.value
                    guard !Task.isCancelled else { return }
                    cleanupReports[task.id] = (snapshot.contentVersion,report)
                }
            Text("\(store.currentSpecimen?.baseName ?? "")_\(task.side.fileSuffix)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if store.stage == .stack || store.stage == .matte {
                HStack(spacing: 6) {
                    ForEach(task.sources.files,id: \.url) { source in
                        VStack(spacing: 4) {
                            WorkflowFileThumbnail(url: source.url).frame(height: 48).clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(source.url.lastPathComponent).font(.system(size: 9)).lineLimit(1).truncationMode(.middle)
                        }.frame(maxWidth: .infinity)
                    }
                }
            }
            if let message = store.displayedRecord(task).error { Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.frame(maxWidth: .infinity)
    }
    private var queue: some View {
        VStack(alignment: .leading,spacing: 0) {
            HStack { Text("本批标本").font(.headline); Spacer(); Text("\(store.batch?.specimens.count ?? 0)").foregroundStyle(.secondary) }.padding(18)
            Picker("筛选",selection: $store.queueFilter) { ForEach(["全部","失败","待检查","已确认","待导出"],id: \.self) { Text($0) } }.padding(.horizontal,12)
            Divider()
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(store.filteredSpecimens) { specimen in
                        VStack(alignment: .leading,spacing: 9) {
                            HStack(spacing: 7) {
                                Toggle("选择 \(specimen.baseName)",isOn: Binding(get: { store.selectedSpecimens.contains(specimen.id) },set: { if $0 { store.selectedSpecimens.insert(specimen.id); store.selectedTaskIDs.formUnion([specimen.front.id,specimen.back.id]) } else { store.selectedSpecimens.remove(specimen.id); store.selectedTaskIDs.subtract([specimen.front.id,specimen.back.id]) } }))
                                    .labelsHidden().toggleStyle(.checkbox).disabled(specimen.isExcluded)
                                Button { store.currentSpecimenID = specimen.id } label: {
                                    Text(specimen.baseName).font(.body.weight(.medium)).lineLimit(1).frame(maxWidth: .infinity,alignment: .leading)
                                }.buttonStyle(.plain)
                            }
                            HStack(spacing: 9) {
                                ForEach([specimen.front,specimen.back]) { task in
                                    VStack(alignment: .leading,spacing: 5) {
                                        Toggle(task.side == .front ? "正面" : "反面",isOn: Binding(get: { store.selectedTaskIDs.contains(task.id) },set: { if $0 { store.selectedTaskIDs.insert(task.id) } else { store.selectedTaskIDs.remove(task.id) } })).font(.caption).toggleStyle(.checkbox).disabled(specimen.isExcluded)
                                        Button { store.currentSpecimenID = specimen.id; store.face = task.side } label: { sideStatus(task) }.buttonStyle(.plain)
                                    }.frame(maxWidth: .infinity)
                                }
                            }
                            if let reason = specimen.exclusionReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                        }.padding(10).frame(maxWidth: .infinity,alignment: .leading)
                            .background(store.currentSpecimenID == specimen.id ? Color.accentColor.opacity(0.16) : .clear,in: RoundedRectangle(cornerRadius: 9))
                            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(store.currentSpecimenID == specimen.id ? Color.accentColor.opacity(0.35) : .clear) }
                    }
                }.padding(10)
            }
            Text("选择标本查看正反面").font(.caption).foregroundStyle(.secondary).padding(18)
        }.background(panelBackground)
    }
    private func sideStatus(_ task: WorkflowSideTask) -> some View {
        VStack(alignment: .leading,spacing: 5) {
            WorkflowFileThumbnail(url: task.roleImages?.cutoutPNG ?? task.sources.first.url).frame(height: 44).clipShape(RoundedRectangle(cornerRadius: 5))
            Text("\(task.side.fileSuffix) · \(store.summaryRecord(task).state.title)").font(.system(size: 10)).foregroundStyle(store.summaryRecord(task).state == .failed ? .red : .secondary).lineLimit(1)
        }.frame(maxWidth: .infinity)
    }
    // MARK: - 阶段参数与人工编辑
    private var parameters: some View {
        VStack(alignment: .leading,spacing: 24) {
            HStack { Text("参数与设置").font(.headline); Spacer(); Text(store.face == .front ? "正面 D" : "反面 V").font(.caption).foregroundStyle(Color.accentColor) }
            Divider()
            switch store.stage {
            case .stack:
                inspectorSection("景深合成检查",icon: "square.3.layers.3d") { Text("核对原图、正反面与名称，检查重影及失焦。整批检查后继续。").font(.callout).foregroundStyle(.secondary) }
            case .matte:
                inspectorSection("蒙版检查",icon: "viewfinder") {
                    imageControls
                    Text("检查触角、细毛和尾突。精修后刷新保存版本。").font(.caption).foregroundStyle(.secondary)
                }
            case .geometry:
                if store.usesFinalization {
                    inspectorSection("保存版本预览",icon: "eye") { imageControls }
                    inspectorSection("人工检查",icon: "checkmark.circle") {
                        Text("本图完成后可检查确认，队列继续处理其他图片。需要修改时在 PS 中打开，自动队列会先安全暂停。")
                            .font(.callout).foregroundStyle(.secondary)
                        if let reason = store.currentTask?.geometrySolution?.reason { Text(reason).font(.caption).foregroundStyle(.orange) }
                        if store.currentTask?.geometrySolution?.isApplicable == false {
                            Text("自动裁切未应用。请在 Photoshop 调整并保存，明确采用当前姿态与裁切后再检查确认。").font(.caption).foregroundStyle(.orange)
                        }
                    }
                } else { geometryControls }
            case .hd:
                inspectorSection("检查此图",icon: "checkmark.circle") {
                    imageControls
                    Text("检查边缘、触角、角度和裁切。确认只作用于当前这一面，不会自动导出。").font(.caption).foregroundStyle(.secondary)
                    Button("确认此图") { store.confirmCurrent() }.disabled(!store.canFinalize)
                    Button("下一张待检查") { store.nextReview() }
                }
            case .png4k:
                inspectorSection("导出", icon: "square.and.arrow.up") {
                    Picker("范围",selection: $exportScope) { ForEach(["此图","所选","全部已确认"],id: \.self) { Text($0) } }
                    Text("符合导出条件：\(store.exportTaskIDs(scope: exportScope).count) 张，未确认图片不参与").font(.caption).foregroundStyle(.secondary)
                    Toggle("高清 JPEG（Stack）",isOn: $store.exportHDSelected)
                    Toggle("透明 PNG4K（Keying_Level）",isOn: $store.exportPNGSelected)
                    Picker("已有成品",selection: $store.exportPolicy) { ForEach(WorkflowExportPolicy.allCases,id: \.self) { Text($0.title).tag($0) } }
                    Text("跳过模式保留已有文件；旧版本标为待更新。覆盖仅替换本任务成品，外来同名文件会报冲突。").font(.caption).foregroundStyle(.secondary)
                    exportLocation(.hd); exportLocation(.png4k)
                    artifactResults(kinds: [.hd,.png4k])
                }
                Divider()
                inspectorSection("4K 构图",icon: "crop") { squareControls }
            case .derivatives:
                EmptyView()
            }
            Divider()
            inspectorSection("Photoshop 精修",icon: "slider.horizontal.3") { psdControls }

            Divider()
            inspectorSection("批次设置",icon: "gearshape") {
                if store.usesFinalization {
                    Text("逐面处理和确认；可分别选择 JPEG、PNG4K，按需单张或批量导出。").font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("抠图方式",value: store.effectiveMatteProvider.title)
                Text("照片工作流使用 Photoshop 选择主体，无需外部引擎。").font(.caption).foregroundStyle(.secondary)
            }.font(.callout)
        }.toggleStyle(.checkbox)
    }
    private var imageControls: some View {
        VStack(alignment: .leading,spacing: 12) {
            Text("显示图层").font(.caption).foregroundStyle(.secondary)
            Picker("图像",selection: $store.previewMode) { ForEach(["底图","抠图","蒙版"],id: \.self) { Text($0) } }.labelsHidden().pickerStyle(.segmented)
            Text("预览底色").font(.caption).foregroundStyle(.secondary)
            Picker("预览底色",selection: $store.previewBackground) { ForEach(["白","黑","棋盘","天蓝"],id: \.self) { Text($0) } }.labelsHidden().pickerStyle(.segmented)
        }
    }
    private var geometryControls: some View {
        VStack(alignment: .leading,spacing: 24) {
            inspectorSection("预览",icon: "eye") { imageControls }
            Divider()
            inspectorSection("裁切与留白",icon: "crop") {
                Picker("输出比例",selection: Binding(get: { store.currentRequest.ratio },set: { value in store.editRequest { $0.ratio = value } })) {
                    Text("自适应").tag(GeometryRatio.adaptive); Text("5:4").tag(GeometryRatio.fiveByFour); Text("11:8.5").tag(GeometryRatio.elevenByEightPointFive); Text("1:1").tag(GeometryRatio.square)
                }
                Text("目标留白 \(store.currentRequest.targetMargin*100,specifier: "%.1f")%")
                Slider(value: Binding(get: { store.currentRequest.targetMargin },set: { value in store.editRequest { $0.targetMargin = value } }),in: 0...0.25,step: 0.005)
            }
            Divider()
            inspectorSection("旋转与位置",icon: "rotate.right") {
                Text("增量角度 \(store.currentSolution?.angleDegrees ?? 0,specifier: "%.2f")°")
                Slider(value: Binding(get: { store.currentSolution?.angleDegrees ?? 0 },set: { value in store.editRequest { $0.angleStrategy = .manual(degrees: value) } }),in: -30...30,step: 0.05)
                HStack { Button(store.pickingTips ? "取消选点" : "两点扶正") { store.pickingTips.toggle(); store.tips = [] }; Button("恢复建议") { store.resetSuggestion() } }
                if store.pickingTips { Text("在完整源图上依次点击左右翅顶（\(store.tips.count)/2）").font(.caption).foregroundStyle(.orange) }
                Button("主体居中") { store.editRequest { $0.centerOverride = nil } }
                Text("拖动预览调整裁切位置；看图倍率只改变显示。").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            inspectorSection("输出尺寸",icon: "arrow.up.left.and.arrow.down.right") {
                if let s = store.currentSolution {
                    Text("输出 \(Int(s.outputSize.width)) × \(Int(s.outputSize.height)) px").monospacedDigit()
                    Text("实际留白 左 \(s.actualMargins.left*100,specifier: "%.1f")% / 上 \(s.actualMargins.top*100,specifier: "%.1f")%\n右 \(s.actualMargins.right*100,specifier: "%.1f")% / 下 \(s.actualMargins.bottom*100,specifier: "%.1f")%").font(.caption).monospacedDigit()
                    if let reason = s.reason { Text(reason).font(.caption).foregroundStyle(s.isApplicable ? .orange : .red) }
                    if !s.isApplicable { Text("请改比例、角度或两点扶正；蒙版不确定时打开 PSD 精修，再刷新。").font(.caption).foregroundStyle(.red) }
                }
                Text("下一步导出堆栈原图，可在该步骤选择输出目录。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var squareControls: some View {
        VStack(alignment: .leading,spacing: 12) {
            Text("4096 × 4096 · 透明 PNG").font(.headline)
            Text("独立安全框，继承已确认姿态；不会再次旋转。").font(.caption).foregroundStyle(.secondary)
            Text("预览底色").font(.caption).foregroundStyle(.secondary)
            Picker("预览底色",selection: $store.previewBackground) { ForEach(["白","黑","棋盘","天蓝"],id: \.self) { Text($0) } }.labelsHidden().pickerStyle(.segmented)
            Toggle("显示安全框",isOn: $store.showSafeFrame)
            HStack { Text("安全边距 px"); TextField("256",value: Binding(get: { store.currentLayout.safeMargin },set: { value in var l = store.currentLayout; l.safeMargin = min(512,max(0,value)); store.editLayout(l) }),format: .number).frame(width: 70) }
            Slider(value: Binding(get: { Double(store.currentLayout.safeMargin) },set: { value in var l = store.currentLayout; l.safeMargin = Int(value.rounded()); store.editLayout(l) }),in: 0...512)
            Button("恢复居中") { var l = store.currentLayout; l.center = CGPoint(x: 2048,y: 2048); store.editLayout(l) }
            Text("拖动预览移动主体。预览底色仅用于看图，输出保留透明。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var psdControls: some View {
        VStack(alignment: .leading,spacing: 8) {
            Button(store.face == .front ? "打开正面工作 PSD" : "打开反面工作 PSD") { store.openPSD() }.disabled(!store.canOpenPSD || (store.manualTaskID != nil && !store.usesFinalization))
            if store.usesFinalization {
                Text("高清导出读取 Stack，透明导出读取 Keying_Level。Keying_Origin 保留原始蒙版，默认隐藏。").font(.caption).foregroundStyle(.secondary)
                Button("刷新保存结果") { store.refreshSaved() }.disabled(store.busy || (store.manualTaskID != nil && store.manualTaskID != store.currentTask?.id))
                if store.manualTaskID != nil {
                    Button("采用当前姿态与裁切") { store.adoptCurrentPSD() }.disabled(store.busy)
                    Button("结束编辑") { store.finishEditing() }.disabled(store.busy)
                    Text("先在 PS 保存再刷新；结束编辑后点击继续处理恢复队列。").font(.caption).foregroundStyle(.secondary)
                }
                Button("重试此图失败步骤") { store.retryCurrent() }
                Menu("从此步骤重新处理") {
                    Button("重新景深合成／导入") { reprocessStage = .stack }
                    Button("重新 PS 抠图") { reprocessStage = .matte }.disabled(store.currentTask?.checkpoints?[.stack] == nil)
                    Button("重新旋转矫正") { reprocessStage = .geometry }.disabled(store.currentTask?.checkpoints?[.matte] == nil)
                }.disabled(store.busy || store.manualTaskID != nil)
                .confirmationDialog("从\(reprocessStage?.title ?? "所选步骤")重新处理？",isPresented: Binding(get: { reprocessStage != nil },set: { if !$0 { reprocessStage = nil } })) {
                    Button("重新处理") { if let step = reprocessStage { store.reprocessCurrent(from: step) }; reprocessStage = nil }
                    Button("取消",role: .cancel) { reprocessStage = nil }
                } message: { Text("旧 PSD 和已导出文件会保留。后续处理与确认失效，请重新检查后再导出。") }
            } else if store.manualTaskID != nil {
                Text("自动队列已保留给人工编辑。请先在 PS 保存，再分类刷新。").font(.caption).foregroundStyle(.orange)
                Picker("这次保存改变了",selection: $store.manualChange) { Text("仅蒙版").tag(WorkflowPSDChange.maskOnly); Text("角度／画布").tag(WorkflowPSDChange.geometry); Text("堆栈内容").tag(WorkflowPSDChange.stackContent) }
                Button("刷新保存结果") { store.refreshSaved() }
                Button("明确继续批处理") { store.resume() }
            }
        }
    }
    private func artifactResults(kinds: [WorkflowAssetKind]) -> some View {
        VStack(alignment: .leading,spacing: 8) {
            ForEach(kinds,id: \.self) { kind in
                let artifact = store.currentTask?.artifacts.last { $0.kind == kind }
                VStack(alignment: .leading) {
                    Text(assetTitle(kind)).font(.caption.bold())
                    if let note = store.currentTask?.exportNotes?[kind] { Text(note).font(.caption).foregroundStyle(.secondary) }
                    if let message = store.currentTask?[kind.stage].error { Text(message).font(.caption).foregroundStyle(.red) }
                    if let artifact { Text(artifact.state.title).font(.caption); Button(artifact.url.lastPathComponent) { NSWorkspace.shared.open(artifact.url) }.font(.caption).disabled(artifact.state != .completed) }
                    else { Text(kind == .hd && store.currentTask?.exportHD == false ? "本次未选择" : "尚无有效产物").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
    private func panelStatus(_ panel: WorkflowStage) -> String {
        guard let task = store.currentTask else { return "未开始" }
        if panel == .hd { return task[.geometry].state == .waitingReview ? "待检查" : task[.geometry].state == .completed ? "已确认" : "未开始" }
        if panel == .geometry && task[.geometry].state == .waitingReview { return "自动处理完成" }
        if panel == .png4k { return "JPEG \(task[.hd].state.title) / PNG \(task[.png4k].state.title)" }
        return task[panel].state.title
    }
    private var primaryTitle: String {
        if store.usesFinalization && (store.stage == .geometry || store.stage == .hd) { return "确认此图" }
        if store.usesFinalization && store.stage == .png4k { return "导出\(exportScope)" }
        return switch store.stage { case .stack: "整批检查完成，继续 AI"; case .matte: "整批检查完成，继续构图"; case .geometry: "确认所选标本两面构图"; case .hd: "导出堆栈原图"; case .png4k: "确认两面并导出 4K PNG"; case .derivatives: "仅重试失败资产" }
    }
    // 检查点条件由存储层汇总；界面仅据此禁用按钮，避免未验证预览进入确认。
    private var primaryDisabled: Bool {
        if store.usesFinalization && (store.stage == .geometry || store.stage == .hd) { return !store.canFinalize }
        if store.usesFinalization && store.stage == .png4k { return store.exportTaskIDs(scope: exportScope).isEmpty || (!store.exportHDSelected && !store.exportPNGSelected) }
        if store.usesFinalization { return true }
        if store.busy || store.manualTaskID != nil || store.batch?.isPaused == true { return true }
        if store.stage == .hd && store.exportDirectory(for: .hd) == nil { return true }
        if store.stage == .png4k && store.exportDirectory(for: .png4k) == nil { return true }
        if store.stage == .geometry || store.stage == .png4k { return !store.canConfirm }
        if store.stage == .stack || store.stage == .matte { return store.batch?.activeTasks.allSatisfy { $0[store.stage].state == .waitingReview } != true }
        return store.selectedSpecimens.isEmpty
    }
    private func assetTitle(_ kind: WorkflowAssetKind) -> String {
        switch kind { case .hd: "高清堆栈 JPG"; case .png4k: "4096 透明 PNG"; case .xianyu: "闲鱼 2000 · 浅灰 RGB 238 · 水印"; case .white1k: "1K 白底 · 1000 · 留白 10 px"; case .footage: "PNG 素材 · 原尺寸紧裁" }
    }
    // MARK: - 本地文件选择
    private func chooseFolder(_ action: (URL) -> Void) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK,let url = panel.url { action(url) }
    }
    private func chooseFile(types: [UTType],_ action: (URL) -> Void) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = types; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK,let url = panel.url { action(url) }
    }
}

// MARK: - 原图缩略预览
struct WorkflowFileThumbnail: View {
    var url: URL?
    @State private var image: CGImage?
    var body: some View {
        ZStack {
            Color.gray.opacity(0.08)
            if let image { Image(decorative: image,scale: 1).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }.task(id: url) {
            image = nil; guard let url else { return }
            let decoded = await Task.detached {
                guard let source = CGImageSourceCreateWithURL(url as CFURL,nil) else { return Optional<CGImage>.none }
                return CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways: true,kCGImageSourceThumbnailMaxPixelSize: 512,kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
            }.value
            // URL 改变会取消旧视图任务，忽略仍在后台解码的旧图返回值。
            guard !Task.isCancelled else { return }; image = decoded
        }
    }
}
