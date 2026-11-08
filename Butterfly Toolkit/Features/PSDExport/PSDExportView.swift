// 管理 PSD 文件或文件夹的选择、导出格式与数量预览，并调度批量导出和结果提示。

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PSDExportView: View {
    @AppStorage("psdExport.inputFolderPath")
    private var rememberedInputFolderPath = ""

    @AppStorage("psdExport.outputFolderPath")
    private var outputFolderPath = ""

    @State private var source: PSDExportSource?
    @State private var format: PSDExportFormat = .jpeg
    @State private var imageCount = 0
    @State private var existingCount = 0
    @State private var isProcessing = false
    @State private var progress: Double = 0
    @State private var statusMessage = "请选择 PSD 文件或输入文件夹"
    @State private var isInputDropTargeted = false
    @State private var isOutputDropTargeted = false

    @State private var showAlert = false
    @State private var alertTitle = "提示"
    @State private var alertMessage = ""
    @State private var completionSound: NSSound?

    private var outputFolderURL: URL? {
        guard !outputFolderPath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: outputFolderPath, isDirectory: true)
    }

    // MARK: - 页面布局

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                headerView

                inputDropArea
                    .frame(maxWidth: 860)

                outputDropArea
                    .frame(maxWidth: 860)

                formatView

                informationView
                    .frame(maxWidth: 860)

                if isProcessing {
                    VStack(spacing: 8) {
                        ProgressView(value: progress)
                            .frame(maxWidth: 520)

                        Text("\(Int(progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    startExport()
                } label: {
                    if isProcessing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 190)
                    } else {
                        Label("开始导出", systemImage: "square.and.arrow.down")
                            .frame(width: 190)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    isProcessing ||
                    source == nil ||
                    outputFolderURL == nil ||
                    imageCount == 0
                )

                Text(statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .padding(34)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            restoreRememberedInputFolder()
            refreshCounts()
        }
        .onChange(of: format) {
            refreshCounts()
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    // MARK: - 界面组件

    private var headerView: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.badge.arrow.up")
                .font(.system(size: 54))

            Text("PSD 批量导出")
                .font(.largeTitle)
                .bold()

            Text("按原尺寸导出为 JPG 或 PNG，并统一转换为 sRGB")
                .foregroundStyle(.secondary)
        }
    }

    private var inputDropArea: some View {
        VStack(spacing: 13) {
            Image(
                systemName: source == nil
                    ? "doc.on.doc"
                    : "checkmark.circle.fill"
            )
            .font(.system(size: 38))
            .foregroundStyle(source == nil ? .secondary : Color.accentColor)

            Text(inputTitle)
                .font(.headline)

            Text(inputDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)

            HStack(spacing: 12) {
                Button {
                    selectInputFolder()
                } label: {
                    Label("选择文件夹…", systemImage: "folder")
                }

                Button {
                    selectPSDFiles()
                } label: {
                    Label("选择 PSD 文件…", systemImage: "doc.on.doc")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isProcessing)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 190)
        .padding(.horizontal, 22)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    isInputDropTargeted
                        ? Color.accentColor.opacity(0.10)
                        : Color.secondary.opacity(0.06)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    isInputDropTargeted
                        ? Color.accentColor
                        : Color.secondary.opacity(0.45),
                    style: StrokeStyle(lineWidth: 2, dash: [9, 7])
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .dropDestination(for: URL.self) { urls, _ in
            handleInputDrop(urls)
        } isTargeted: { targeted in
            isInputDropTargeted = targeted
        }
    }

    private var outputDropArea: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.fill.badge.plus")
                .font(.title2)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text("输出文件夹")
                    .font(.headline)

                Text(
                    outputFolderPath.isEmpty
                        ? "把输出文件夹拖到这里，或者点击选择"
                        : outputFolderPath
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            }

            Spacer()

            if let outputFolderURL {
                Button("打开") {
                    NSWorkspace.shared.open(outputFolderURL)
                }
                .disabled(isProcessing)
            }

            Button("选择…") {
                selectOutputFolder()
            }
            .disabled(isProcessing)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    isOutputDropTargeted
                        ? Color.accentColor.opacity(0.12)
                        : Color.secondary.opacity(0.08)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isOutputDropTargeted
                        ? Color.accentColor
                        : Color.clear,
                    lineWidth: 2
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .dropDestination(for: URL.self) { urls, _ in
            handleOutputDrop(urls)
        } isTargeted: { targeted in
            isOutputDropTargeted = targeted
        }
    }

    private var formatView: some View {
        VStack(spacing: 10) {
            Text("输出格式")
                .font(.headline)

            Picker("输出格式", selection: $format) {
                ForEach(PSDExportFormat.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)
            .disabled(isProcessing)

            Text(
                format == .jpeg
                    ? "质量 6 · 原尺寸 · sRGB · 嵌入配置文件 · 无元数据"
                    : "原尺寸 · sRGB · 嵌入配置文件 · 无元数据"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var informationView: some View {
        HStack(spacing: 18) {
            informationCard(
                title: "PSD 总数",
                value: "\(imageCount)",
                icon: "doc.on.doc"
            )

            informationCard(
                title: "已有文件",
                value: "\(existingCount)",
                icon: "checkmark.circle"
            )

            informationCard(
                title: "待导出",
                value: "\(max(0, imageCount - existingCount))",
                icon: "square.and.arrow.down"
            )

            informationCard(
                title: "输出规格",
                value: "原尺寸 \(format.rawValue)",
                icon: "aspectratio"
            )
        }
    }

    private func informationCard(
        title: String,
        value: String,
        icon: String
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var inputTitle: String {
        switch source {
        case .folder:
            "已选择输入文件夹"
        case .files(let urls):
            "已选择 \(urls.count) 个 PSD 文件"
        case nil:
            "把 PSD 文件夹或多个 PSD 文件拖到这里"
        }
    }

    private var inputDescription: String {
        switch source {
        case .folder(let url):
            url.path
        case .files(let urls):
            if urls.count == 1 {
                urls[0].path
            } else {
                urls.prefix(3).map(\.lastPathComponent).joined(separator: "、") +
                    (urls.count > 3 ? " 等 \(urls.count) 个文件" : "")
            }
        case nil:
            "文件夹模式会递归查找 PSD；也可以一次选择或拖入多个 PSD"
        }
    }

    // MARK: - 输入输出选择与恢复

    private func restoreRememberedInputFolder() {
        guard source == nil, !rememberedInputFolderPath.isEmpty else {
            return
        }
        let url = URL(
            fileURLWithPath: rememberedInputFolderPath,
            isDirectory: true
        )
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue {
            source = .folder(url)
        }
    }

    private func selectInputFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择 PSD 输入文件夹"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        if case .folder(let currentURL) = source {
            panel.directoryURL = currentURL
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        setInputFolder(url)
    }

    private func selectPSDFiles() {
        let panel = NSOpenPanel()
        panel.title = "选择 PSD 文件"
        panel.prompt = "选择"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "psd") ?? .data
        ]

        guard panel.runModal() == .OK, !panel.urls.isEmpty else {
            return
        }
        setInputFiles(panel.urls)
    }

    private func selectOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择图片输出文件夹"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = outputFolderURL

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        setOutputFolder(url)
    }

    private func handleInputDrop(_ urls: [URL]) -> Bool {
        guard !isProcessing, !urls.isEmpty else {
            return false
        }

        let directories = urls.filter { url in
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey]
            )
            return values?.isDirectory == true
        }

        if urls.count == 1, let folder = directories.first {
            setInputFolder(folder)
            return true
        }

        let psdFiles = urls.filter {
            $0.pathExtension.lowercased() == "psd" &&
            !directories.contains($0)
        }
        guard psdFiles.count == urls.count else {
            showMessage(
                title: "无法选择",
                message: "请拖入一个文件夹，或者只拖入 PSD 文件。"
            )
            return false
        }

        setInputFiles(psdFiles)
        return true
    }

    private func handleOutputDrop(_ urls: [URL]) -> Bool {
        guard !isProcessing, urls.count == 1, let url = urls.first else {
            return false
        }
        let isDirectory = (try? url.resourceValues(
            forKeys: [.isDirectoryKey]
        ))?.isDirectory == true
        guard isDirectory else {
            showMessage(
                title: "无法选择",
                message: "输出位置必须是一个文件夹。"
            )
            return false
        }

        setOutputFolder(url)
        return true
    }

    private func setInputFolder(_ url: URL) {
        source = .folder(url)
        rememberedInputFolderPath = url.path
        refreshCounts()
    }

    private func setInputFiles(_ urls: [URL]) {
        let uniqueFiles = Dictionary(
            urls.map { ($0.standardizedFileURL.path, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        source = .files(uniqueFiles)
        refreshCounts()
    }

    private func setOutputFolder(_ url: URL) {
        outputFolderPath = url.path
        refreshCounts()
    }

    // MARK: - 数量预览与批量导出

    private func refreshCounts() {
        guard let source else {
            imageCount = 0
            existingCount = 0
            statusMessage = "请选择 PSD 文件或输入文件夹"
            return
        }

        do {
            if let outputFolderURL {
                let result = try PSDExportProcessor.scan(
                    source: source,
                    outputFolder: outputFolderURL,
                    format: format
                )
                imageCount = result.totalCount
                existingCount = result.skippedCount
                statusMessage =
                    "发现 \(result.totalCount) 个 PSD，其中 \(result.skippedCount) 个已有同名 \(format.rawValue)"
            } else {
                imageCount = try PSDExportProcessor.sourceCount(for: source)
                existingCount = 0
                statusMessage = "发现 \(imageCount) 个 PSD，请选择输出文件夹"
            }
        } catch {
            imageCount = 0
            existingCount = 0
            statusMessage = error.localizedDescription
        }
    }

    private func startExport() {
        guard let source, let outputFolderURL else {
            return
        }

        let selectedFormat = format
        isProcessing = true
        progress = 0
        statusMessage = "正在扫描 PSD 文件……"

        Task {
            // 在整批导出期间保持源文件与输出目录的安全范围访问，并在结束时释放。
            let accessURLs = source.accessURLs + [outputFolderURL]
            let accessedURLs = accessURLs.filter {
                $0.startAccessingSecurityScopedResource()
            }
            defer {
                accessedURLs.forEach {
                    $0.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let scanResult = try PSDExportProcessor.scan(
                    source: source,
                    outputFolder: outputFolderURL,
                    format: selectedFormat
                )

                if scanResult.jobs.isEmpty {
                    finishExport(
                        successCount: 0,
                        skippedCount: scanResult.skippedCount,
                        failureMessages: []
                    )
                    return
                }

                var successCount = 0
                var failureMessages: [String] = []

                for (index, job) in scanResult.jobs.enumerated() {
                    do {
                        // 每次只解码一张 PSD，并及时释放临时图像对象，控制批量导出内存。
                        try await Task.detached(priority: .userInitiated) {
                            try autoreleasepool {
                                try PSDExportProcessor.export(job)
                            }
                        }.value
                        successCount += 1
                    } catch {
                        failureMessages.append(
                            "\(job.sourceURL.lastPathComponent)：\(error.localizedDescription)"
                        )
                    }

                    progress = Double(index + 1) /
                        Double(scanResult.jobs.count)
                    statusMessage =
                        "正在导出 \(index + 1) / \(scanResult.jobs.count)"
                }

                finishExport(
                    successCount: successCount,
                    skippedCount: scanResult.skippedCount,
                    failureMessages: failureMessages
                )
            } catch {
                isProcessing = false
                showMessage(
                    title: "导出失败",
                    message: error.localizedDescription
                )
            }
        }
    }

    // MARK: - 结果汇总与提示

    private func finishExport(
        successCount: Int,
        skippedCount: Int,
        failureMessages: [String]
    ) {
        isProcessing = false
        progress = 1
        refreshCounts()

        var message =
            "成功导出 \(successCount) 张。\n" +
            "跳过已有文件 \(skippedCount) 张。\n" +
            "失败 \(failureMessages.count) 张。"

        if !failureMessages.isEmpty {
            message += "\n\n失败文件：\n" +
                failureMessages.prefix(8).joined(separator: "\n")
            if failureMessages.count > 8 {
                message += "\n……以及另外 \(failureMessages.count - 8) 张"
            }
        }

        statusMessage =
            "完成：导出 \(successCount) 张，跳过 \(skippedCount) 张"
        playCompletionSound()
        showMessage(title: "PSD 导出完成", message: message)
    }

    private func playCompletionSound() {
        guard let soundURL = Bundle.main.url(
            forResource: "complete",
            withExtension: "m4a"
        ) else {
            return
        }
        completionSound = NSSound(contentsOf: soundURL, byReference: true)
        completionSound?.play()
    }

    private func showMessage(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}

#Preview {
    PSDExportView()
}
