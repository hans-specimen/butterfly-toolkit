// 图鉴卡片界面：原生三栏组织标本、真实预览与逐只信息，人工构图交给 Photoshop。
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct IdentificationCardsView: View {
    @ObservedObject var store: IdentificationCardsStore
    @State private var confirmLayout = false
    @State private var confirmRemove = false
    @State private var pendingRemoval: RemovalRequest?
    @FocusState private var queueFocused: Bool
    @State private var confirmRegenerate = false
    @State private var showCollectionBatch = false

    private struct RemovalRequest {
        let ids: Set<UUID>
        let clearingList: Bool

        var title: String {
            if clearingList { return "清空这批 \(ids.count) 张卡片？" }
            return ids.count == 1 ? "移除这张卡片？" : "移除所选的 \(ids.count) 张卡片？"
        }

        var buttonTitle: String { clearingList ? "清空列表" : "移除卡片" }
    }

    var body: some View {
        VStack(spacing:0) {
            header
            Divider()
            if store.session.records.isEmpty { emptyState }
            else {
                HStack(spacing:0) {
                    queue.frame(width:210)
                    Divider()
                    preview.frame(minWidth:300,maxWidth:.infinity,maxHeight:.infinity)
                    Divider()
                    ScrollView { inspector.padding(20) }.frame(width:300)
                        .background(Color(nsColor:.windowBackgroundColor))
                }
            }
            Divider()
            footer
            if let error = store.error {
                HStack(alignment:.top) {
                    Image(systemName:"exclamationmark.triangle.fill")
                    Text(error).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                    Button("关闭") { store.error = nil }
                }.font(.callout).foregroundStyle(.red).padding(12)
            }
        }
        .background(Color(nsColor:.windowBackgroundColor))
        .frame(minWidth:900,minHeight:640)
        .sheet(isPresented: $showCollectionBatch) {
            CardCollectionBatchView(store: store)
        }
        .alert("覆盖已有 PNG？",isPresented:Binding(get:{ store.overwrite != nil },set:{ if !$0,store.overwrite != nil { store.answerOverwrite(false) } })) {
            Button("覆盖",role:.destructive) { store.answerOverwrite(true) }
            Button("跳过",role:.cancel) { store.answerOverwrite(false) }
        } message: { Text(store.overwrite?.destination.path ?? "") }
        .confirmationDialog("重新自动排版会替换这张卡片的人工位置和大小",isPresented:$confirmLayout,titleVisibility:.visible) {
            Button("重新自动排版",role:.destructive) { store.refresh(layout:true) }
            Button("取消",role:.cancel) {}
        }
        .confirmationDialog(pendingRemoval?.title ?? "移除卡片？", isPresented: $confirmRemove,
                            titleVisibility: .visible, presenting: pendingRemoval) { request in
            Button(request.buttonTitle, role: .destructive) { store.removeCards(request.ids) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("对应的临时工作 PSD 将被移除，输入图片和已导出的 PNG 会保留。")
        }
        .alert("已导出卡片需要重新生成",isPresented:$confirmRegenerate) {
            Button("重新生成") { store.refresh(layout:true) }
            Button("取消",role:.cancel) {}
        } message: { Text("临时 PSD 已清理。文字会保留，之前在 Photoshop 的人工细节无法恢复。") }
    }
    // MARK: - 输入、输出与列表
    private var header: some View {
        HStack(spacing:16) {
            VStack(alignment:.leading,spacing:4) {
                Text("图鉴卡片").font(.title2.bold())
                Text("双面 PNG · Photoshop 模板").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("添加 PNG 或文件夹…",systemImage:"plus") { chooseInputs() }.disabled(store.locked)
            Button("批量填写采集信息…") { showCollectionBatch = true }
                .disabled(store.locked || store.session.records.isEmpty)
            Button("预览全部") { store.refresh(all:true) }
                .help("依次生成缺少预览或已过期的卡片")
                .disabled(store.locked || !store.session.records.contains { $0.input.issue == nil && !store.hasCurrentPreview($0) })
            Button("导出全部") { store.export(all:true) }
                .help("导出所有已有有效预览的卡片")
                .disabled(store.locked || !store.session.records.contains { store.canExport($0) })
        }.padding(.horizontal,24).padding(.vertical,18)
    }
    private var queue: some View {
        let selectedIDs = Set(store.selectedIDs)
        let total = store.session.records.count
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("标本").font(.headline)
                    Spacer()
                    Text("已选 \(selectedIDs.count)/\(total)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                HStack {
                    Button("全选") { store.selectAll() }
                        .help("全选标本，列表内也可按 ⌘A")
                        .disabled(store.locked || selectedIDs.count == total)
                    Spacer()
                    Button("清空列表…") {
                        requestRemoval(store.session.records.map(\.id), clearingList: true)
                    }
                    .disabled(store.locked)
                }.controlSize(.small)
            }.padding(12)
            Divider()
            ScrollView {
                SpecimenSelectionRows(items: store.session.records, selectedIDs: selectedIDs, currentID: store.selectedID) { _, card, isSelected, isCurrent in
                    Button {
                        store.select(card.id, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
                        queueFocused = true
                    } label: {
                        VStack(alignment:.leading,spacing:7) {
                            HStack(spacing:6) {
                                WorkflowFileThumbnail(url:card.input.front).frame(width:70,height:48)
                                WorkflowFileThumbnail(url:card.input.back).frame(width:70,height:48)
                            }.accessibilityLabel("正面与反面素材")
                            Text(card.title).font(.body.weight(.medium)).lineLimit(2)
                            if let number = card.input.specimenNumber {
                                Text(number).font(.caption).foregroundStyle(.secondary)
                            } else if card.title != card.fields.latinName && !card.fields.latinName.isEmpty {
                                Text(card.fields.latinName).font(.caption).foregroundStyle(.secondary)
                            }
                            if let missing = card.missingNames { Text(missing).font(.caption).foregroundStyle(.orange) }
                            cardStatus(card)
                        }.frame(maxWidth:.infinity,alignment:.leading).padding(12)
                            .overlay(alignment: .topTrailing) {
                                if isSelected {
                                    Image(systemName: isCurrent ? "checkmark.circle.fill" : "checkmark.circle")
                                        .font(.caption).foregroundStyle(Color.accentColor)
                                        .padding(8).accessibilityHidden(true).allowsHitTesting(false)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityHint(isCurrent ? "当前显示预览和标本信息" : "")
                    .disabled(store.locked)
                }
            }
            .clipped()
            .focusable()
            .focusEffectDisabled()
            .focused($queueFocused)
            .onKeyPress("a", phases: .down) { press in
                let modifiers = press.modifiers.intersection([.command, .shift, .option, .control])
                guard modifiers == .command, !store.locked else { return .ignored }
                store.selectAll()
                return .handled
            }
        }
    }
    @ViewBuilder private func cardStatus(_ card: CardRecord) -> some View {
        if let issue = card.input.issue ?? card.issue {
            SpecimenStatusBadge(title: "需检查", tone: .amber)
            Text(issue).font(.caption).foregroundStyle(.secondary).lineLimit(3).help(issue)
        } else if card.isExported {
            SpecimenStatusBadge(title: "已导出", tone: .green)
        } else if store.hasCurrentPreview(card) {
            SpecimenStatusBadge(title: "待导出", tone: .blue)
        } else {
            SpecimenStatusBadge(title: "待生成预览", tone: .neutral)
        }
    }
    // MARK: - 预览与人工调整
    private var preview: some View {
        VStack(spacing:16) {
            Spacer(minLength:8)
            if let image = store.selectedImage {
                Image(nsImage:image).resizable().scaledToFit().padding(.horizontal,20)
                    .accessibilityLabel("当前图鉴卡片的 Photoshop 合成预览")
                if let current = store.current, !store.hasCurrentPreview(current) {
                    Label("请重新生成预览后导出",systemImage:"arrow.clockwise").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName:"photo.on.rectangle").font(.system(size:38,weight:.light)).foregroundStyle(.secondary)
                Text(store.current?.input.issue ?? "填写卡片信息后，点击「预览当前」或「预览全部」")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal,20)
            }
            Spacer(minLength:8)
            if store.manualID != nil {
                VStack(spacing:10) {
                    Text("在 Photoshop 中调整并保存，然后返回刷新。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("完成调整并刷新",systemImage:"arrow.clockwise") { store.finishManual() }
                        .buttonStyle(.borderedProminent).disabled(store.busy)
                }.padding(.bottom,20)
            } else {
                HStack {
                    Button("预览当前",systemImage:"eye") {
                        if let c=store.current,c.exportedURL != nil,c.roles == nil { confirmRegenerate=true } else { store.refresh() }
                    }
                    Button("在 Photoshop 中调整",systemImage:"arrow.up.forward.app") { store.openPhotoshop() }
                }.disabled(store.locked || store.current?.input.issue != nil || store.current == nil).padding(.bottom,20)
            }
        }.background(Color(nsColor:.textBackgroundColor))
    }
    // MARK: - 逐只信息
    private var inspector: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("标本信息").font(.headline)
            if let card=store.current,card.exportedURL != nil,card.roles == nil {
                Text("工作 PSD 已清理。再次生成会保留文字并重新排版，无法恢复之前的人工细节。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            editableField("中文名", placeholder: "中文名", text: field(\.chineseName))
            editableField("拉丁名", placeholder: "拉丁名", text: field(\.latinName))
            Picker("性别",selection:Binding(get:{store.current?.fields.sex ?? .unknown},set:{ value in store.edit { $0.sex=value } })) {
                ForEach(CardSex.allCases,id:\.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Divider()
            Text("采集信息").font(.headline)
            labeled("粘贴表格") {
                TextEditor(text:field(\.rawCollection)).font(.callout).frame(height:72)
                    .border(Color(nsColor:.separatorColor))
            }
            Button("整理粘贴内容",systemImage:"text.alignleft") { store.organizeCollection() }
            editableField("采集点", placeholder: "地点、地区", text: collectionField(\.locality))
            HStack(alignment:.top) {
                editableField("日期", placeholder: "2026.4", text: collectionField(\.date))
                editableField("国家", placeholder: "国家", text: collectionField(\.country))
            }
            HStack(alignment:.top) {
                editableField("海拔（米）", placeholder: "1000m", text: collectionField(\.altitude))
                editableField("翅展（mm）", placeholder: "74", text: Binding(
                    get: { store.current?.fields.collection.wingspan ?? "" },
                    set: { value in store.edit { $0.collection.wingspan = value.isEmpty ? nil : value } }
                ))
            }
            Button("更新采集文字") { store.composeCollection() }
            labeled("最终采集文字") {
                TextField("留空则不显示", text: field(\.collectionText).replacingTabs, axis: .vertical).lineLimit(2...5)
                if let message = ToolkitTextInput.multilineError(store.current?.fields.collectionText ?? "") {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            ForEach(store.current?.fields.collection.warnings ?? [],id:\.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            Text("Image Hans Collection. 为模板固定署名。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("重新自动排版…") { confirmLayout=true }.disabled(store.current?.input.issue != nil)
        }.textFieldStyle(.roundedBorder).disabled(store.locked || store.current == nil)
    }
    private func labeled<Content:View>(_ title:String,@ViewBuilder content:()->Content) -> some View {
        VStack(alignment:.leading,spacing:6) { Text(title).font(.caption).foregroundStyle(.secondary); content() }
    }
    private func editableField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        labeled(title) {
            TextField(placeholder, text: text.replacingTabs)
            if let message = ToolkitTextInput.singleLineError(text.wrappedValue) {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func field(_ key:WritableKeyPath<CardFields,String>) -> Binding<String> {
        Binding(get:{store.current?.fields[keyPath:key] ?? ""},set:{value in store.edit { $0[keyPath:key]=value }})
    }
    private func collectionField(_ key:WritableKeyPath<CardCollectionInfo,String>) -> Binding<String> {
        Binding(get:{store.current?.fields.collection[keyPath:key] ?? ""},set:{value in store.edit { $0.collection[keyPath:key]=value }})
    }
    // MARK: - 空态与输出
    private var emptyState: some View {
        VStack(spacing:18) {
            Image(systemName:"rectangle.on.rectangle").font(.system(size:46,weight:.light)).foregroundStyle(.secondary)
            Text("把正反面照片做成图鉴卡片").font(.title2.weight(.semibold))
            Text("选择透明 PNG 或文件夹，自动配对 D / V。\n逐只填写信息，预览后导出。")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("选择 PNG 或文件夹…") { chooseInputs() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(store.locked)
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private var footer: some View {
        let selected = store.selectedCards
        let exportable = selected.contains { store.canExport($0) }
        return HStack(spacing:12) {
            if store.busy { ProgressView().controlSize(.small); Text(store.activity).font(.callout) }
            else {
                VStack(alignment:.leading,spacing:4) {
                    Text("输出到").font(.caption).foregroundStyle(.secondary)
                    Text(store.session.outputDirectory.path).font(.caption).lineLimit(1).truncationMode(.middle).help(store.session.outputDirectory.path)
                    if selected.count == 1, let card = selected.first {
                        Text(card.outputName).font(.caption).lineLimit(1).truncationMode(.middle).help(card.outputName).textSelection(.enabled)
                    }
                }
                Button("更改…") { chooseOutput() }.disabled(store.locked)
            }
            Spacer(minLength:8)
            Button(role: .destructive) { requestRemoval(selected.map(\.id)) } label: {
                Text(selected.count == 1 ? "移除这张卡片…" : "移除所选…")
                    .foregroundStyle(store.locked || selected.isEmpty ? Color.secondary : .red)
            }
            .disabled(store.locked || selected.isEmpty)
            Button(selected.count == 1 ? "导出当前 PNG" : "导出所选 PNG") { store.export(all: false) }
                .buttonStyle(.borderedProminent)
                .disabled(store.locked || !exportable)
        }.padding(.horizontal,24).padding(.vertical,14)
    }
    private func requestRemoval(_ ids: [UUID], clearingList: Bool = false) {
        guard !store.locked, !ids.isEmpty else { return }
        pendingRemoval = RemovalRequest(ids: Set(ids), clearingList: clearingList)
        confirmRemove = true
    }

    private func chooseInputs() {
        let panel=NSOpenPanel(); panel.title="选择正反面 PNG 或文件夹"; panel.canChooseFiles=true; panel.canChooseDirectories=true; panel.allowsMultipleSelection=true; panel.allowedContentTypes=[.png]
        if panel.runModal() == .OK { store.importFiles(panel.urls) }
    }
    private func chooseOutput() {
        let panel=NSOpenPanel(); panel.title="选择图鉴 PNG 输出文件夹"; panel.canChooseFiles=false; panel.canChooseDirectories=true; panel.canCreateDirectories=true; panel.directoryURL=store.session.outputDirectory
        if panel.runModal() == .OK,let url=panel.url { store.setOutput(url) }
    }
}
