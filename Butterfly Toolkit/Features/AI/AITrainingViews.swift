import SwiftUI

struct AISamplesView: View {
    @ObservedObject var store: AIWorkspaceStore
    @State private var viewport = AIViewport()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("训练素材").font(.title2).fontWeight(.semibold)
                    Text("\(store.pairedSamples.count) 组成对素材 · 人工精扣与确认后的修正答案").foregroundStyle(.secondary)
                }
                Spacer()
                Button("载入测试批次…", action: store.chooseRun).disabled(store.busy)
            }.padding(20)
            Table(store.pairedSamples, selection: $store.selectedID) {
                TableColumn("素材") { sample in
                    HStack(spacing: 10) {
                        AIThumbnail(path: sample.reference ?? sample.original).frame(width: 45, height: 36)
                        Text(sample.name).lineLimit(2).help(sample.name)
                    }.padding(.vertical, 4)
                }.width(min: 210, ideal: 330)
                TableColumn("对齐") { sample in
                    Label(sample.alignmentTitle, systemImage: sample.alignment == "aligned" ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(sample.alignment == "aligned" ? Color.secondary : .orange)
                }.width(85)
                TableColumn("用途") { sample in Text(store.curation.use(for: sample.id).rawValue).foregroundStyle(.secondary) }.width(70)
                TableColumn("尺寸") { sample in Text(sample.dimensions).monospacedDigit() }.width(110)
            }.frame(minHeight: 200, maxHeight: 300)
            Divider()
            if let sample = store.selected, sample.reference != nil {
                HStack {
                    Label("图层对齐检查", systemImage: "square.on.square").font(.headline)
                    Spacer()
                    Text(sample.alignment == "aligned" ? "对齐记录通过" : "请核对原图与答案位置").foregroundStyle(sample.alignment == "aligned" ? Color.secondary : .orange)
                    Button("整图") { viewport.fit(sample.pixelSize) }
                    Button("细节") { focus(sample) }
                }.padding(16)
                HStack(spacing: 1) {
                    AIImagePanel(path: sample.original, title: "原始底图", imageSize: sample.pixelSize, background: .black, viewport: $viewport)
                    AIImagePanel(path: sample.reference, title: "人工答案", imageSize: sample.pixelSize, background: .black, viewport: $viewport)
                }.background(Color(nsColor: .separatorColor))
                .onChange(of: sample.id, initial: true) { _, _ in focus(sample) }
            } else {
                ContentUnavailableView("选择一份素材检查对齐", systemImage: "square.on.square")
            }
            HStack { Text("\(store.alignedCount) 份对齐正常 · \(store.pairedSamples.count - store.alignedCount) 份需处理或核对"); Spacer(); Text("同一标本整组划分用途") }
                .font(.caption).foregroundStyle(.secondary).padding(14)
        }
        .onAppear { store.selectPairedSampleIfAvailable() }
    }
    private func focus(_ sample: AISample) {
        if let roi = sample.rois.dropFirst().first ?? sample.rois.first { viewport.center = roi.center; viewport.zoom = 8 }
        else { viewport.fit(sample.pixelSize) }
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
                        Text("创建第一轮训练").font(.largeTitle).fontWeight(.semibold)
                        Text("用人工精扣，教模型保留白色缘毛。").font(.title3).foregroundStyle(.secondary)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 16) {
                            Label("小样本学习验证", systemImage: "scope").font(.headline)
                            Text("先准备少量已对齐的素材，后续验证模型能否学会细节，再扩大训练范围。")
                                .foregroundStyle(.secondary)
                            Divider()
                            HStack { Text("任务名称"); Spacer(); TextField("训练任务名称", text: $store.taskName).textFieldStyle(.roundedBorder).frame(maxWidth: 280) }
                        }.padding(10)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        Text("训练素材").font(.headline)
                        HStack {
                            Label("\(store.trainingCandidates.count) 份符合训练选择条件 · 已选 \(store.trainingSelection.count) 份", systemImage: "photo.stack")
                            Spacer(); Button("选择样本…") { chooseSamples = true }
                        }
                        HStack(spacing: 12) {
                            ForEach(store.samples.filter { store.trainingSelection.contains($0.id) }) { sample in
                                AIThumbnail(path: sample.reference).frame(width: 80, height: 64).help(sample.name)
                            }
                        }
                        Text("先在训练素材页确认标本组并设置为“训练”。缺少答案、待核对或对齐异常的样本不可选择。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("初始模型").font(.headline)
                        Picker("初始模型", selection: .constant("base")) {
                            Text(store.catalog?.model.name ?? "未连接模型").tag("base")
                        }.labelsHidden()
                        Text("当前只有预训练基础模型；尚无蝴蝶专项训练版本。").font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("高级设置", isExpanded: $advanced) {
                        VStack(alignment: .leading, spacing: 10) {
                            AIInfoRow("既有推理输入", "2048 × 2048 · FP32")
                            Text("训练轮数、学习率、保存点等参数尚未接入，需后续小规模训练验证后确定。这里不会安装依赖、下载模型或启动训练。")
                                .font(.callout).foregroundStyle(.secondary)
                        }.padding(.top, 12)
                    }
                    Label("训练后端尚未接入，当前仅能准备素材与任务信息。", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: 720).padding(36).frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                Label("尚无训练任务", systemImage: "clock").foregroundStyle(.secondary)
                Spacer()
                Button("创建训练任务（未接入）") {}.buttonStyle(.borderedProminent).disabled(true)
            }.padding(20)
        }
        .sheet(isPresented: $chooseSamples) {
            VStack(alignment: .leading, spacing: 16) {
                Text("选择训练素材").font(.title2).fontWeight(.semibold)
                Text("同一标本的正反面及裁切只能属于同一种用途。以下仅允许选择已确认且用途为训练的样本。")
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(store.pairedSamples) { sample in
                            Toggle(isOn: Binding(get: { store.trainingSelection.contains(sample.id) }, set: { enabled in
                                if enabled && store.canTrain(sample) { store.trainingSelection.insert(sample.id) }
                                else { store.trainingSelection.remove(sample.id) }
                            })) {
                                VStack(alignment: .leading) {
                                    Text(sample.name)
                                    Text(store.canTrain(sample) ? "已对齐 · 训练组" : "不可选：需有人工答案、对齐通过、确认标本组并设为训练用途")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.disabled(!store.canTrain(sample))
                        }
                    }
                }
                HStack { Spacer(); Button("完成") { chooseSamples = false }.buttonStyle(.borderedProminent) }
            }.padding(26).frame(width: 600, height: 440)
        }
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
                    Text("保留基础模型，未来训练产生的新版本单独保存。").font(.title3).foregroundStyle(.secondary)
                }
                if let model = store.catalog?.model {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 20) {
                            HStack(spacing: 16) {
                                Image(systemName: "square.3.layers.3d").font(.largeTitle).foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 5) { Text(model.name).font(.title2).fontWeight(.semibold); Text("预训练基础模型").foregroundStyle(.secondary) }
                                Spacer()
                                Label("当前模型", systemImage: "checkmark.circle.fill").foregroundStyle(.tint)
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
                                Button("查看测试对比") { navigate(.aiCutout) }
                                Button("打开中文报告", action: store.openReport).disabled(store.catalog?.reportPath == nil)
                            }
                        }.padding(16)
                    }
                }
                Text("训练生成的版本").font(.headline)
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "tray").font(.title).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("还没有训练版本").font(.title3)
                        Text("真实训练完成后，才能比较效果并选择用于抠图的版本。")
                            .foregroundStyle(.secondary)
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
