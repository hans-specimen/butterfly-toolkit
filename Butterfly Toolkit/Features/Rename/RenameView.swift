// 提供单面与双面照片的批量命名、预览、编号记忆，以及两阶段重命名和撤销。
//
//  RenameView.swift
//  Butterfly Toolkit
//
//  由 Hans 创建于 2026/8/4。
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers


// MARK: - 重命名模式

/// 图片重命名模式。
///
/// doubleSided：
/// 每只蝴蝶有两张照片，分别添加 A、B。
///
/// 例如：
/// NY10001A.jpg
/// NY10001B.jpg
/// NY10002A.jpg
/// NY10002B.jpg
///
/// singleSided：
/// 每张照片使用一个独立编号，不添加 A、B。
///
/// 例如：
/// NY10001.jpg
/// NY10002.jpg
/// NY10003.jpg
///
/// 单面模式下允许不填写前缀：
/// 10001.jpg
/// 10002.jpg
enum RenameMode: String, CaseIterable, Identifiable {

    /// 双面模式：每两张图片共用一个编号，并分别添加 A、B。
    case doubleSided

    /// 单面模式：每张图片使用一个独立编号。
    case singleSided

    /// 让枚举可以直接用于 SwiftUI 的 ForEach。
    var id: String {
        rawValue
    }

    /// 显示在界面上的模式名称。
    var displayName: String {
        switch self {
        case .doubleSided:
            return "双面模式"

        case .singleSided:
            return "单面模式"
        }
    }

    /// 每种模式的简短说明。
    var description: String {
        switch self {
        case .doubleSided:
            return "同一编号分为 A、B 两张照片"

        case .singleSided:
            return "每张照片一个编号，不添加 A、B"
        }
    }

    /// 用于 UserDefaults 的模式标识。
    ///
    /// 这样单面模式和双面模式可以分别记忆各自的编号，
    /// 不会互相覆盖。
    var storageKey: String {
        switch self {
        case .doubleSided:
            return "DoubleSided"

        case .singleSided:
            return "SingleSided"
        }
    }
}


// MARK: - 单条重命名记录

/// 表示一张图片从旧文件名修改为新文件名。
struct RenameItem: Identifiable {

    /// SwiftUI 在 ForEach 中识别每一条记录所使用的唯一 ID。
    let id = UUID()

    /// 当前文件地址。
    let oldURL: URL

    /// 重命名后的目标文件地址。
    let newURL: URL

    /// 当前文件名，不包含文件夹路径。
    var oldName: String {
        oldURL.lastPathComponent
    }

    /// 重命名后的文件名，不包含文件夹路径。
    var newName: String {
        newURL.lastPathComponent
    }
}


// MARK: - 主界面

struct RenameView: View {

    // MARK: - 文件夹状态

    /// 用户当前选择或拖入的文件夹。
    ///
    /// 当它为 nil 时，表示还没有选择文件夹。
    @State private var folderURL: URL?


    // MARK: - 命名设置

    /// 当前使用的重命名模式。
    ///
    /// 默认使用原来的“双面模式”。
    @State private var renameMode: RenameMode = .doubleSided

    /// 文件名前缀。
    ///
    /// 双面模式下必须填写。
    /// 单面模式下可以留空。
    @State private var prefix = "NY"

    /// 起始编号。
    ///
    /// 使用 String 保存，是因为 TextField 与 String 绑定最方便。
    /// 真正生成文件名时会转换为 Int。
    @State private var startNumber = "10001"


    // MARK: - 重命名记录

    /// 根据当前文件夹、模式、前缀和起始编号生成的重命名预览。
    @State private var renamePlan: [RenameItem] = []

    /// 最近一次成功执行的重命名记录。
    ///
    /// 用于“撤销上一次”功能。
    @State private var lastRenameItems: [RenameItem] = []


    // MARK: - 界面状态

    /// 当前拖动的文件是否位于拖放区域上方。
    @State private var isDropTargeted = false

    /// 当前是否正在执行重命名。
    @State private var isRenaming = false

    /// 界面底部显示的状态文字。
    @State private var statusMessage = "请将图片文件夹拖入下方区域"


    // MARK: - 弹窗状态

    /// 是否显示重命名确认窗口。
    @State private var showPreviewSheet = false

    /// 是否显示普通提示弹窗。
    @State private var showAlert = false

