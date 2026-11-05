import SwiftUI
import UniformTypeIdentifiers
import ImageIO

extension WorkflowStage {
    var title: String {
        switch self { case .stack: "景深合成"; case .matte: "AI 抠图与回写"; case .geometry: "旋转裁切"; case .hd: "堆栈原图"; case .png4k: "4K PNG"; case .derivatives: "派生图片" }
    }
}
extension WorkflowStatus {
    var title: String {
        switch self { case .pending: "待处理"; case .running: "处理中"; case .waitingReview: "等待检查"; case .completed: "已完成"; case .failed: "失败"; case .excluded: "已排除" }
    }
}

struct PhotoWorkflowView: View {
    @ObservedObject var store: PhotoWorkflowStore
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("照片工作流").font(.title2.bold())
                    Text("收藏标本 · 每只六张 · 正面 F / 反面 U").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("打开批次清单…") { chooseFile(types: [.json]) { store.openBatch($0) } }.disabled(store.busy || store.manualTaskID != nil)
                if store.batch != nil {
                    Button("本批次 AI 引擎…") { chooseFolder { store.configureEngine($0) } }.disabled(store.busy || store.manualTaskID != nil)
                    Button("关闭批次／新建") { store.closeBatch() }.disabled(store.busy || store.manualTaskID != nil)
                    Button("查看输出") { if let url = store.batch?.outputDirectory { NSWorkspace.shared.open(url) } }
                }
            }.padding()
            if store.batch == nil { setup.disabled(store.busy) }
            else { execution }
            if let error = store.error { HStack { Image(systemName: "exclamationmark.triangle.fill"); Text(error).textSelection(.enabled); Spacer(); Button("关闭") { store.error = nil } }.foregroundStyle(.red).padding(10).background(.red.opacity(0.07)) }
        }
        .onChange(of: store.currentSpecimenID) { store.cancelMove(); store.prepareSelected() }
        .onChange(of: store.selectedSpecimens) { store.prepareSelected() }
        .onChange(of: store.face) { store.cancelMove(); store.refreshVisibleImage() }
        .onDisappear { store.cancelMove() }
    }
    private var setup: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading,spacing: 16) {
                    HStack { Button("选择照片文件夹…") { chooseFolder { store.scan($0) } }; Text(store.draft?.directory.path ?? "只读取直接子目录 JPG / JPEG").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    HStack { Button("选择输出目录…") { chooseFolder { store.outputDirectory = $0 } }; Text(store.outputDirectory?.path ?? "请选择新的空批次目录").font(.caption).foregroundStyle(.secondary) }
                    if let draft = store.draft {
                        Text("\(draft.photoCount) 张照片 · \(draft.groups.count) 只标本 · \(draft.remainder.count) 张未分组").font(.headline)
                        if !draft.otherFiles.isEmpty { Text("其他格式未参与：\(draft.otherFiles.map(\.lastPathComponent).joined(separator: "、"))").font(.caption).foregroundStyle(.secondary) }
                        if !draft.remainder.isEmpty {
                            Toggle("明确排除剩余 \(draft.remainder.count) 张试拍",isOn: Binding(get: { store.draft?.ignoreRemainder ?? false },set: { store.draft?.ignoreRemainder = $0 }))
                            Text(draft.remainder.map(\.lastPathComponent).joined(separator: "、")).font(.caption)
                        }
                        ForEach(Array(draft.groups.enumerated()),id: \.element.id) { index,group in
                            VStack(alignment: .leading,spacing: 8) {
                                HStack {
                                    Text("第 \(index+1) 组").bold()
                                    Spacer()
                                    Button("交换正反面") { store.draft?.groups[index].swapFaces() }
                                    Toggle("排除整组",isOn: Binding(get: { store.draft?.groups[index].excluded ?? false },set: { store.draft?.groups[index].excluded = $0 })).toggleStyle(.checkbox)
                                }
                                ForEach(0..<2) { side in
                                    HStack(alignment: .top) {
                                        Text(side == 0 ? "正面 F" : "反面 U").font(.caption).frame(width: 50)
                                        ForEach(0..<3) { offset in
                                            let slot = side*3+offset
                                            VStack {
                                                WorkflowFileThumbnail(url: group.files[slot]).frame(width: 105,height: 70)
                                                Text(group.files[slot]?.lastPathComponent ?? "缺图：需要替换").font(.caption2).lineLimit(2)
                                                HStack { Button("替换") { chooseFile(types: [.jpeg]) { store.draft?.groups[index].files[slot] = $0 } }; Button("移除") { store.draft?.groups[index].files[slot] = nil } }.font(.caption2)
                                            }.frame(maxWidth: .infinity)
                                        }
                                    }
                                }
                            }.padding(12).background(.quaternary.opacity(0.4),in: RoundedRectangle(cornerRadius: 8)).opacity(group.excluded ? 0.45 : 1)
                        }
                    }
                }.padding()
            }.frame(minWidth: 480)
            VStack(alignment: .leading,spacing: 14) {
                Text("名称清单").font(.headline)
                Text("每组六张对应一行。排除整组保留原行，其他名称不会顺移。").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $store.names).font(.body.monospaced()).frame(minHeight: 140).border(.quaternary)
                checkpoints
                Divider()
                Text("本批次 AI 引擎").font(.headline)
                HStack { TextField("butterfly-matte 目录",text: $store.enginePath); Button("选择…") { chooseFolder { store.enginePath = $0.path } } }
                Text("本批次明确选择；不会更改 AI 工作区偏好。").font(.caption).foregroundStyle(.secondary)
                derivativeChoices
                Spacer()
                Button(store.busy ? "固定分组与内容指纹…" : "冻结映射并开始处理") { store.start() }.buttonStyle(.borderedProminent).disabled(store.busy || store.draft == nil || store.outputDirectory == nil)
            }.padding().frame(minWidth: 300,idealWidth: 340,maxWidth: 420)
        }
    }
    private var checkpoints: some View {
        VStack(alignment: .leading) {
            Toggle("景深合成后检查",isOn: $store.checkAfterStack)
            Toggle("蒙版回写后检查",isOn: $store.checkAfterMatte)
            Text("第 3 步与第 5 步始终需要确认两面。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var derivativeChoices: some View {
        VStack(alignment: .leading,spacing: 8) {
            Text("派生资产").font(.headline)
            ForEach([WorkflowAssetKind.xianyu,.white1k,.footage],id: \.self) { kind in
                Toggle(assetTitle(kind),isOn: Binding(get: { store.selectedDerivatives.contains(kind) },set: { if $0 { store.selectedDerivatives.insert(kind) } else { store.selectedDerivatives.remove(kind) } }))
            }
            if store.selectedDerivatives.contains(.xianyu) {
                Button("选择闲鱼水印…") { chooseFile(types: [.image]) { store.watermarkURL = $0 } }
                Text(store.watermarkURL?.lastPathComponent ?? "未选水印：仅闲鱼资产会失败").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var execution: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(Array(WorkflowStage.allCases.enumerated()),id: \.element) { index,stage in
                    Button { store.stage = stage } label: { Text("\(index+1) \(stage.title)").font(.caption).padding(.vertical,6) }.buttonStyle(.bordered).tint(store.stage == stage ? .accentColor : .gray)
                }
                Spacer()
                if store.batch?.isPaused == true { Button("明确继续批处理") { store.resume() }.disabled(store.busy) }
                else { Button("暂停") { store.pause() } }
            }.padding(.horizontal).padding(.bottom,10)
            HSplitView {
                queue.frame(minWidth: 180,idealWidth: 215,maxWidth: 280)
                VStack(spacing: 10) {
                    HStack {
                        Picker("面",selection: $store.face) { Text("正面 F").tag(WorkflowSide.front); Text("反面 U").tag(WorkflowSide.back) }.pickerStyle(.segmented).frame(width: 180)
                        Spacer()
                        Text("看图倍率").font(.caption)
                        Slider(value: $store.zoom,in: 0.5...4).frame(width: 100)
                        Text("\(Int(store.zoom*100))%").monospacedDigit().font(.caption).frame(width: 42)
                        Button(store.currentDetailReady ? "返回快速预览" : "加载原图细节") { if store.currentDetailReady { store.useQuickPreview() } else { store.loadCurrentDetail() } }.disabled(store.manualTaskID != nil || store.currentTask?.roleImages == nil)
                    }
                    if let task = store.currentTask {
                        if store.currentDetailReady,let image = store.displayImage(for: task) { Text("当前角色原图细节已加载 · \(image.width) × \(image.height) px").font(.caption).foregroundStyle(.secondary) }
                        if let roles = task.roleImages {
                            WorkflowGeometryPreview(image: store.displayImage(for: task),source: roles,solution: store.currentPreviewSolution,square: store.stage == .png4k ? store.currentPreviewLayout : nil,zoom: store.zoom,background: store.previewBackground,showSafeFrame: store.showSafeFrame,interactionStarted: store.previewInteractionStarted[task.id],onSourcePoint: store.pickTip,onMoveChanged: store.updateMove,onMoveEnded: store.commitMove)
                                .overlay(alignment: .topLeading) {
                                    if store.loading.contains(task.id) { Text("校验当前完整源范围…").font(.caption).padding(6).background(.regularMaterial,in: RoundedRectangle(cornerRadius: 5)) }
                                }
                        } else {
                            WorkflowFileThumbnail(url: task.stackPNG?.pngURL ?? task.snapshot?.snapshotURL ?? task.sources.first.url).frame(maxWidth: .infinity,maxHeight: .infinity)
                        }
                        if store.stage == .stack || store.stage == .matte {
                            HStack { ForEach(task.sources.files,id: \.url) { source in VStack { WorkflowFileThumbnail(url: source.url).frame(height: 70); Text(source.url.lastPathComponent).font(.caption2) } } }.frame(height: 95)
                        }
                        if let message = task[store.stage].error { Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    } else { ContentUnavailableView("请选择标本",systemImage: "photo") }
                }.padding().frame(minWidth: 380)
                ScrollView { parameters.padding() }.frame(minWidth: 250,idealWidth: 280,maxWidth: 330)
            }
            Divider()
            HStack {
                if store.busy { ProgressView().controlSize(.small); Text("处理当前真实阶段，请勿在 PS 中同时编辑").font(.caption) }
                else { Text(store.batch?.isPaused == true ? "自动队列已暂停；保存、刷新后需明确继续" : "\(store.selectedSpecimens.count) 只已选 · 当前 \(store.stage.title)").font(.caption) }
                Spacer()
                Button("重试失败项") { store.retry() }.disabled(store.busy || store.selectedSpecimens.isEmpty)
                Button("暂不处理所选标本") { store.excludeSelected() }.disabled(store.busy || store.selectedSpecimens.isEmpty)
                Button(primaryTitle) { store.primary() }.buttonStyle(.borderedProminent).disabled(primaryDisabled)
            }.padding()
        }
    }
    private var queue: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 8) {
                Text("标本队列").font(.headline)
                ForEach(store.batch?.specimens ?? []) { specimen in
                    VStack(alignment: .leading,spacing: 5) {
                        HStack {
                            Toggle("",isOn: Binding(get: { store.selectedSpecimens.contains(specimen.id) },set: { if $0 { store.selectedSpecimens.insert(specimen.id) } else { store.selectedSpecimens.remove(specimen.id) } })).labelsHidden().disabled(specimen.isExcluded)
                            Button(specimen.baseName) { store.currentSpecimenID = specimen.id }.buttonStyle(.plain).fontWeight(store.currentSpecimenID == specimen.id ? .bold : .regular)
                        }
                        HStack { sideStatus(specimen.front); sideStatus(specimen.back) }
                        if let reason = specimen.exclusionReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    }.padding(8).frame(maxWidth: .infinity,alignment: .leading).background(store.currentSpecimenID == specimen.id ? Color.accentColor.opacity(0.1) : .clear,in: RoundedRectangle(cornerRadius: 6))
                }
            }.padding(10)
        }
    }
    private func sideStatus(_ task: WorkflowSideTask) -> some View {
        VStack(alignment: .leading) {
            WorkflowFileThumbnail(url: task.roleImages?.cutoutPNG ?? task.sources.first.url).frame(height: 52)
            Text("\(task.side.fileSuffix) · \(task[store.stage].state.title)").font(.caption2).foregroundStyle(task[store.stage].state == .failed ? .red : .secondary)
        }.frame(maxWidth: .infinity)
    }
    private var parameters: some View {
        VStack(alignment: .leading,spacing: 14) {
            Text(store.stage.title).font(.headline)
            if store.batch != nil { Text("本批次引擎：\(store.enginePath.isEmpty ? "尚未配置，请使用顶部选择按钮" : store.enginePath)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if let b = store.batch { Text("整批检查：合成\(b.checkAfterStack ? "开启" : "关闭") · 蒙版\(b.checkAfterMatte ? "开启" : "关闭")").font(.caption).foregroundStyle(.secondary) }
            switch store.stage {
            case .stack:
                Text("核对三张原图、正反面与名称，检查重影及失焦。所有有效标本到齐后才能继续。").font(.callout)
                psdControls
            case .matte:
                Text("检查真实保存蒙版的触角、细毛和尾突。人工精修后必须刷新保存版本。").font(.callout)
                imageControls; psdControls
            case .geometry:
                geometryControls; psdControls
            case .hd:
                Text("当前保存版本的未抠底图 · JPEG 0.82 · 不额外缩放").font(.callout)
                artifactResults(kinds: [.hd]); psdControls
            case .png4k:
                squareControls; derivativeChoices; psdControls
            case .derivatives:
                Text("只读取已确认的 4K PNG。成功资产保留，重试仅处理失败项。").font(.callout)
                artifactResults(kinds: [.png4k,.xianyu,.white1k,.footage])
            }
        }.disabled(store.busy)
    }
    private var imageControls: some View {
        VStack(alignment: .leading) {
            Picker("图像",selection: $store.previewMode) { ForEach(["底图","抠图","蒙版"],id: \.self) { Text($0) } }.pickerStyle(.segmented)
            Picker("预览底色",selection: $store.previewBackground) { ForEach(["白","黑","棋盘"],id: \.self) { Text($0) } }.pickerStyle(.segmented)
        }
    }
    private var geometryControls: some View {
        VStack(alignment: .leading,spacing: 12) {
            imageControls
            Picker("输出比例",selection: Binding(get: { store.currentRequest.ratio },set: { value in store.editRequest { $0.ratio = value } })) {
                Text("自适应").tag(GeometryRatio.adaptive); Text("5:4").tag(GeometryRatio.fiveByFour); Text("11:8.5").tag(GeometryRatio.elevenByEightPointFive); Text("1:1").tag(GeometryRatio.square)
            }
            Text("目标留白 \(store.currentRequest.targetMargin*100,specifier: "%.1f")%")
            Slider(value: Binding(get: { store.currentRequest.targetMargin },set: { value in store.editRequest { $0.targetMargin = value } }),in: 0...0.25,step: 0.005)
            Text("增量角度 \(store.currentSolution?.angleDegrees ?? 0,specifier: "%.2f")°")
            Slider(value: Binding(get: { store.currentSolution?.angleDegrees ?? 0 },set: { value in store.editRequest { $0.angleStrategy = .manual(degrees: value) } }),in: -30...30,step: 0.05)
            HStack { Button(store.pickingTips ? "取消选点" : "两点扶正") { store.pickingTips.toggle(); store.tips = [] }; Button("恢复建议") { store.resetSuggestion() } }
            if store.pickingTips { Text("在完整源图上依次点击左右翅顶（\(store.tips.count)/2）").font(.caption).foregroundStyle(.orange) }
            Button("主体居中") { store.editRequest { $0.centerOverride = nil } }
            Text("拖动预览调整裁切位置；看图倍率只改变显示。").font(.caption).foregroundStyle(.secondary)
            if let s = store.currentSolution {
                Text("输出 \(Int(s.outputSize.width)) × \(Int(s.outputSize.height)) px").monospacedDigit()
                Text("实际留白 左 \(s.actualMargins.left*100,specifier: "%.1f")% / 上 \(s.actualMargins.top*100,specifier: "%.1f")%\n右 \(s.actualMargins.right*100,specifier: "%.1f")% / 下 \(s.actualMargins.bottom*100,specifier: "%.1f")%").font(.caption).monospacedDigit()
                if let reason = s.reason { Text(reason).font(.caption).foregroundStyle(s.isApplicable ? .orange : .red) }
                if !s.isApplicable { Text("请改比例、角度或两点扶正；蒙版不确定时打开 PSD 精修，再刷新。").font(.caption).foregroundStyle(.red) }
            }
            Toggle("导出堆栈原图（高清 JPG）",isOn: $store.exportHD)
        }
    }
    private var squareControls: some View {
        VStack(alignment: .leading,spacing: 12) {
            Text("4096 × 4096 · 透明 PNG").font(.headline)
            Text("独立安全框，继承已确认姿态；不会再次旋转。").font(.caption).foregroundStyle(.secondary)
            Picker("预览底色",selection: $store.previewBackground) { ForEach(["白","黑","棋盘"],id: \.self) { Text($0) } }.pickerStyle(.segmented)
            Toggle("显示安全框",isOn: $store.showSafeFrame)
            HStack { Text("安全边距 px"); TextField("256",value: Binding(get: { store.currentLayout.safeMargin },set: { value in var l = store.currentLayout; l.safeMargin = min(512,max(0,value)); store.editLayout(l) }),format: .number).frame(width: 70) }
            Slider(value: Binding(get: { Double(store.currentLayout.safeMargin) },set: { value in var l = store.currentLayout; l.safeMargin = Int(value); store.editLayout(l) }),in: 0...512,step: 1)
            Button("恢复居中") { var l = store.currentLayout; l.center = CGPoint(x: 2048,y: 2048); store.editLayout(l) }
            Text("拖动预览移动主体。白／黑／棋盘仅为看图背景，输出保留透明。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var psdControls: some View {
        VStack(alignment: .leading,spacing: 8) {
            Divider()
            Button(store.face == .front ? "打开正面工作 PSD" : "打开反面工作 PSD") { store.openPSD() }.disabled(store.currentTask?.snapshot == nil || store.manualTaskID != nil)
            if store.manualTaskID != nil {
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
                let artifact = store.currentTask?.artifacts.first { $0.kind == kind }
                VStack(alignment: .leading) {
                    Text(assetTitle(kind)).font(.caption.bold())
                    if let artifact { Text(artifact.state.title).font(.caption); Button(artifact.url.lastPathComponent) { NSWorkspace.shared.open(artifact.url) }.font(.caption).disabled(artifact.state != .completed) }
                    else { Text(kind == .hd && store.currentTask?.exportHD == false ? "本次未选择" : kind.stage == .derivatives && !store.selectedDerivatives.contains(kind) ? "本次未选择" : "尚无有效产物").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
    private var primaryTitle: String {
        switch store.stage { case .stack: "整批检查完成，继续 AI"; case .matte: "整批检查完成，继续构图"; case .geometry: "确认所选标本两面构图"; case .hd: "重试堆栈原图"; case .png4k: "确认两面并导出 4K PNG"; case .derivatives: "仅重试失败资产" }
    }
    private var primaryDisabled: Bool {
        if store.busy || store.manualTaskID != nil || store.batch?.isPaused == true { return true }
        if store.stage == .geometry || store.stage == .png4k { return !store.canConfirm }
        if store.stage == .stack || store.stage == .matte { return store.batch?.activeTasks.allSatisfy { $0[store.stage].state == .waitingReview } != true }
        return store.selectedSpecimens.isEmpty
    }
    private func assetTitle(_ kind: WorkflowAssetKind) -> String {
        switch kind { case .hd: "高清堆栈 JPG"; case .png4k: "4096 透明 PNG"; case .xianyu: "闲鱼 2000 · 浅灰 RGB 238 · 水印"; case .white1k: "1K 白底 · 1000 · 留白 10 px"; case .footage: "PNG 素材 · 原尺寸紧裁" }
    }
    private func chooseFolder(_ action: (URL) -> Void) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK,let url = panel.url { action(url) }
    }
    private func chooseFile(types: [UTType],_ action: (URL) -> Void) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = types; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK,let url = panel.url { action(url) }
    }
}

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
            guard !Task.isCancelled else { return }; image = decoded
        }
    }
}
