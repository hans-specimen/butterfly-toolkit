import AppKit
import SwiftUI

struct TransparentPNGTrimView: View {
    private static let defaultInputPath =
        "/Users/hans/SynologyDrive/Butterfly/_butterfly_photos/02 - PNG_4K"
    private static let defaultOutputPath =
        "/Users/hans/SynologyDrive/Butterfly/_butterfly_photos/06 - PNG素材"

    @AppStorage("transparentPNGTrim.inputFolderPath")
    private var inputFolderPath = defaultInputPath
    @AppStorage("transparentPNGTrim.outputFolderPath")
    private var outputFolderPath = defaultOutputPath

    @State private var scanResult: TransparentPNGTrimScanResult?
    @State private var isProcessing = false
    @State private var progress = 0.0
    @State private var processedCount = 0
    @State private var processingTotal = 0
    @State private var currentFileName = "尚未开始"
    @State private var statusMessage = "准备裁切透明 PNG"
    @State private var showConfirmation = false
    @State private var showAlert = false
    @State private var alertTitle = "提示"
    @State private var alertMessage = ""
    @State private var completionSound: NSSound?

    private var inputFolderURL: URL {
        URL(fileURLWithPath: inputFolderPath, isDirectory: true)
    }
    private var outputFolderURL: URL {
        URL(fileURLWithPath: outputFolderPath, isDirectory: true)
    }

