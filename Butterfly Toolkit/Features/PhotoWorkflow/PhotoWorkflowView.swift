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
    @State private var selectedDraftID: UUID?
    @State private var singleFace = false
    @Environment(\.colorScheme) private var colorScheme
    private var panelBackground: Color { colorScheme == .dark ? Color(white: 0.16) : Color(nsColor: .windowBackgroundColor) }
    private var canvasBackground: Color { colorScheme == .dark ? Color(white: 0.13) : Color(nsColor: .textBackgroundColor) }
    private let queueWidth: CGFloat = 210
    private let inspectorWidth: CGFloat = 300
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
                    Button("关闭批次／新建") { store.closeBatch() }.disabled(store.busy || store.manualTaskID != nil)
                    Button("查看输出") { if let url = store.batch?.outputDirectory { NSWorkspace.shared.open(url) } }
                }
            }.padding(.horizontal,24).padding(.vertical,20)
            Divider()
            if store.batch == nil { setup.disabled(store.busy) }
            else { execution }
            if let error = store.error { HStack { Image(systemName: "exclamationmark.triangle.fill"); Text(error).textSelection(.enabled); Spacer(); Button("关闭") { store.error = nil } }.foregroundStyle(.red).padding(10).background(.red.opacity(0.07)) }
        }
        .background(panelBackground)
        .frame(minWidth: 980,minHeight: 640)
        .onChange(of: store.currentSpecimenID) { store.cancelMove(); store.prepareSelected() }
        .onChange(of: store.selectedSpecimens) { store.prepareSelected() }
        .onChange(of: store.face) { store.cancelMove(); store.refreshVisibleImage() }
        .onDisappear { store.cancelMove() }
    }
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
                Text(store.draft.map { "\($0.groups.filter { !$0.excluded }.count) 只待处理 · 正反面各三张" } ?? "选择照片文件夹，开始建立收藏批次")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(store.busy ? "正在准备批次…" : "开始处理") { store.start() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(store.busy || store.draft == nil || store.outputDirectory == nil)
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
                            Text("共 \(store.draft?.photoCount ?? 0) 张照片 · 核对分组与正反面").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(group.excluded ? "已排除" : "待处理").font(.caption.weight(.medium)).padding(.horizontal,10).padding(.vertical,6)
                            .background(Color.accentColor.opacity(0.12),in: Capsule())
                    }
                    ForEach(0..<2) { side in
                        VStack(alignment: .leading,spacing: 12) {
                            HStack { Text(side == 0 ? "正面" : "反面").font(.headline); Spacer(); Text(side == 0 ? "F · 3 张原图" : "U · 3 张原图").font(.caption).foregroundStyle(.secondary) }
                            HStack(alignment: .top,spacing: 12) {
                                ForEach(0..<3) { offset in
                                    let slot = side*3+offset
                                    VStack(alignment: .leading,spacing: 8) {
                                        WorkflowFileThumbnail(url: group.files[slot]).aspectRatio(1.2,contentMode: .fit)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                        Text(group.files[slot]?.lastPathComponent ?? "缺图：需要替换").font(.caption).lineLimit(1).truncationMode(.middle)
                                        HStack(spacing: 10) {
                                            Button("替换") { chooseFile(types: [.jpeg]) { store.draft?.groups[index].files[slot] = $0 } }
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
                        Text("导入第一批蝴蝶照片").font(.title3.weight(.semibold))
                        Text("每只蝴蝶六张照片，正反面各三张。\n导入后在左侧选择标本，在这里核对原图。")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("选择照片文件夹…",systemImage: "folder") { chooseFolder { store.scan($0) } }.controlSize(.large)
                    }.frame(maxWidth: .infinity).padding(.vertical,100)
                }
                if let draft = store.draft {
                    if !draft.remainder.isEmpty {
                        VStack(alignment: .leading,spacing: 8) {
                            Toggle("明确排除剩余 \(draft.remainder.count) 张试拍",isOn: Binding(get: { store.draft?.ignoreRemainder ?? false },set: { store.draft?.ignoreRemainder = $0 }))
                            Text(draft.remainder.map(\.lastPathComponent).joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !draft.otherFiles.isEmpty { Text("其他格式未参与：\(draft.otherFiles.map(\.lastPathComponent).joined(separator: "、"))").font(.caption).foregroundStyle(.secondary) }
                }
            }.padding(24).frame(maxWidth: 1040).frame(maxWidth: .infinity,alignment: .topLeading)
        }.background(canvasBackground)
    }
    private var setupInspector: some View {
        VStack(alignment: .leading,spacing: 24) {
            inspectorSection("批次目录",icon: "folder") {
                directoryControl("原始照片",url: store.draft?.directory,placeholder: "选择 JPG / JPEG 文件夹") { chooseFolder { store.scan($0) } }
                directoryControl("输出位置",url: store.outputDirectory,placeholder: "选择新的空文件夹") { chooseFolder { store.outputDirectory = $0 } }
            }
            Divider()
            inspectorSection("名称清单",icon: "text.alignleft") {
                TextEditor(text: $store.names).font(.body).scrollContentBackground(.hidden)
                    .padding(8).frame(height: 112)
                    .background(Color(nsColor: .textBackgroundColor),in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary) }
                Text("每只一行，与左侧顺序对应；排除整组时保留原行。").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            inspectorSection("检查点",icon: "checkmark.circle") { checkpoints }
            Divider()
            derivativeChoices
            Divider()
            inspectorSection("AI 引擎",icon: "sparkles") {
                HStack(spacing: 8) {
                    TextField("butterfly-matte 目录",text: $store.enginePath).textFieldStyle(.roundedBorder)
                    Button("选择") { chooseFolder { store.enginePath = $0.path } }
                }
                Text("仅用于本批次").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity,alignment: .leading).toggleStyle(.checkbox)
    }
    private func directoryControl(_ title: String,url: URL?,placeholder: String,action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading,spacing: 6) {
            HStack { Text(title).font(.callout); Spacer(); Button(url == nil ? "选择…" : "更改…",action: action).font(.caption) }
            Text(url?.lastPathComponent ?? placeholder).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .help(url?.path ?? placeholder)
        }
    }
    private func inspectorSection<Content: View>(_ title: String,icon: String,@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading,spacing: 14) {
            Label(title,systemImage: icon).font(.subheadline.weight(.semibold))
            content()
        }.frame(maxWidth: .infinity,alignment: .leading)
    }
    private var checkpoints: some View {
        VStack(alignment: .leading,spacing: 12) {
            Toggle("景深合成后检查",isOn: $store.checkAfterStack)
            Toggle("蒙版回写后检查",isOn: $store.checkAfterMatte)
            Text("构图与 4K 导出始终需要确认两面。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var derivativeChoices: some View {
        inspectorSection("输出资产",icon: "square.and.arrow.down") {
            ForEach([WorkflowAssetKind.xianyu,.white1k,.footage],id: \.self) { kind in
                Toggle(isOn: Binding(get: { store.selectedDerivatives.contains(kind) },set: { if $0 { store.selectedDerivatives.insert(kind) } else { store.selectedDerivatives.remove(kind) } })) {
                    VStack(alignment: .leading,spacing: 4) {
                        Text(kind == .xianyu ? "闲鱼产品图" : kind == .white1k ? "1K 白底" : "PNG 素材")
                        Text(kind == .xianyu ? "2000 × 2000 · 浅灰底 · 水印" : kind == .white1k ? "1000 × 1000 · 留白 10 px" : "紧裁透明边缘 · 原尺寸")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.checkbox)
            }
            if store.selectedDerivatives.contains(.xianyu) {
                Button("选择闲鱼水印…") { chooseFile(types: [.image]) { store.watermarkURL = $0 } }
                Text(store.watermarkURL?.lastPathComponent ?? "未选水印：仅闲鱼资产会失败").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
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
                if store.busy { ProgressView().controlSize(.small); Text("正在处理，请勿在 PS 中同时编辑").font(.caption) }
                else { Text(store.batch?.isPaused == true ? "已暂停 · 保存并刷新后继续" : "已选 \(store.selectedSpecimens.count) 只 · 正反面").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Menu("更多操作") {
                    Button("重试失败项") { store.retry() }.disabled(store.busy || store.selectedSpecimens.isEmpty)
                    Button("暂不处理所选标本") { store.excludeSelected() }.disabled(store.busy || store.selectedSpecimens.isEmpty)
                }.fixedSize()
                if store.batch?.isPaused == true { Button("明确继续批处理") { store.resume() }.disabled(store.busy) }
                else { Button("暂停") { store.pause() } }
                Button(primaryTitle) { store.primary() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(primaryDisabled)
            }.padding(.horizontal,24).padding(.vertical,14)
        }
    }
    private var executionPreview: some View {
        VStack(alignment: .leading,spacing: 20) {
            HStack {
                VStack(alignment: .leading,spacing: 6) {
                    Text(store.currentSpecimen?.baseName ?? "请选择标本").font(.title2.bold())
                    Text("收藏批次 · \(store.batch?.specimens.count ?? 0) 只标本").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let task = store.currentTask {
                    Text(task[store.stage].state.title).font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
                        .padding(.horizontal,10).padding(.vertical,6).background(Color.accentColor.opacity(0.12),in: Capsule())
                }
            }
            ScrollView(.horizontal,showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(WorkflowStage.allCases.enumerated()),id: \.element) { index,stage in
                        Button { store.stage = stage } label: {
                            HStack(spacing: 5) {
                                Text("\(index+1)").font(.caption2.bold()).frame(width: 18,height: 18).background(store.stage == stage ? Color.accentColor : Color.secondary.opacity(0.14),in: Circle()).foregroundStyle(store.stage == stage ? .white : .secondary)
                                Text(stage.title).font(.caption).fixedSize()
                            }.padding(.horizontal,8).padding(.vertical,8)
                                .background(store.stage == stage ? Color.accentColor.opacity(0.1) : .clear,in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                    }
                }
            }
            Divider()
            HStack {
                Text(store.stage == .png4k ? "PNG 4K" : store.stage.title).font(.headline)
                Spacer()
                Button { singleFace.toggle() } label: { Label(singleFace ? "正反面对照" : "单面放大",systemImage: singleFace ? "rectangle.split.2x1" : "arrow.up.left.and.arrow.down.right") }.buttonStyle(.borderless).font(.caption)
            }
            if let specimen = store.currentSpecimen {
                HStack(alignment: .top,spacing: 16) {
                    if !singleFace || store.face == .front { facePreview(specimen.front) }
                    if !singleFace || store.face == .back { facePreview(specimen.back) }
                }.frame(maxWidth: .infinity,maxHeight: 560)
                HStack(spacing: 10) {
                    Picker("当前编辑面",selection: $store.face) { Text("正面 F").tag(WorkflowSide.front); Text("反面 U").tag(WorkflowSide.back) }
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
                        .font(.caption).buttonStyle(.borderless).disabled(store.manualTaskID != nil || store.currentTask?.roleImages == nil)
                }
                Spacer(minLength: 0)
            } else { ContentUnavailableView("请选择标本",systemImage: "photo").frame(maxHeight: .infinity) }
        }.padding(24).background(canvasBackground)
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
                        zoom: store.zoom,background: store.previewBackground,showSafeFrame: store.showSafeFrame,
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
            if let message = task[store.stage].error { Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.frame(maxWidth: .infinity)
    }
    private var queue: some View {
        VStack(alignment: .leading,spacing: 0) {
            HStack { Text("本批标本").font(.headline); Spacer(); Text("\(store.batch?.specimens.count ?? 0)").foregroundStyle(.secondary) }.padding(18)
            Divider()
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(store.batch?.specimens ?? []) { specimen in
                        HStack(alignment: .top,spacing: 8) {
                            Toggle("选择 \(specimen.baseName)",isOn: Binding(get: { store.selectedSpecimens.contains(specimen.id) },set: { if $0 { store.selectedSpecimens.insert(specimen.id) } else { store.selectedSpecimens.remove(specimen.id) } }))
                                .labelsHidden().toggleStyle(.checkbox).disabled(specimen.isExcluded).padding(.top,4)
                            Button { store.currentSpecimenID = specimen.id } label: {
                                VStack(alignment: .leading,spacing: 8) {
                                    Text(specimen.baseName).font(.body.weight(.medium)).lineLimit(1)
                                    HStack(spacing: 6) { sideStatus(specimen.front); sideStatus(specimen.back) }
                                    if let reason = specimen.exclusionReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity,alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
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
            Text("\(task.side.fileSuffix) · \(task[store.stage].state.title)").font(.system(size: 10)).foregroundStyle(task[store.stage].state == .failed ? .red : .secondary).lineLimit(1)
        }.frame(maxWidth: .infinity)
    }
    private var parameters: some View {
        VStack(alignment: .leading,spacing: 24) {
            HStack { Text("参数与设置").font(.headline); Spacer(); Text(store.face == .front ? "正面 F" : "反面 U").font(.caption).foregroundStyle(Color.accentColor) }
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
                geometryControls
            case .hd:
                inspectorSection("高清堆栈",icon: "photo") {
                    Text("使用当前保存的底图，保留原尺寸。").font(.caption).foregroundStyle(.secondary)
                    artifactResults(kinds: [.hd])
                }
            case .png4k:
                inspectorSection("4K 构图",icon: "crop") { squareControls }
                Divider()
                derivativeChoices
            case .derivatives:
                inspectorSection("导出结果",icon: "square.and.arrow.down") {
                    Text("基于已确认的 4K；仅重试失败资产。").font(.caption).foregroundStyle(.secondary)
                    artifactResults(kinds: [.png4k,.xianyu,.white1k,.footage])
                }
            }
            if store.stage != .derivatives {
                Divider()
                inspectorSection("Photoshop 精修",icon: "slider.horizontal.3") { psdControls }
            }
            Divider()
            inspectorSection("批次设置",icon: "gearshape") {
                if let b = store.batch {
                    LabeledContent("合成后检查",value: b.checkAfterStack ? "开启" : "关闭")
                    LabeledContent("蒙版后检查",value: b.checkAfterMatte ? "开启" : "关闭")
                }
                directoryControl("AI 引擎",url: store.enginePath.isEmpty ? nil : URL(fileURLWithPath: store.enginePath),placeholder: "尚未配置") { chooseFolder { store.configureEngine($0) } }
                    .disabled(store.manualTaskID != nil)
            }.font(.callout)
        }.toggleStyle(.checkbox).disabled(store.busy)
    }
    private var imageControls: some View {
        VStack(alignment: .leading,spacing: 12) {
            Text("显示图层").font(.caption).foregroundStyle(.secondary)
            Picker("图像",selection: $store.previewMode) { ForEach(["底图","抠图","蒙版"],id: \.self) { Text($0) } }.labelsHidden().pickerStyle(.segmented)
            Text("预览底色").font(.caption).foregroundStyle(.secondary)
            Picker("预览底色",selection: $store.previewBackground) { ForEach(["白","黑","棋盘"],id: \.self) { Text($0) } }.labelsHidden().pickerStyle(.segmented)
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
                Toggle("导出高清堆栈 JPG",isOn: $store.exportHD)
            }
        }
    }
    private var squareControls: some View {
        VStack(alignment: .leading,spacing: 12) {
            Text("4096 × 4096 · 透明 PNG").font(.headline)
            Text("独立安全框，继承已确认姿态；不会再次旋转。").font(.caption).foregroundStyle(.secondary)
            Text("预览底色").font(.caption).foregroundStyle(.secondary)
            Picker("预览底色",selection: $store.previewBackground) { ForEach(["白","黑","棋盘"],id: \.self) { Text($0) } }.labelsHidden().pickerStyle(.segmented)
            Toggle("显示安全框",isOn: $store.showSafeFrame)
            HStack { Text("安全边距 px"); TextField("256",value: Binding(get: { store.currentLayout.safeMargin },set: { value in var l = store.currentLayout; l.safeMargin = min(512,max(0,value)); store.editLayout(l) }),format: .number).frame(width: 70) }
            Slider(value: Binding(get: { Double(store.currentLayout.safeMargin) },set: { value in var l = store.currentLayout; l.safeMargin = Int(value); store.editLayout(l) }),in: 0...512,step: 1)
            Button("恢复居中") { var l = store.currentLayout; l.center = CGPoint(x: 2048,y: 2048); store.editLayout(l) }
            Text("拖动预览移动主体。白／黑／棋盘仅为看图背景，输出保留透明。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var psdControls: some View {
        VStack(alignment: .leading,spacing: 8) {
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
