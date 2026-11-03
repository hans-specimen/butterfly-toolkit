import SwiftUI

struct AISamplesView: View {
    @ObservedObject var store: AIWorkspaceStore
    var navigate: (ToolPage) -> Void
    @State private var viewport = AIViewport()
    @FocusState private var materialListFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("训练素材").font(.title2).fontWeight(.semibold)
                    Text("\(store.pairedSamples.count) 份素材 · 检查通过并确认答案后可用于训练").foregroundStyle(.secondary)
                }
                Spacer()
                Button("刷新素材") { store.load() }.disabled(store.busy)
            }.padding(20)
            AITrainingSourcesView(store: store, navigate: navigate).padding(.horizontal, 20).padding(.bottom, 12)
            if !store.importSummary.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(store.importSummary.enumerated()), id: \.offset) { _, message in
                            Text(message).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                    }.font(.caption).padding(10)
                }.frame(maxHeight: 95).background(.quaternary.opacity(0.4)).padding(.horizontal, 20)
            }
            HStack(spacing: 12) {
                Text("已选 \(store.materialSelection.count) / \(store.pairedSamples.count) 份").monospacedDigit()
                Text("⇧ 连选 · ⌘ 点选 · ⌘A 全选").foregroundStyle(.secondary)
                Spacer()
                AIConfirmAnswersButton(store: store)
                Button("全选") { store.setMaterialSelection(Set(store.pairedSamples.map(\.id))) }
                    .disabled(store.pairedSamples.isEmpty)
                Button("取消全选") { store.setMaterialSelection([]) }.disabled(store.materialSelection.isEmpty)
            }.font(.callout).padding(.horizontal, 20).padding(.bottom, 10)
            Table(store.pairedSamples, selection: Binding(get: { store.materialSelection }, set: { store.setMaterialSelection($0) })) {
                TableColumn("素材") { sample in
                    HStack(spacing: 10) {
                        AIThumbnail(path: sample.reference ?? sample.original).frame(width: 45, height: 36)
                        Text(sample.name).lineLimit(2).help(sample.name)
                    }.frame(height: 44)
                }.width(min: 210, ideal: 330)
                TableColumn("对齐") { sample in
                    Label(sample.alignmentTitle, systemImage: sample.alignment == "aligned" ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(sample.alignment == "aligned" ? Color.secondary : .orange)
                }.width(85)
                TableColumn("答案") { sample in
                    Text(sample.answerConfirmed != true ? "待人工确认" : "已确认").foregroundStyle(sample.answerConfirmed != true ? Color.orange : .secondary)
                }.width(90)
                TableColumn("来源") { sample in Text(sample.materialKind ?? "已有素材").font(.caption) }.width(130)
                TableColumn("尺寸") { sample in Text(sample.dimensions).monospacedDigit() }.width(110)
            // Match the estimate for unrealized rows to the 44 pt content plus native row insets.
            // Otherwise macOS estimates 24 pt, then repeatedly adjusts the scroll anchor to 52 pt.
            }.environment(\.defaultMinListRowHeight, 52)
                .frame(minHeight: 200, maxHeight: 300)
                .focused($materialListFocused)
                .simultaneousGesture(TapGesture().onEnded { materialListFocused = true })
            Divider()
            if let sample = store.selected, sample.reference != nil {
                HStack {
                    Label("图层对齐检查", systemImage: "square.on.square").font(.headline)
                    if store.materialSelection.count > 1 {
                        Text("当前预览 1 份").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(sample.alignment == "aligned" ? "对齐记录通过" : "请核对原图与答案位置").foregroundStyle(sample.alignment == "aligned" ? Color.secondary : .orange)
                    Button("整图") { viewport.fit(sample.pixelSize) }
                    Button("细节") { focus(sample) }

                }.padding(16)
                Text(sample.alignmentNote).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16)
                HStack(spacing: 1) {
                    AIImagePanel(path: sample.original, title: "原始底图", imageSize: sample.pixelSize, background: .black, viewport: $viewport)
                    AIImagePanel(path: sample.reference, title: "人工答案", imageSize: sample.pixelSize, background: .black, viewport: $viewport)
                }.background(Color(nsColor: .separatorColor))
                .onChange(of: sample.id, initial: true) { _, _ in focus(sample) }
            } else {
                ContentUnavailableView(store.pairedSamples.isEmpty ? "还没有训练素材" : "选择一份素材检查对齐", systemImage: "square.on.square",
                    description: Text("将 PSD 放入 butterfly-ai-footage/待处理PSD，再点击“导入三层 PSD”。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack { Text("\(store.alignedCount) 份对齐正常 · \(store.pairedSamples.count - store.alignedCount) 份需处理或核对"); Spacer() }
                .font(.caption).foregroundStyle(.secondary).padding(14)
        }
        .onAppear { store.selectPairedSampleIfAvailable() }
        .onChange(of: store.pairedSamples.map(\.id)) { _, _ in
            store.setMaterialSelection(store.materialSelection)
        }
    }
    private func focus(_ sample: AISample) {
        if let roi = sample.rois.dropFirst().first ?? sample.rois.first { viewport.center = roi.center; viewport.zoom = 8 }
        else { viewport.fit(sample.pixelSize) }
    }
}

struct AIConfirmAnswersButton: View {
    @ObservedObject var store: AIWorkspaceStore
    var body: some View {
        Button(store.materialSelection.count > 1 ? "确认所选答案（\(store.materialSelection.count) 份）" : "确认答案") {
            Task { await store.confirmSelectedAnswers() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.busy || store.pendingAnswerCount == 0)
    }
}

struct AITrainingView: View {
    @ObservedObject var store: AIWorkspaceStore
    @State private var chooseSamples = false
    @State private var advanced = false
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("准备训练").font(.largeTitle).fontWeight(.semibold)
                        Text("选择已确认的素材，设置本次训练任务。").font(.title3).foregroundStyle(.secondary)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 16) {
                            Label("小样本学习验证", systemImage: "scope").font(.headline)
                            Text("使用少量已确认的素材验证模型能否学会细节，再扩大训练范围。")
                                .foregroundStyle(.secondary)
                            Divider()
                            HStack { Text("任务名称"); Spacer(); TextField("训练任务名称", text: $store.taskName).disabled(store.busy).textFieldStyle(.roundedBorder).frame(maxWidth: 280) }
                        }.padding(10)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        Text("训练素材").font(.headline)
                        HStack {
                            Label("\(store.trainingCandidates.count) 份符合训练选择条件 · 已选 \(store.trainingSelection.count) 份", systemImage: "photo.stack")
                            Spacer(); Button("选择样本…") { chooseSamples = true }.disabled(store.busy)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 12)], alignment: .leading, spacing: 12) {
                            ForEach(store.samples.filter { store.trainingSelection.contains($0.id) }) { sample in
                                AIThumbnail(path: sample.reference).frame(width: 80, height: 64).help(sample.name)
                            }
                        }
                        Text("已对齐且答案已确认的素材，即可选入训练。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("初始模型").font(.headline)
                        Picker("初始模型", selection: .constant("base")) {
                            Text(store.catalog?.model.name ?? "未连接模型").tag("base")
                        }.labelsHidden()
                        Text("从基础模型开始微调，新版本单独保存。").font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("高级设置", isExpanded: $advanced) {
                        VStack(alignment: .leading, spacing: 10) {
                            Stepper("训练轮数：\(store.trainingEpochs)", value: $store.trainingEpochs, in: 1...100)
                            Picker("训练尺寸", selection: $store.trainingInputSize) {
                                Text("512 × 512 · 先验证流程").tag(512)
                                Text("1024 × 1024 · 更多细节，更慢").tag(1024)
                            }
                            AIInfoRow("学习率", "0.00001")
                            AIInfoRow("训练设备", "CPU · FP32")
                            Text("每轮学习全部所选素材，保留连续透明度。原始高清素材不变；当前微调抠图解码部分，基础模型保持独立。")
                                .font(.callout).foregroundStyle(.secondary)
                        }.padding(.top, 12)
                    }.disabled(store.busy)
                    Text("当前训练使用 CPU：本模型的部分反向运算尚不支持 Mac GPU。抠图仍可使用 GPU。训练完成后请比较细节，训练误差下降不代表新图效果一定更好。")
                        .font(.callout).foregroundStyle(.secondary)
                    if let run = store.currentTraining {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack { Text(run.name).font(.headline); Spacer(); Text(run.statusTitle) }
                                ProgressView(value: run.progress)
                                Text("\(run.step) / \(run.totalSteps) 步 · 第 \(run.epoch) / \(run.epochs) 轮")
                                if let loss = run.loss { Text("训练误差：\(loss, specifier: "%.6f")").monospacedDigit() }
                                Text(run.message).font(.callout).foregroundStyle(.secondary)
                                Button("查看任务记录") { store.reveal(run.outputDirectory) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        }
                    }
                }.frame(maxWidth: 720).padding(36).frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                Label(store.isTraining ? "正在训练 · 请保持 Toolkit 打开" : (store.currentTraining?.statusTitle ?? "尚无训练任务"), systemImage: "clock").foregroundStyle(.secondary)
                Spacer()
                if store.isTraining {
                    Button("停止训练", action: store.stopTraining)
                } else {
                    Button("开始训练", action: store.startTraining).buttonStyle(.borderedProminent).disabled(!store.canStartTraining)
                }
            }.padding(20)
        }
        .sheet(isPresented: $chooseSamples) {
            VStack(alignment: .leading, spacing: 16) {
                Text("选择训练素材").font(.title2).fontWeight(.semibold)
                Text("选择本次训练使用的素材；只需对齐通过并确认答案。")
                    .foregroundStyle(.secondary)
                HStack {
                    Text("已选 \(store.trainingSelection.count) / \(store.trainingCandidates.count) 份")
                    Spacer()
                    Button("全选可用素材") { Task { await store.selectAllForTraining() } }.keyboardShortcut("a", modifiers: .command)
                    Button("取消全选") { store.trainingSelection = [] }
                }.disabled(store.busy)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(store.pairedSamples) { sample in
                            Toggle(isOn: Binding(get: { store.trainingSelection.contains(sample.id) }, set: { enabled in
                                Task { await store.selectForTraining(sample, enabled: enabled) }
                            })) {
                                VStack(alignment: .leading) {
                                    Text(sample.name)
                                    Text(store.canTrain(sample) ? "答案已确认 · 已对齐" : "不可选：需对齐通过并确认答案")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.disabled(store.busy || !store.canTrain(sample))
                        }
                    }
                }
                HStack { Spacer(); Button("完成") { chooseSamples = false }.buttonStyle(.borderedProminent) }
            }.padding(26).frame(width: 600, height: 440)
                .task { await store.refreshTrainingEligibility() }
        }
        .task { await store.refreshTrainingEligibility() }
    }
}

