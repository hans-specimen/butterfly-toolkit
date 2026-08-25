import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum SmartCropOutputMode: String, CaseIterable, Identifiable {
    case folder = "保存到文件夹"
    case overwrite = "覆盖源文件"
    var id: String { rawValue }
}

struct SmartCropView: View {
    @State private var inputDescription = "尚未选择图片"
    @State private var imageURLs: [URL] = []
    @State private var outputFolderURL: URL?
    @State private var isDropTargeted = false

    @State private var selectedRatio: CropRatio = .fiveFour
    @State private var preferredPadding = 0.10
    @State private var autoStraighten = true
    @State private var outputMode: SmartCropOutputMode = .folder

    @State private var previewIndex = 0
    @State private var previewImage: NSImage?
    @State private var croppedPreviewImage: NSImage?
    @State private var previewStatus = "请选择 JPEG 图片"
    @State private var previewGeneration = UUID()
    @State private var isLoadingPreview = false

    @State private var isProcessing = false
    @State private var progress = 0.0
    @State private var processedCount = 0
    @State private var successCount = 0
    @State private var skippedCount = 0
    @State private var failedCount = 0
    @State private var processingLogs: [String] = []
    @State private var cancellationToken: CropCancellationToken?

    @State private var showOverwriteConfirmation = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    private let cropProcessor = ButterflyCropProcessor()