    /// 提示弹窗的标题。
    @State private var alertTitle = "提示"

    /// 提示弹窗的正文。
    @State private var alertMessage = ""


    // MARK: - 支持的图片格式

    /// 只有这些扩展名的文件才会参与重命名。
    ///
    /// 比较时会统一转换为小写，因此 JPG 和 jpg 都可以识别。
    private let allowedExtensions = [
        "jpg",
        "jpeg",
        "png",
        "tif",
        "tiff"
    ]


    // MARK: - 主界面布局

    var body: some View {
        VStack(spacing: 20) {

            // 页面标题和说明。
            headerView

            // 单面模式、双面模式选择。
            modeSelectionView

            // 文件夹拖放与浏览区域。
            dropArea

            // 图片数量、编号数量、最后编号。
            informationView

            // 前缀和起始编号输入框。
            inputView

            // 显示前几项重命名预览。
            previewView

            // 撤销、打开文件夹、开始重命名按钮。
            actionButtons

            // 页面底部状态说明。
            Text(statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .padding(32)
        .frame(width: 760, height: 760)

        // 当前缀发生变化时：
        // 1. 清理前缀内容；
        // 2. 读取保存过的编号；
        // 3. 刷新重命名预览。
        .onChange(of: prefix) { _, newValue in
            handlePrefixChanged(newValue)
        }

        // 当起始编号发生变化时，立即刷新预览。
        .onChange(of: startNumber) { _, _ in
            refreshRenamePlan()
        }

        // 当单双面模式发生变化时，
        // 读取该模式对应的上次编号并刷新预览。
        .onChange(of: renameMode) { _, _ in
            handleRenameModeChanged()
        }

        // 重命名前的确认窗口。
        .sheet(isPresented: $showPreviewSheet) {
            confirmationSheet
        }

        // 普通提示弹窗。
        .alert(alertTitle, isPresented: $showAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }


    // MARK: - 标题区域

    private var headerView: some View {
        VStack(spacing: 8) {
            Text("🦋 蝴蝶照片批量重命名")
                .font(.largeTitle)
                .bold()

            Text("选择单双面模式，设置前缀和起始编号，然后确认重命名")
                .foregroundStyle(.secondary)
        }
    }


    // MARK: - 模式选择区域

    private var modeSelectionView: some View {
        VStack(spacing: 8) {

            // 使用 segmented 样式显示两个模式按钮。
            Picker("重命名模式", selection: $renameMode) {
                ForEach(RenameMode.allCases) { mode in
                    Text(mode.displayName)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)

            // 根据当前模式显示对应说明。
            Text(renameMode.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }


    // MARK: - 文件夹拖入区域

    private var dropArea: some View {
        VStack(spacing: 14) {

            // 尚未选择文件夹时显示“添加文件夹”图标。
            // 已经选择文件夹后显示实心文件夹图标。
            Image(
                systemName: folderURL == nil
                ? "folder.badge.plus"
                : "folder.fill"
            )
            .font(.system(size: 48))
            .foregroundStyle(
                isDropTargeted
                ? Color.accentColor
                : Color.primary
            )

            if let folderURL {

                // 显示文件夹名称。
                Text(folderURL.lastPathComponent)
                    .font(.title3)
                    .bold()

                // 显示完整文件夹路径。
                Text(folderURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

            } else {

                Text("把图片文件夹拖到这里")
                    .font(.headline)

                Text("支持 JPG、JPEG、PNG、TIF、TIFF")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 除了拖放，也可以点击按钮打开系统文件夹选择器。
            Button {
                selectFolder()
            } label: {
                Label("浏览文件夹", systemImage: "folder")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 175)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    isDropTargeted
                    ? Color.accentColor.opacity(0.15)
                    : Color.secondary.opacity(0.08)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(
                    isDropTargeted
                    ? Color.accentColor
                    : Color.secondary.opacity(0.5),
                    style: StrokeStyle(
                        lineWidth: 2,
                        dash: [9]
                    )
                )
        )

        // 接收从 Finder 拖入的 URL。
        .dropDestination(for: URL.self) { urls, _ in

            // 这里只处理拖入内容中的第一个项目。
            guard let url = urls.first else {
                return false
            }

            return receiveFolder(url)

        } isTargeted: { targeted in

            // 当鼠标拖着文件进入区域时改变背景和边框颜色。
            isDropTargeted = targeted
        }
    }


    // MARK: - 数量信息区域

    private var informationView: some View {
        HStack(spacing: 20) {

            informationCard(
                title: "图片数量",
                value: "\(renamePlan.count)",
                icon: "photo.on.rectangle.angled"
            )

            informationCard(
                title: itemCountTitle,
                value: "\(numberedItemCount)",
                icon: "number"
            )

            informationCard(
                title: "最后编号",
                value: calculatedLastNumber,
                icon: "tag"
            )
        }
    }

    /// 第二张信息卡片的标题。
    ///
    /// 双面模式下，两张图片代表一只蝴蝶，因此显示“蝴蝶数量”。
    /// 单面模式下，每张图片使用一个编号，因此显示“编号数量”。
    private var itemCountTitle: String {
        switch renameMode {
        case .doubleSided:
            return "蝴蝶数量"

        case .singleSided:
            return "编号数量"
        }
    }

    /// 当前实际会使用多少个编号。
    ///
    /// 双面模式：
    /// 4 张图片使用 2 个编号。
    ///
    /// 单面模式：
    /// 4 张图片使用 4 个编号。
    private var numberedItemCount: Int {
        switch renameMode {
        case .doubleSided:
            return renamePlan.count / 2

        case .singleSided:
            return renamePlan.count
        }
    }

    /// 创建统一样式的信息卡片。
    private func informationCard(
        title: String,
        value: String,
        icon: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.headline)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    /// 根据当前模式计算最后一个编号。
    ///
    /// 例如双面模式：
    /// 起始编号 10001，共 6 张图片，也就是 3 只蝴蝶，
    /// 最后编号为 10003。
    ///
    /// 例如单面模式：
    /// 起始编号 10001，共 6 张图片，
    /// 最后编号为 10006。
    private var calculatedLastNumber: String {
        guard let number = ToolkitTextInput.integer(startNumber, in: 1...Int.max),
              !renamePlan.isEmpty else {
            return "—"
        }

        let (lastNumber, overflow) = number.addingReportingOverflow(max(0, numberedItemCount - 1))
        return overflow ? "—" : String(lastNumber)
    }


    // MARK: - 输入区域

    private var inputView: some View {
        VStack(spacing: 8) {

            HStack(spacing: 26) {

                HStack {
                    Text("前缀")

                    TextField(
                        renameMode == .singleSided
                        ? "可留空，例如 NY"
                        : "例如 NY",
                        text: $prefix.replacingTabs
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 155)
                }

                HStack {
                    Text("起始编号")

                    TextField(
                        "例如 10061",
                        text: $startNumber.replacingTabs
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                }
            }

            // 单面模式下明确提醒用户前缀可以为空。
            if renameMode == .singleSided {
                Text("单面模式允许前缀留空，例如：10001.jpg、10002.jpg")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }


    // MARK: - 实时预览

    private var previewView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("重命名预览")
                    .font(.headline)

                Spacer()

                if renamePlan.count > 6 {
                    Text("显示前 6 项")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if renamePlan.isEmpty {

                Text("选择文件夹并填写正确设置后，将在这里显示预览")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 80)

            } else {

                VStack(spacing: 5) {
                    ForEach(renamePlan.prefix(6)) { item in
                        HStack {
                            Text(item.oldName)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)

                            Text(item.newName)
                                .bold()
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()
                        }
                        .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 92, alignment: .top)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.06))
        )
    }


    // MARK: - 操作按钮

    private var actionButtons: some View {
        HStack(spacing: 16) {

            // 撤销最近一次成功执行的重命名。
            Button {
                undoLastRename()
            } label: {
                Label(
                    "撤销上一次",
                    systemImage: "arrow.uturn.backward"
                )
                .frame(width: 130)
            }
            .disabled(lastRenameItems.isEmpty || isRenaming)

            // 在 Finder 中打开当前文件夹。
            Button {
                openSelectedFolder()
            } label: {
                Label(
                    "打开文件夹",
                    systemImage: "folder"
                )
                .frame(width: 120)
            }
            .disabled(folderURL == nil)

            // 开始重命名前先打开确认窗口。
            Button {
                prepareConfirmation()
            } label: {
                if isRenaming {

                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 160)

                } else {

                    Label(
                        "开始重命名",
                        systemImage: "play.fill"
                    )
                    .frame(width: 160)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(
                folderURL == nil ||
                renamePlan.isEmpty ||
                isRenaming
            )
        }
    }


    // MARK: - 确认窗口

    private var confirmationSheet: some View {
        VStack(spacing: 18) {
            Text("确认重命名")
                .font(.title2)
                .bold()

            Text(confirmationDescription)
                .foregroundStyle(.secondary)

            // 最多显示前 20 项，
            // 防止图片数量很多时确认窗口过长。
            List(renamePlan.prefix(20)) { item in
                HStack {
                    Text(item.oldName)
                        .lineLimit(1)

                    Spacer()

                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)

                    Text(item.newName)
                        .bold()
                        .lineLimit(1)
                }
            }

            if renamePlan.count > 20 {
                Text("这里只显示前 20 项，其余文件将按照相同规则处理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("取消", role: .cancel) {
                    showPreviewSheet = false
                }

                Spacer()

                Button {
                    showPreviewSheet = false
                    performRename()
                } label: {
                    Text("确认并开始")
                        .frame(width: 120)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 650, height: 560)
    }

    /// 确认窗口中的数量说明。
    private var confirmationDescription: String {
        switch renameMode {
        case .doubleSided:
            return """
            即将使用双面模式重命名 \(renamePlan.count) 张图片，\
            共 \(renamePlan.count / 2) 只蝴蝶。
            """

        case .singleSided:
            return """
            即将使用单面模式重命名 \(renamePlan.count) 张图片，\
            共使用 \(renamePlan.count) 个编号。
            """
        }
    }


    // MARK: - 浏览选择文件夹

    private func selectFolder() {
        let panel = NSOpenPanel()

        // 文件选择窗口标题。
        panel.title = "选择图片文件夹"

        // 右下角确认按钮的文字。
        panel.prompt = "选择"

        // 不允许选择单独文件。
        panel.canChooseFiles = false

        // 允许选择文件夹。
        panel.canChooseDirectories = true

        // 每次只允许选择一个文件夹。
        panel.allowsMultipleSelection = false

        // 不在这里创建新文件夹。
        panel.canCreateDirectories = false

        // 用户点击确认，并且成功获得文件夹 URL。
        if panel.runModal() == .OK,
           let url = panel.url {
            _ = receiveFolder(url)
        }
    }


    // MARK: - 接收拖入或选择的文件夹

    /// 处理用户拖入或选择的文件夹。
    ///
    /// - Parameter url: 用户拖入或选择的 URL。
    /// - Returns: 是否成功接收该文件夹。
    private func receiveFolder(_ url: URL) -> Bool {

        // 用于接收目标是否为文件夹。
        var isDirectory: ObjCBool = false

        // 检查路径是否存在，并同时判断是不是文件夹。
        let exists = FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        )

        guard exists, isDirectory.boolValue else {
            showMessage(
                title: "无法使用",
                message: "请拖入一个文件夹，不要拖入单张图片。"
            )
            return false
        }

        // 保存当前文件夹。
        folderURL = url

        // 尝试根据文件夹名称自动识别前缀。
        autoDetectPrefix(from: url)

        // 生成重命名预览。
        refreshRenamePlan()

        return true
    }


    // MARK: - 自动识别前缀

    /// 如果文件夹名称仅由 2～5 个字母组成，
    /// 就自动把它作为文件名前缀。
    ///
    /// 例如文件夹名称为 NY，
    /// 则前缀自动设置为 NY。
    private func autoDetectPrefix(from url: URL) {
        let folderName = url.lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        // 检查文件夹名是否全部由字母组成。
        let lettersOnly = folderName.allSatisfy {
            $0.isLetter
        }

        guard lettersOnly,
              folderName.count >= 2,
              folderName.count <= 5 else {
            return
        }

        prefix = folderName

        // 读取该模式、该前缀上次保存的编号。
        loadRememberedNumber()
    }


    // MARK: - 前缀发生变化

    /// 清理用户输入的前缀。
    ///
    /// 主要完成：
    /// 1. 去除首尾空格；
    /// 2. 自动转换为大写；
    /// 3. 读取保存的编号；
    /// 4. 刷新预览。
    private func handlePrefixChanged(_ newValue: String) {
        let cleaned = ToolkitTextInput.replacingTabs(newValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        if ToolkitTextInput.singleLineError(newValue, filename: true) != nil {
            refreshRenamePlan()
            return
        }

        // 如果清理后的内容和原内容不同，
        // 重新赋值后先结束本次处理。
        //
        // 重新赋值会再次触发 onChange，
        // 下一次再继续读取编号和刷新预览。
        if cleaned != newValue {
            prefix = cleaned
            return
        }

        loadRememberedNumber()
        refreshRenamePlan()
    }


    // MARK: - 模式发生变化

    /// 当用户切换单面模式或双面模式时调用。
    private func handleRenameModeChanged() {

        // 切换模式后，读取该模式单独保存的编号。
        loadRememberedNumber()

        // 按照新模式重新生成预览。
        refreshRenamePlan()
    }


    // MARK: - UserDefaults 编号记忆

    /// 生成编号存储所使用的 UserDefaults 键。
    ///
    /// 键中包含：
    /// 1. 当前模式；
    /// 2. 当前前缀。
    ///
    /// 例如：
    /// NextNumber_DoubleSided_NY
    /// NextNumber_SingleSided_NY
    /// NextNumber_SingleSided_NoPrefix
    ///
    /// 这样不同模式和不同前缀的编号互不影响。
    private var rememberedNumberKey: String {
        let cleanedPrefix = prefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        let prefixPart = cleanedPrefix.isEmpty
            ? "NoPrefix"
            : cleanedPrefix

        return "NextNumber_\(renameMode.storageKey)_\(prefixPart)"
    }

    /// 读取该模式和前缀上次保存的下一个编号。
    private func loadRememberedNumber() {
        let savedNumber = UserDefaults.standard.integer(
            forKey: rememberedNumberKey
        )

        // UserDefaults 在键不存在时会返回 0。
        // 因此只有大于 0 时才使用保存值。
        if savedNumber > 0 {
            startNumber = String(savedNumber)
        }
    }

    /// 保存下次应该使用的起始编号。
    private func saveNextNumber(_ number: Int) {
        UserDefaults.standard.set(
            number,
            forKey: rememberedNumberKey
        )
    }


    // MARK: - 生成重命名方案

    /// 根据当前设置生成完整的重命名预览。
    private func refreshRenamePlan() {

        if let message = ToolkitTextInput.singleLineError(prefix, filename: true) {
            renamePlan = []
            statusMessage = "前缀：\(message)"
            return
        }
        if let message = ToolkitTextInput.singleLineError(startNumber) {
            renamePlan = []
            statusMessage = "起始编号：\(message)"
            return
        }

        // 必须先选择文件夹。
        guard let folderURL else {
            renamePlan = []
            statusMessage = "请将图片文件夹拖入下方区域"
            return
        }

        // 清理前缀。
        let cleanedPrefix = prefix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        // 起始编号必须能够转换成整数，
        // 并且必须大于 0。
        guard let initialNumber = ToolkitTextInput.integer(startNumber, in: 1...Int.max),
              initialNumber > 0 else {
            renamePlan = []
            statusMessage = "请输入正确的起始编号"
            return
        }

        // 双面模式仍然要求必须填写前缀。
        //
        // 单面模式允许前缀为空。
        if renameMode == .doubleSided,
           cleanedPrefix.isEmpty {
            renamePlan = []
            statusMessage = "双面模式下请输入文件名前缀"
            return
        }

        // 对沙盒应用而言，访问用户选择的外部文件夹时，
        // 可能需要开启安全范围访问权限。
        let accessGranted =
            folderURL.startAccessingSecurityScopedResource()

        // 无论函数成功还是失败，
        // 结束时都停止安全范围访问。
        defer {
            if accessGranted {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            // 读取并排序文件夹中的所有支持图片。
            let files = try imageFiles(in: folderURL)
            let count = renameMode == .doubleSided ? files.count / 2 + files.count % 2 : files.count
            guard initialNumber <= Int.max - count else {
                renamePlan = []
                statusMessage = "起始编号过大，请缩小编号。"
                return
            }

            var items: [RenameItem] = []

            switch renameMode {

            // MARK: - 双面模式生成规则

            case .doubleSided:

                var currentNumber = initialNumber

                for (index, oldURL) in files.enumerated() {

                    // 第 0、2、4……张为 A。
                    // 第 1、3、5……张为 B。
                    let side = index.isMultiple(of: 2)
                        ? "A"
                        : "B"

                    // 保留原图片的扩展名。
                    let fileExtension =
                        oldURL.pathExtension.lowercased()

                    // 生成新文件名。
                    //
                    // 例如：
                    // NY10001A.jpg
                    // NY10001B.jpg
                    let newName =
                        "\(cleanedPrefix)\(currentNumber)\(side).\(fileExtension)"

                    let newURL =
                        folderURL.appendingPathComponent(newName)

                    items.append(
                        RenameItem(
                            oldURL: oldURL,
                            newURL: newURL
                        )
                    )

                    // B 面完成后，编号加 1。
                    if side == "B" {
                        currentNumber += 1
                    }
                }


            // MARK: - 单面模式生成规则

            case .singleSided:

                for (index, oldURL) in files.enumerated() {

                    // 单面模式每张图片编号加 1。
                    let currentNumber =
                        initialNumber + index

                    // 保留原图片扩展名。
                    let fileExtension =
                        oldURL.pathExtension.lowercased()

                    // 单面模式允许前缀为空。
                    //
                    // 有前缀时：
                    // NY10001.jpg
                    //
                    // 无前缀时：
                    // 10001.jpg
                    let newName =
                        "\(cleanedPrefix)\(currentNumber).\(fileExtension)"

                    let newURL =
                        folderURL.appendingPathComponent(newName)

                    items.append(
                        RenameItem(
                            oldURL: oldURL,
                            newURL: newURL
                        )
                    )
                }
            }

            // 保存生成结果，界面会自动刷新。
            renamePlan = items

            // 根据读取结果更新底部状态文字。
            updateStatusMessage(for: files.count)

        } catch {

            // 如果读取文件夹失败，清空预览。
            renamePlan = []

            statusMessage =
                "读取文件夹失败：\(error.localizedDescription)"
        }
    }


    // MARK: - 更新状态文字

    /// 根据图片数量和当前模式更新状态说明。
    private func updateStatusMessage(for fileCount: Int) {

        if fileCount == 0 {
            statusMessage = "该文件夹中没有找到支持的图片"
            return
        }

        switch renameMode {

        case .doubleSided:

            if fileCount.isMultiple(of: 2) {
                statusMessage =
                    "双面模式：已发现 \(fileCount) 张图片，共 \(fileCount / 2) 只蝴蝶"
            } else {
                statusMessage =
                    "⚠️ 双面模式下发现 \(fileCount) 张图片，图片数量不是偶数"
            }

        case .singleSided:

            statusMessage =
                "单面模式：已发现 \(fileCount) 张图片，将使用 \(fileCount) 个编号"
        }
    }


    // MARK: - 读取并排序图片

    /// 读取文件夹中的图片，并按照文件名自然排序。
    ///
    /// 自然排序可以让：
    /// 1.jpg
    /// 2.jpg
    /// 10.jpg
    ///
    /// 按照符合人类习惯的顺序排列，
    /// 而不是 1、10、2。
    private func imageFiles(in folderURL: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [
                .isRegularFileKey
            ],
            options: [
                .skipsHiddenFiles
            ]
        )
        .filter { url in

            // 只保留支持的图片扩展名。
            allowedExtensions.contains(
                url.pathExtension.lowercased()
            )
        }
        .sorted {

            // 使用 macOS 的自然排序规则。
            $0.lastPathComponent.localizedStandardCompare(
                $1.lastPathComponent
            ) == .orderedAscending
        }
    }


    // MARK: - 执行前检查

    /// 在显示确认窗口前进行基础检查。
    private func prepareConfirmation() {

        guard folderURL != nil else {
            showMessage(
                title: "未选择文件夹",
                message: "请先拖入或选择图片文件夹。"
            )
            return
        }

        guard !renamePlan.isEmpty else {
            showMessage(
                title: "没有图片",
                message: "没有找到可以重命名的图片，或者当前命名设置不正确。"
            )
            return
        }

        // 只有双面模式才要求图片数量为偶数。
        if renameMode == .doubleSided,
           !renamePlan.count.isMultiple(of: 2) {
            showMessage(
                title: "图片数量异常",
                message:
                    "双面模式下共发现 \(renamePlan.count) 张图片，"
                    + "数量不是偶数。\n\n"
                    + "请检查是否缺少某只蝴蝶的正面或反面照片，"
                    + "或者改用单面模式。"
            )
            return
        }

        // 检查通过后显示确认窗口。
        showPreviewSheet = true
    }


    // MARK: - 真正执行重命名

    private func performRename() {
        guard let folderURL else {
            return
        }

        // 防止用户在重命名过程中重复点击按钮。
        isRenaming = true

        let accessGranted =
            folderURL.startAccessingSecurityScopedResource()

        defer {
            if accessGranted {
                folderURL.stopAccessingSecurityScopedResource()
            }

            isRenaming = false
        }

        do {
            // 在真正移动文件前检查目标名称是否安全。
            try validateRenamePlan(renamePlan)

            // 使用两阶段方式执行重命名，
            // 避免新旧文件名互相占用。
            try executeTwoStageRename(renamePlan)

            // 保存本次记录，用于撤销。
            lastRenameItems = renamePlan

            // 当前一共消耗了多少个编号。
            let usedNumberCount = numberedItemCount

            let initialNumber = ToolkitTextInput.integer(startNumber, in: 1...Int.max) ?? 0

            // 计算下一次应该使用的起始编号。
            let nextNumber =
                initialNumber + usedNumberCount

            // 保存下次编号。
            saveNextNumber(nextNumber)

            // 同时更新界面中的起始编号。
            startNumber = String(nextNumber)

            showMessage(
                title: "重命名完成",
                message: successMessage(nextNumber: nextNumber)
            )

            // 重命名结束后重新读取文件夹，
            // 更新预览中的文件名。
            refreshRenamePlan()

        } catch {
            showMessage(
                title: "重命名失败",
                message: error.localizedDescription
            )
        }
    }

    /// 根据当前模式生成成功提示。
    private func successMessage(nextNumber: Int) -> String {
        switch renameMode {

        case .doubleSided:
            return """
            成功重命名 \(renamePlan.count) 张图片，\
            共 \(renamePlan.count / 2) 只蝴蝶。

            下次起始编号已自动更新为 \(nextNumber)。
            """

        case .singleSided:
            return """
            成功重命名 \(renamePlan.count) 张图片，\
            共使用 \(renamePlan.count) 个编号。

            下次起始编号已自动更新为 \(nextNumber)。
            """
        }
    }


    // MARK: - 检查重名和重复目标

    /// 在执行重命名前检查是否存在文件名冲突。
    private func validateRenamePlan(
        _ items: [RenameItem]
    ) throws {
        let fileManager = FileManager.default

        // 当前所有源文件路径。
        let sourcePaths = Set(
            items.map {
                $0.oldURL.standardizedFileURL.path
            }
        )

        // 所有目标文件路径。
        let targetPaths = items.map {
            $0.newURL.standardizedFileURL.path
        }

        // 如果目标路径去重后的数量变少，
        // 说明有两个文件生成了相同的新文件名。
        if Set(targetPaths).count != targetPaths.count {
            throw RenameError.duplicateTargetName
        }

        for item in items {
            let targetPath =
                item.newURL.standardizedFileURL.path

            // 如果目标文件已经存在，
            // 并且它又不是本次要参与重命名的源文件，
            // 就说明会覆盖无关文件，因此中止。
            if fileManager.fileExists(atPath: targetPath),
               !sourcePaths.contains(targetPath) {
                throw RenameError.fileAlreadyExists(
                    item.newName
                )
            }
        }
    }


    // MARK: - 两阶段重命名

    /// 使用临时文件名完成安全重命名。
    ///
    /// 为什么不能直接逐个改名：
    ///
    /// 假设文件夹中存在：
    /// 1.jpg
    /// 2.jpg
    ///
    /// 如果直接把 1.jpg 改成 2.jpg，
    /// 就会与现有 2.jpg 冲突。
    ///
    /// 因此分为两个阶段：
    ///
    /// 第一阶段：
    /// 所有文件先改成随机临时名称。
    ///
    /// 第二阶段：
    /// 临时文件再改成最终名称。
    private func executeTwoStageRename(
        _ items: [RenameItem]
    ) throws {
        let fileManager = FileManager.default

        // 记录原地址、临时地址和最终地址。
        var temporaryItems:
            [(original: URL, temporary: URL, final: URL)] = []

        do {

            // 第一阶段：全部移动到随机临时名称。
            for item in items {

                // 如果旧地址和新地址完全相同，
                // 表示该文件本身不需要改名。
                if item.oldURL.standardizedFileURL ==
                    item.newURL.standardizedFileURL {
                    continue
                }

                // UUID 可以确保临时文件名基本不会重复。
                let temporaryName =
                    ".butterfly-renamer-\(UUID().uuidString).tmp"

                let temporaryURL =
                    item.oldURL
                        .deletingLastPathComponent()
                        .appendingPathComponent(temporaryName)

                try fileManager.moveItem(
                    at: item.oldURL,
                    to: temporaryURL
                )

                temporaryItems.append(
                    (
                        original: item.oldURL,
                        temporary: temporaryURL,
                        final: item.newURL
                    )
                )
            }

            // 第二阶段：临时名称改成最终名称。
            for item in temporaryItems {
                try fileManager.moveItem(
                    at: item.temporary,
                    to: item.final
                )
            }

        } catch {

            // 任一阶段发生错误，都尝试恢复原文件名。
            rollbackTemporaryItems(temporaryItems)

            throw error
        }
    }


    // MARK: - 失败回滚

    /// 重命名中途失败时，尽可能恢复原始文件名。
    private func rollbackTemporaryItems(
        _ items: [
            (
                original: URL,
                temporary: URL,
                final: URL
            )
        ]
    ) {
        let fileManager = FileManager.default

        // 使用 reversed 从最后一个文件开始恢复，
        // 可以减少恢复过程中的名称冲突。
        for item in items.reversed() {

            // 如果文件还停留在临时名称，
            // 就从临时名称恢复到原名称。
            if fileManager.fileExists(
                atPath: item.temporary.path
            ) {
                try? fileManager.moveItem(
                    at: item.temporary,
                    to: item.original
                )

            // 如果文件已经进入最终名称，
            // 就从最终名称恢复到原名称。
            } else if fileManager.fileExists(
                atPath: item.final.path
            ) {
                try? fileManager.moveItem(
                    at: item.final,
                    to: item.original
                )
            }
        }
    }


    // MARK: - 撤销

    /// 撤销最近一次成功执行的重命名。
    private func undoLastRename() {
        guard !lastRenameItems.isEmpty else {
            return
        }

        guard let folderURL else {
            return
        }

        let accessGranted =
            folderURL.startAccessingSecurityScopedResource()

        defer {
            if accessGranted {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        // 将旧地址和新地址互换，
        // 就得到一份反向重命名方案。
        let undoItems = lastRenameItems.map {
            RenameItem(
                oldURL: $0.newURL,
                newURL: $0.oldURL
            )
        }

        do {
            // 先检查撤销时是否也存在文件名冲突。
            try validateRenamePlan(undoItems)

            // 使用同样的两阶段方式恢复文件。
            try executeTwoStageRename(undoItems)

            // 撤销成功后清空记录，
            // 防止用户重复撤销同一次操作。
            lastRenameItems = []

            showMessage(
                title: "已撤销",
                message: "上一次重命名已经恢复。"
            )

            refreshRenamePlan()

        } catch {
            showMessage(
                title: "撤销失败",
                message: error.localizedDescription
            )
        }
    }


    // MARK: - 打开文件夹

    /// 在 Finder 中打开当前选择的文件夹。
    private func openSelectedFolder() {
        guard let folderURL else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting(
            [folderURL]
        )
    }


    // MARK: - 弹窗

    /// 统一设置并显示提示弹窗。
    private func showMessage(
        title: String,
        message: String
    ) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}


// MARK: - 自定义错误

/// 重命名过程中可能出现的自定义错误。
enum RenameError: LocalizedError {

    /// 文件夹中已经存在某个目标文件。
    case fileAlreadyExists(String)

    /// 生成的目标文件名中存在重复。
    case duplicateTargetName

    /// 显示给用户看的错误说明。
    var errorDescription: String? {
        switch self {

        case .fileAlreadyExists(let fileName):
            return "文件夹中已经存在目标文件：\(fileName)"

        case .duplicateTargetName:
            return "生成的目标文件名存在重复，请检查前缀和起始编号。"
        }
    }
}


// MARK: - SwiftUI 预览

#Preview {
    RenameView()
}