struct AIModelsView: View {
    @ObservedObject var store: AIWorkspaceStore
    var navigate: (ToolPage) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("本机模型").font(.largeTitle).fontWeight(.semibold)
                    Text("基础模型和训练版本分别保存，可选择版本进行抠图对比。").font(.title3).foregroundStyle(.secondary)
                }
                if let model = store.catalog?.model {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 20) {
                            HStack(spacing: 16) {
                                Image(systemName: "square.3.layers.3d").font(.largeTitle).foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 5) { Text(model.name).font(.title2).fontWeight(.semibold); Text("预训练基础模型").foregroundStyle(.secondary) }
                                Spacer()
                                if store.inferenceModelID == "base" { Label("当前模型", systemImage: "checkmark.circle.fill").foregroundStyle(.tint) }
                            }
                            Divider()
                            AIInfoRow("本机文件", model.available ? "可用" : "不完整或未找到")
                            AIInfoRow("既有数值验证", model.numericStatus == "passed" ? "CPU / GPU 对照通过" : (model.numericStatus == "failed" ? "未通过" : "待验证"))
                            AIInfoRow("输入尺寸", "\(model.inputSize) × \(model.inputSize)")
                            AIInfoRow("当前测试批次", "\(model.testedSamples) 份")
                            Divider()
                            Text("细节观察").font(.headline)
                            Text(model.qualitySummary).foregroundStyle(.secondary)
                            HStack {
                                Button("使用基础模型") { store.inferenceModelID = "base"; navigate(.aiCutout) }.disabled(store.busy)
                                Button("打开中文报告", action: store.openReport).disabled(store.catalog?.reportPath == nil)
                            }
                        }.padding(16)
                    }
                }
                Text("训练生成的版本").font(.headline)
                if store.trainingRuns.isEmpty {
                    Text("还没有训练版本。开始训练后，任务进度和结果会保存在本机。").foregroundStyle(.secondary)
                }
                ForEach(store.trainingRuns) { run in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text(run.name).font(.headline); Spacer(); Text(run.statusTitle) }
                            Text("\(run.sampleCount) 份素材 · \(run.step)/\(run.totalSteps) 步 · \(run.createdAt)").font(.caption).foregroundStyle(.secondary)
                            Text(run.message).font(.callout)
                            HStack {
                                Button("查看记录") { store.reveal(run.outputDirectory) }
                                if run.isUsable {
                                    Button(store.inferenceModelID == run.id ? "已用于抠图" : "用于抠图") {
                                        store.inferenceModelID = run.id; navigate(.aiCutout)
                                    }.disabled(store.busy)
                                    Button("显示模型") { store.reveal(run.modelPath) }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                }
                HStack {
                    Button("准备第一轮训练") { navigate(.aiTraining) }
                    Button("比较版本") {}.disabled(true)
                    Button("选用训练版本") {}.disabled(true)
                }
            }.frame(maxWidth: 820).padding(36).frame(maxWidth: .infinity)
        }
    }
}