    var body: some View {
        VStack(spacing: 24) {
            headerView
            VStack(spacing: 14) {
                folderRow(
                    title: "输入文件夹",
                    path: inputFolderPath,
                    icon: "folder.badge.gearshape",
                    selectAction: { selectFolder(isInput: true) },
                    openAction: { NSWorkspace.shared.open(inputFolderURL) }
                )
                folderRow(
                    title: "输出文件夹",
                    path: outputFolderPath,
                    icon: "folder.fill.badge.plus",
                    selectAction: { selectFolder(isInput: false) },
                    openAction: { NSWorkspace.shared.open(outputFolderURL) }
                )
            }
            .frame(maxWidth: 900)

            informationView

            processingProgressView

            Button {
                showConfirmation = true
            } label: {
                if isProcessing {
                    ProgressView().controlSize(.small).frame(width: 220)
                } else {
                    Label("同步目录并开始裁切", systemImage: "crop")
                        .frame(width: 220)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isProcessing || scanResult?.totalCount == 0)

            Text(statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
        }
        .padding(34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: refreshScan)
        .alert("确认同步输出目录？", isPresented: $showConfirmation) {
            Button("取消", role: .cancel) {}
            Button("同步并开始", role: .destructive, action: startProcessing)
        } message: {
            Text(confirmationMessage)
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private var headerView: some View {
        VStack(spacing: 8) {
            Image(systemName: "crop").font(.system(size: 54))
            Text("透明 PNG 主体裁切").font(.largeTitle).bold()
            Text("移除蝴蝶四周的全透明像素，并镜像输入目录结构")
                .foregroundStyle(.secondary)
        }
    }

    private var informationView: some View {
        HStack(spacing: 16) {
            informationCard(title: "PNG 总数", value: "\(scanResult?.totalCount ?? 0)", icon: "photo.stack")
            informationCard(title: "已有文件", value: "\(scanResult?.skippedCount ?? 0)", icon: "checkmark.circle")
            informationCard(title: "待裁切", value: "\(scanResult?.jobs.count ?? 0)", icon: "crop")
            informationCard(title: "待新建目录", value: "\(scanResult?.missingDirectoryCount ?? 0)", icon: "folder.badge.plus")
            informationCard(title: "待删除目录", value: "\(scanResult?.extraDirectoryCount ?? 0)", icon: "folder.badge.minus")
        }
        .frame(maxWidth: 900)
    }

    private var confirmationMessage: String {
        let missing = scanResult?.missingDirectoryCount ?? 0
        let extra = scanResult?.extraDirectoryCount ?? 0
        return "将新建 \(missing) 个缺失子文件夹，并删除 \(extra) 个输入目录中不存在的输出子文件夹及其内容。已有同名输出 PNG 会跳过，PSD 不会被读取或复制。"
    }

    private var processingProgressView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("处理进度", systemImage: "chart.bar.fill")
                    .font(.headline)
                Spacer()
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }

            ProgressView(value: progress, total: 1)
                .progressViewStyle(.linear)
                .tint(isProcessing ? .accentColor : (progress >= 1 ? .green : .secondary))

            HStack {
                Text("已完成 \(processedCount) / \(processingTotal)")
                    .monospacedDigit()
                Spacer()
                Text(currentFileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: 900)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("处理进度 \(Int((progress * 100).rounded()))%，已完成 \(processedCount) 张，共 \(processingTotal) 张")
    }

    private func folderRow(
        title: String,
        path: String,
        icon: String,
        selectAction: @escaping () -> Void,
        openAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title2).frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("打开", action: openAction).disabled(isProcessing)
            Button("更改…", action: selectAction).disabled(isProcessing)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }

    private func informationCard(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.headline).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private func selectFolder(isInput: Bool) {
        let panel = NSOpenPanel()
        panel.title = isInput ? "选择透明 PNG 输入文件夹" : "选择 PNG 素材输出文件夹"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = !isInput
        panel.directoryURL = isInput ? inputFolderURL : outputFolderURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if isInput { inputFolderPath = url.path } else { outputFolderPath = url.path }
        refreshScan()
    }

    private func refreshScan() {
        do {
            let result = try TransparentPNGTrimProcessor.scan(
                inputFolder: inputFolderURL,
                outputFolder: outputFolderURL
            )
            scanResult = result
            statusMessage = "发现 \(result.totalCount) 张 PNG，待裁切 \(result.jobs.count) 张，已有 \(result.skippedCount) 张"
        } catch {
            scanResult = nil
            statusMessage = error.localizedDescription
        }
    }

    private func startProcessing() {
        isProcessing = true
        progress = 0
        processedCount = 0
        processingTotal = scanResult?.jobs.count ?? 0
        currentFileName = "正在同步目录结构……"
        statusMessage = "正在同步输出目录结构……"
        let input = inputFolderURL
        let output = outputFolderURL

        Task {
            do {
                let syncResult = try await Task.detached(priority: .userInitiated) {
                    try TransparentPNGTrimProcessor.synchronizeDirectories(
                        inputFolder: input,
                        outputFolder: output
                    )
                }.value
                let result = try TransparentPNGTrimProcessor.scan(
                    inputFolder: input,
                    outputFolder: output
                )
                processingTotal = result.jobs.count
                var successCount = 0
                var failures: [String] = []

                for (index, job) in result.jobs.enumerated() {
                    currentFileName = job.sourceURL.lastPathComponent
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try TransparentPNGTrimProcessor.trim(job)
                        }.value
                        successCount += 1
                    } catch {
                        failures.append("\(job.sourceURL.lastPathComponent)：\(error.localizedDescription)")
                    }
                    processedCount = index + 1
                    progress = Double(processedCount) / Double(max(1, processingTotal))
                    statusMessage = "正在裁切 \(processedCount) / \(processingTotal)（\(Int((progress * 100).rounded()))%）"
                }

                isProcessing = false
                progress = 1
                processedCount = processingTotal
                currentFileName = failures.isEmpty ? "处理完成" : "处理完成，部分文件失败"
                refreshScan()
                playCompletionSound()
                var message = "新建目录 \(syncResult.createdCount) 个，删除目录 \(syncResult.removedCount) 个。\n成功裁切 \(successCount) 张，跳过已有文件 \(result.skippedCount) 张，失败 \(failures.count) 张。"
                if !failures.isEmpty {
                    message += "\n\n失败文件：\n" + failures.prefix(8).joined(separator: "\n")
                }
                showMessage(title: "透明 PNG 裁切完成", message: message)
            } catch {
                isProcessing = false
                currentFileName = "处理已中止"
                showMessage(title: "处理失败", message: error.localizedDescription)
            }
        }
    }

    private func playCompletionSound() {
        guard let url = Bundle.main.url(forResource: "complete", withExtension: "m4a") else { return }
        completionSound = NSSound(contentsOf: url, byReference: true)
        completionSound?.play()
    }

    private func showMessage(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}

#Preview { TransparentPNGTrimView() }