    var body: some View {
        HStack(spacing: 0) {
            leftSidebar
            Divider()
            rightContent
        }
        .frame(minWidth: 1_000, minHeight: 720)
        .onChange(of: selectedRatio) { refreshPreview() }
        .onChange(of: preferredPadding) { refreshPreview() }
        .onChange(of: autoStraighten) { refreshPreview() }
        .alert("无法使用所选内容", isPresented: $showErrorAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .alert("确认覆盖源文件？", isPresented: $showOverwriteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("覆盖并开始", role: .destructive) {
                beginProcessing()
            }
        } message: {
            Text("将原子替换所选的 \(imageURLs.count) 张 JPEG。处理失败时原文件保持不变，此操作不会另建备份。")
        }
    }

    private var leftSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                inputSection
                Divider()
                cropSettingsSection
                Divider()
                outputSection
                startButton
            }
            .padding(20)
        }
        .frame(width: 350)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("输入")
            dropArea
            Text(inputDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            if !imageURLs.isEmpty {
                Text("共 \(imageURLs.count) 张 JPEG")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dropArea: some View {
        VStack(spacing: 10) {
            Image(systemName: imageURLs.isEmpty ? "photo.on.rectangle.angled" : "photo.stack.fill")
                .font(.system(size: 26))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)

            Text(imageURLs.isEmpty ? "拖入文件夹或若干 JPEG" : "可拖入其他图片重新选择")
                .font(.headline)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                Button(action: chooseInputFolder) {
                    Label("文件夹", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                Button(action: chooseInputImages) {
                    Label("图片", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isProcessing)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6])
                )
        }
        .dropDestination(for: URL.self) { urls, _ in
            receiveDroppedURLs(urls)
        } isTargeted: { isDropTargeted = $0 }
    }

    private var cropSettingsSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            sectionTitle("裁剪设置")

            VStack(alignment: .leading, spacing: 8) {
                Text("比例")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Picker("裁剪比例", selection: $selectedRatio) {
                    ForEach(CropRatio.allCases) { ratio in
                        Text(ratio.rawValue).tag(ratio)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(isProcessing)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("期望留白")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Text("\(Int(preferredPadding * 100))%")
                        .font(.subheadline)
                        .monospacedDigit()
                }
                Slider(value: $preferredPadding, in: 0.02...0.25, step: 0.01)
                    .disabled(isProcessing)
                Text("空间不足时减少留白；无法保全蝴蝶时跳过。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("自动旋转扶正（最多 ±10°）", isOn: $autoStraighten)
                .font(.subheadline)
                .fontWeight(.medium)
                .disabled(isProcessing)
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("输出")
            Picker("输出方式", selection: $outputMode) {
                ForEach(SmartCropOutputMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isProcessing)

            if outputMode == .folder {
                Button(action: chooseOutputFolder) {
                    Label(
                        outputFolderURL == nil ? "选择输出文件夹" : "更改输出文件夹",
                        systemImage: "folder"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isProcessing)

                if let outputFolderURL {
                    Text(outputFolderURL.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
            } else {
                Label("开始前会再次确认，失败时原图不变。", systemImage: "exclamationmark.shield")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var startButton: some View {
        Button {
            if isProcessing {
                cancellationToken?.cancel()
                processingLogs.append("正在等待当前图片完成后取消……")
            } else if outputMode == .overwrite {
                showOverwriteConfirmation = true
            } else {
                beginProcessing()
            }
        } label: {
            HStack {
                if isProcessing {
                    Image(systemName: "stop.fill")
                    Text("取消处理")
                } else {
                    Image(systemName: "play.fill")
                    Text("开始智能裁剪")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(isProcessing ? .red : .accentColor)
        .controlSize(.large)
        .disabled(
            !isProcessing && (
                imageURLs.isEmpty ||
                (outputMode == .folder && outputFolderURL == nil)
            )
        )
    }

    private var rightContent: some View {
        VStack(spacing: 14) {
            previewSection
            progressSection
            logSection
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("预览效果")
                    .font(.headline)
                Text("（\(selectedRatio.rawValue)）")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                if !imageURLs.isEmpty {
                    Button { movePreview(by: -1) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(previewIndex == 0 || isLoadingPreview)
                    Text("\(previewIndex + 1) / \(imageURLs.count)")
                        .font(.caption)
                        .monospacedDigit()
                    Button { movePreview(by: 1) } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(previewIndex >= imageURLs.count - 1 || isLoadingPreview)
                }
            }

            HStack(spacing: 16) {
                previewCard(title: "原图", image: previewImage, emptyText: "请选择 JPEG")
                Image(systemName: "arrow.right")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.secondary)
                previewCard(
                    title: "裁剪后",
                    image: croppedPreviewImage,
                    emptyText: isLoadingPreview ? "正在分析主体……" : "等待预览"
                )
            }

            HStack(spacing: 8) {
                if isLoadingPreview { ProgressView().controlSize(.small) }
                Text(previewStatus)
                    .font(.caption)
                    .foregroundStyle(croppedPreviewImage == nil && !imageURLs.isEmpty ? .orange : .secondary)
                    .lineLimit(2)
                Spacer()
                if !imageURLs.isEmpty {
                    Text(imageURLs[previewIndex].lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(16)
        .background(cardBackground(cornerRadius: 12))
        .frame(maxHeight: .infinity)
    }

    private func previewCard(title: String, image: NSImage?, emptyText: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.subheadline).fontWeight(.semibold)
            ZStack {
                Rectangle().fill(Color.black.opacity(0.035))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    VStack(spacing: 9) {
                        Image(systemName: "photo")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text(emptyText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .overlay(Rectangle().stroke(Color.secondary.opacity(0.18)))
            .aspectRatio(selectedRatio.value, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 410)
        }
        .frame(maxWidth: .infinity)
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("处理进度").font(.headline)
                Spacer()
                Text("成功 \(successCount)  跳过 \(skippedCount)  失败 \(failedCount)")
                    .font(.caption)
                Text("\(processedCount) / \(imageURLs.count)")
                    .font(.caption)
                    .monospacedDigit()
                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
            ProgressView(value: progress)
            Text(isProcessing ? "正在逐张处理，源文件仅在成功后替换。" : progressMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(cardBackground(cornerRadius: 10))
    }

    private var progressMessage: String {
        if processedCount == 0 { return "尚未开始处理" }
        return "处理完成：成功 \(successCount)，跳过 \(skippedCount)，失败 \(failedCount)。"
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("处理日志").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if processingLogs.isEmpty {
                        Text("处理记录将在这里显示")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(processingLogs.enumerated()), id: \.offset) { _, log in
                            Text(log)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(height: 150)
        .background(cardBackground(cornerRadius: 10))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.headline)
    }

    private func cardBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.secondary.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.secondary.opacity(0.15))
            )
    }

    // MARK: - Input

    private func chooseInputFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择包含 JPEG 的文件夹"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectFolder(url)
    }

    private func chooseInputImages() {
        let panel = NSOpenPanel()
        panel.title = "选择 JPEG 图片"
        panel.prompt = "选择"
        panel.allowedContentTypes = [.jpeg]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        selectImages(panel.urls)
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择输出文件夹"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { outputFolderURL = panel.url }
    }

    private func receiveDroppedURLs(_ urls: [URL]) -> Bool {
        guard !isProcessing, !urls.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        if urls.count == 1,
           FileManager.default.fileExists(
            atPath: urls[0].path,
            isDirectory: &isDirectory
           ), isDirectory.boolValue {
            selectFolder(urls[0])
            return true
        }
        guard urls.allSatisfy({ isJPEG($0) && !$0.hasDirectoryPath }) else {
            presentInputError("请拖入一个文件夹，或只拖入 JPG、JPEG 图片；不能混合文件夹和图片。")
            return false
        }
        selectImages(urls)
        return true
    }

    private func selectFolder(_ folder: URL) {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .filter(isJPEG)
            .sorted(by: standardURLSort)
            guard !files.isEmpty else {
                presentInputError("该文件夹当前层没有 JPG、JPEG 图片。")
                return
            }
            applyInput(
                files,
                description: folder.path,
                defaultOutput: folder.deletingLastPathComponent()
                    .appendingPathComponent(folder.lastPathComponent + "_智能裁剪")
            )
        } catch {
            presentInputError("无法读取该文件夹：\(error.localizedDescription)")
        }
    }

    private func selectImages(_ urls: [URL]) {
        let files = Array(Set(urls.filter(isJPEG))).sorted(by: standardURLSort)
        guard !files.isEmpty else {
            presentInputError("没有可处理的 JPG、JPEG 图片。")
            return
        }
        let parent = files[0].deletingLastPathComponent()
        applyInput(
            files,
            description: "已选择 \(files.count) 张图片",
            defaultOutput: parent.appendingPathComponent("智能裁剪输出")
        )
    }

    private func applyInput(_ files: [URL], description: String, defaultOutput: URL) {
        imageURLs = files
        inputDescription = description
        outputFolderURL = defaultOutput
        previewIndex = 0
        resetProgress()
        refreshPreview()
    }

    private func isJPEG(_ url: URL) -> Bool {
        ButterflyCropProcessor.supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private func standardURLSort(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }

    private func presentInputError(_ message: String) {
        errorMessage = message
        showErrorAlert = true
    }

    // MARK: - Preview

    private func movePreview(by offset: Int) {
        previewIndex = min(max(0, previewIndex + offset), imageURLs.count - 1)
        refreshPreview()
    }

    private func refreshPreview() {
        let generation = UUID()
        previewGeneration = generation
        guard imageURLs.indices.contains(previewIndex) else {
            previewImage = nil
            croppedPreviewImage = nil
            previewStatus = "请选择 JPEG 图片"
            return
        }
        let sourceURL = imageURLs[previewIndex]
        previewImage = NSImage(contentsOf: sourceURL)
        croppedPreviewImage = nil
        previewStatus = "正在识别主体并计算裁剪范围……"
        isLoadingPreview = true
        let options = currentOptions

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Result<(NSImage, CropAnalysis), Error>
            do {
                outcome = .success(
                    try cropProcessor.renderPreview(
                        sourceURL: sourceURL,
                        options: options
                    )
                )
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async {
                guard previewGeneration == generation else { return }
                isLoadingPreview = false
                switch outcome {
                case .success(let result):
                    croppedPreviewImage = result.0
                    let analysis = result.1
                    previewStatus = String(
                        format: "预计扶正 %+.1f° · 实际留白 %.0f%% · 主体完整",
                        analysis.rotationDegrees,
                        analysis.actualPadding * 100
                    )
                case .failure(let error):
                    croppedPreviewImage = nil
                    previewStatus = "跳过：\(error.localizedDescription)"
                }
            }
        }
    }

    private var currentOptions: CropOptions {
        CropOptions(
            ratio: selectedRatio,
            preferredPadding: preferredPadding,
            autoStraighten: autoStraighten
        )
    }

    // MARK: - Batch processing

    private func beginProcessing() {
        guard !imageURLs.isEmpty else { return }
        guard outputMode == .overwrite || outputFolderURL != nil else {
            presentInputError("请先选择输出文件夹。")
            return
        }
        resetProgress()
        isProcessing = true
        processingLogs = ["准备处理 \(imageURLs.count) 张图片。"]
        let files = imageURLs
        let destinationFolder = outputFolderURL
        let overwrite = outputMode == .overwrite
        let options = currentOptions
        let token = CropCancellationToken()
        cancellationToken = token

        DispatchQueue.global(qos: .userInitiated).async {
            for (index, sourceURL) in files.enumerated() {
                if token.isCancelled { break }
                autoreleasepool {
                    let destinationURL = overwrite
                        ? sourceURL
                        : destinationFolder!.appendingPathComponent(sourceURL.lastPathComponent)
                    do {
                        let result = try cropProcessor.process(
                            sourceURL: sourceURL,
                            destinationURL: destinationURL,
                            overwriteSource: overwrite,
                            options: options
                        )
                        let angle = result.analysis.rotationDegrees
                        let padding = result.analysis.actualPadding * 100
                        updateBatchProgress(
                            index: index,
                            total: files.count,
                            kind: .success,
                            log: String(
                                format: "✓ %@ · 扶正 %+.1f° · 留白 %.0f%%",
                                sourceURL.lastPathComponent,
                                angle,
                                padding
                            )
                        )
                    } catch let reason as CropFailureReason {
                        let isFailure = reason == .cannotReadImage
                            || reason == .cannotReadMetadata
                            || reason == .cannotCreateImage
                            || reason == .cannotWriteImage
                        updateBatchProgress(
                            index: index,
                            total: files.count,
                            kind: isFailure ? .failure : .skipped,
                            log: "\(isFailure ? "✕" : "–") \(sourceURL.lastPathComponent) · \(reason.localizedDescription)"
                        )
                    } catch {
                        updateBatchProgress(
                            index: index,
                            total: files.count,
                            kind: .failure,
                            log: "✕ \(sourceURL.lastPathComponent) · \(error.localizedDescription)"
                        )
                    }
                }
            }
            DispatchQueue.main.async {
                let cancelled = token.isCancelled
                isProcessing = false
                cancellationToken = nil
                if cancelled {
                    processingLogs.append("已取消，未开始的图片保持不变。")
                } else {
                    progress = 1
                    processingLogs.append("处理结束：成功 \(successCount)，跳过 \(skippedCount)，失败 \(failedCount)。")
                }
            }
        }
    }

    private enum BatchProgressKind { case success, skipped, failure }

    private func updateBatchProgress(
        index: Int,
        total: Int,
        kind: BatchProgressKind,
        log: String
    ) {
        DispatchQueue.main.async {
            processedCount = index + 1
            progress = Double(processedCount) / Double(total)
            switch kind {
            case .success: successCount += 1
            case .skipped: skippedCount += 1
            case .failure: failedCount += 1
            }
            processingLogs.append(log)
        }
    }

    private func resetProgress() {
        progress = 0
        processedCount = 0
        successCount = 0
        skippedCount = 0
        failedCount = 0
        processingLogs = []
    }
}

#Preview {
    SmartCropView()
}
