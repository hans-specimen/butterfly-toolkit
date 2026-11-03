import SwiftUI
import AppKit

struct XianyuProductView: View {
    private static let defaultInputPath =
        "/Users/hans/SynologyDrive/Butterfly/_butterfly_photos/02 - PNG_4K"
    private static let defaultOutputPath =
        "/Users/hans/SynologyDrive/Butterfly/_butterfly_photos/03 - 白底商品图"
    @AppStorage("xianyuProduct.inputFolderPath")
    private var inputFolderPath = defaultInputPath

    @AppStorage("xianyuProduct.outputFolderPath")
    private var outputFolderPath = defaultOutputPath

    @State private var imageCount = 0
    @State private var existingCount = 0
    @State private var isProcessing = false
    @State private var progress: Double = 0
    @State private var statusMessage = "准备生成闲鱼产品图"

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

    private var watermarkURL: URL? {
        Bundle.main.url(
            forResource: "mark",
            withExtension: "png"
        )
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
                    openAction: { openFolder(inputFolderURL) }
                )

                folderRow(
                    title: "输出文件夹",
                    path: outputFolderPath,
                    icon: "folder.fill.badge.plus",
                    selectAction: { selectFolder(isInput: false) },
                    openAction: { openFolder(outputFolderURL) }
                )
            }
            .frame(maxWidth: 820)

            informationView

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
                startGeneration()
            } label: {
                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 190)
                } else {
                    Label(
                        "生成产品图",
                        systemImage: "wand.and.stars"
                    )
                    .frame(width: 190)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isProcessing || imageCount == 0)

            Text(statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .padding(34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            refreshCounts()
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private var headerView: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 54))

            Text("闲鱼产品图")
                .font(.largeTitle)
                .bold()

            Text("批量生成 2000 × 2000 灰底水印商品图")
                .foregroundStyle(.secondary)
        }
    }

    private func folderRow(
        title: String,
        path: String,
        icon: String,
        selectAction: @escaping () -> Void,
        openAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer()

            Button("打开", action: openAction)
                .disabled(isProcessing)

            Button("更改…", action: selectAction)
                .disabled(isProcessing)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var informationView: some View {
        HStack(spacing: 18) {
            informationCard(
                title: "PNG 总数",
                value: "\(imageCount)",
                icon: "photo.stack"
            )

            informationCard(
                title: "已有文件",
                value: "\(existingCount)",
                icon: "checkmark.circle"
            )

            informationCard(
                title: "待生成",
                value: "\(max(0, imageCount - existingCount))",
                icon: "sparkles"
            )

            informationCard(
                title: "输出规格",
                value: "2000 × 2000 PNG",
                icon: "square.resize"
            )
        }
        .frame(maxWidth: 820)
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

    private func selectFolder(isInput: Bool) {
        let panel = NSOpenPanel()
        panel.title = isInput ? "选择 PNG 输入文件夹" : "选择产品图输出文件夹"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = !isInput
        panel.directoryURL = isInput ? inputFolderURL : outputFolderURL

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        if isInput {
            inputFolderPath = url.path
        } else {
            outputFolderPath = url.path
        }

        refreshCounts()
    }

    private func refreshCounts() {
        do {
            let result = try XianyuProductProcessor.scan(
                inputFolder: inputFolderURL,
                outputFolder: outputFolderURL
            )
            imageCount = result.totalCount
            existingCount = result.skippedCount

            if result.totalCount == 0 {
                statusMessage = "输入文件夹中没有找到 PNG 图片"
            } else {
                statusMessage =
                    "发现 \(result.totalCount) 张 PNG，其中 \(result.skippedCount) 张已有产品图"
            }
        } catch {
            imageCount = 0
            existingCount = 0
            statusMessage = error.localizedDescription
        }
    }

    private func startGeneration() {
        guard inputFolderURL.standardizedFileURL !=
                outputFolderURL.standardizedFileURL else {
            showMessage(
                title: "文件夹设置错误",
                message: "输入文件夹和输出文件夹不能相同。"
            )
            return
        }

        isProcessing = true
        progress = 0
        statusMessage = "正在扫描 PNG 图片……"

        Task {
            do {
                let scanResult = try XianyuProductProcessor.scan(
                    inputFolder: inputFolderURL,
                    outputFolder: outputFolderURL
                )
                guard let watermarkURL else {
                    throw XianyuProductError.invalidWatermark
                }

                let watermark = try XianyuProductProcessor.loadWatermark(
                    from: watermarkURL
                )

                if scanResult.jobs.isEmpty {
                    finishGeneration(
                        successCount: 0,
                        skippedCount: scanResult.skippedCount,
                        failureNames: []
                    )
                    return
                }

                var successCount = 0
                var failureNames: [String] = []

                for (index, job) in scanResult.jobs.enumerated() {
                    do {
                        try XianyuProductProcessor.createProductImage(
                            sourceURL: job.sourceURL,
                            destinationURL: job.destinationURL,
                            watermark: watermark
                        )
                        successCount += 1
                    } catch {
                        failureNames.append(job.sourceURL.lastPathComponent)
                    }

                    progress = Double(index + 1) /
                        Double(scanResult.jobs.count)
                    statusMessage =
                        "正在处理 \(index + 1) / \(scanResult.jobs.count)"

                    await Task.yield()
                }

                finishGeneration(
                    successCount: successCount,
                    skippedCount: scanResult.skippedCount,
                    failureNames: failureNames
                )
            } catch {
                isProcessing = false
                showMessage(
                    title: "生成失败",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func finishGeneration(
        successCount: Int,
        skippedCount: Int,
        failureNames: [String]
    ) {
        isProcessing = false
        progress = 1
        refreshCounts()

        var message =
            "成功生成 \(successCount) 张。\n" +
            "跳过已有文件 \(skippedCount) 张。\n" +
            "失败 \(failureNames.count) 张。"

        if !failureNames.isEmpty {
            message += "\n\n失败文件：\n" +
                failureNames.prefix(8).joined(separator: "\n")

            if failureNames.count > 8 {
                message += "\n……以及另外 \(failureNames.count - 8) 张"
            }
        }

        statusMessage =
            "完成：生成 \(successCount) 张，跳过 \(skippedCount) 张"
        playCompletionSound()
        showMessage(title: "产品图生成完成", message: message)
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

    private func openFolder(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func showMessage(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}

#Preview {
    XianyuProductView()
}
