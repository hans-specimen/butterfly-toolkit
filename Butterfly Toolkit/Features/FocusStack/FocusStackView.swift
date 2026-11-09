// 展示原图与命名清单的景深合成分组，协调 Photoshop 逐组生成 PSD 并反馈进度。

import AppKit
import SwiftUI

struct FocusStackView: View {
    @AppStorage("focusStack.inputFolderPath")
    private var inputFolderPath = "/Users/hans/SynologyDrive/Butterfly/_Original_Sony/260820"
    @AppStorage("focusStack.outputFolderPath")
    private var outputFolderPath = ""
    @AppStorage("focusStack.namesText")
    private var namesText = ""

    @State private var plan: FocusStackPlan?
    @State private var validationMessage = "请选择文件夹并粘贴名称清单"
    @State private var isProcessing = false
    @State private var progress = 0.0
    @State private var completedCount = 0
    @State private var processingTotal = 0
    @State private var currentFileName = "尚未开始"
    @State private var showConfirmation = false
    @State private var showAlert = false
    @State private var alertTitle = "提示"
    @State private var alertMessage = ""
    @State private var completionSound: NSSound?

    private var inputFolderURL: URL {
        URL(fileURLWithPath: inputFolderPath, isDirectory: true)
    }

    private var outputFolderURL: URL? {
        guard !outputFolderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: outputFolderPath, isDirectory: true)
    }

    // MARK: - 页面布局

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerView
                folderRows
                namesEditor
                informationView
                previewView
                progressView

                Button {
                    showConfirmation = true
                } label: {
                    if isProcessing {
                        ProgressView().controlSize(.small).frame(width: 220)
                    } else {
                        Label("启动 Photoshop 并处理", systemImage: "play.fill")
                            .frame(width: 220)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isProcessing || plan?.pendingJobs.isEmpty != false)

                Text(validationMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
            .padding(34)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            if outputFolderPath.isEmpty, !inputFolderPath.isEmpty {
                outputFolderPath = inputFolderPath
            }
            refreshPlan()
        }
        .onChange(of: namesText) { refreshPlan() }
        .alert("确认开始景深合成？", isPresented: $showConfirmation) {
            Button("取消", role: .cancel) {}
            Button("开始处理", action: startProcessing)
        } message: {
            Text("Photoshop 将依次处理 \(plan?.pendingJobs.count ?? 0) 个 PSD。处理期间请不要在 Photoshop 中进行其他操作；已有同名 PSD 会自动跳过。")
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
            Image(systemName: "square.3.layers.3d").font(.system(size: 54))
            Text("景深合成 PSD").font(.largeTitle).bold()
            Text("每 6 张照片对应一只蝴蝶，前三张生成 D，后三张生成 V")
                .foregroundStyle(.secondary)
        }
    }

    private var folderRows: some View {
        VStack(spacing: 12) {
            folderRow(title: "索尼原图文件夹", path: inputFolderPath, isInput: true)
            folderRow(title: "PSD 输出文件夹", path: outputFolderPath, isInput: false)
        }
        .frame(maxWidth: 900)
    }

    private func folderRow(title: String, path: String, isInput: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: isInput ? "photo.stack" : "folder.fill.badge.plus")
                .font(.title2).frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(path.isEmpty ? "尚未选择" : path)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer()
            if !path.isEmpty {
                Button("打开") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
                }
                .disabled(isProcessing)
            }
            Button("选择…") { selectFolder(isInput: isInput) }
                .disabled(isProcessing)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }

    private var namesEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("PSD 名称清单", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Spacer()
                Text("每行一只蝴蝶，不要填写 _D、_V 或 .psd")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $namesText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 150, maxHeight: 230)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                .disabled(isProcessing)
        }
        .padding(16)
        .frame(maxWidth: 900)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }

    private var informationView: some View {
        HStack(spacing: 14) {
            infoCard("照片", value: plan?.imageCount ?? 0, icon: "photo.on.rectangle.angled")
            infoCard("蝴蝶", value: plan?.butterflyCount ?? 0, icon: "ladybug")
            infoCard("PSD 总数", value: plan?.jobs.count ?? 0, icon: "doc.on.doc")
            infoCard("已有跳过", value: plan?.skippedCount ?? 0, icon: "forward.end")
            infoCard("待处理", value: plan?.pendingJobs.count ?? 0, icon: "hourglass")
        }
        .frame(maxWidth: 900)
    }

    private func infoCard(_ title: String, value: Int, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text("\(value)").font(.headline).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity).padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder private var previewView: some View {
        if let jobs = plan?.jobs.prefix(6), !jobs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("分组预览（按文件名自然排序）", systemImage: "eye")
                    .font(.headline)
                ForEach(Array(jobs)) { job in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(job.destinationURL.lastPathComponent)
                            .fontWeight(.medium).frame(width: 280, alignment: .leading)
                            .lineLimit(1).truncationMode(.middle)
                        Text("← " + job.sourceSummary)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            .padding(16).frame(maxWidth: 900, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
        }
    }

    @ViewBuilder private var progressView: some View {
        if isProcessing || completedCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("已完成 \(completedCount) / \(processingTotal)").monospacedDigit()
                    Spacer()
                    Text(currentFileName).lineLimit(1).truncationMode(.middle)
                }
                .font(.caption).foregroundStyle(.secondary)
                ProgressView(value: progress)
            }
            .padding(16).frame(maxWidth: 900)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
        }
    }

    // MARK: - 目录选择与分组校验

    private func selectFolder(isInput: Bool) {
        let panel = NSOpenPanel()
        panel.title = isInput ? "选择索尼原图文件夹" : "选择 PSD 输出文件夹"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = !isInput
        panel.allowsMultipleSelection = false
        if !((isInput ? inputFolderPath : outputFolderPath).isEmpty) {
            panel.directoryURL = URL(fileURLWithPath: isInput ? inputFolderPath : outputFolderPath)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if isInput {
            inputFolderPath = url.path
            outputFolderPath = url.path
        } else {
            outputFolderPath = url.path
        }
        refreshPlan()
    }

    private func refreshPlan() {
        guard let outputFolderURL else {
            plan = nil
            validationMessage = "请选择 PSD 输出文件夹"
            return
        }
        do {
            let newPlan = try FocusStackProcessor.makePlan(
                inputFolder: inputFolderURL,
                outputFolder: outputFolderURL,
                namesText: namesText
            )
            plan = newPlan
            validationMessage = "分组检查通过：将生成 \(newPlan.jobs.count) 个 PSD，已有 \(newPlan.skippedCount) 个会跳过"
        } catch {
            plan = nil
            validationMessage = error.localizedDescription
        }
    }

    // MARK: - Photoshop 合成调度

    private func startProcessing() {
        // 执行前重新规划，跳过已生成的 PSD，并阻止无效分组启动。
        refreshPlan()
        guard let jobs = plan?.pendingJobs, !jobs.isEmpty else { return }
        guard let photoshop = FocusStackProcessor.photoshopApplicationName() else {
            showError(FocusStackError.photoshopNotFound)
            return
        }

        isProcessing = true
        progress = 0
        completedCount = 0
        processingTotal = jobs.count
        validationMessage = "正在通过 \(photoshop) 处理，请不要操作 Photoshop……"

        Task {
            var failures: [String] = []
            let owner = UUID()
            for (index, job) in jobs.enumerated() {
                currentFileName = job.destinationURL.lastPathComponent
                do {
                    // 经共享协调器占用 Photoshop，避免其他功能同时操控同一应用。
                    try await PhotoshopExecutionCoordinator.shared.run(owner: owner) {
                        try await Task.detached(priority: .userInitiated) {
                            try FocusStackProcessor.process(job, photoshopApplicationName: photoshop)
                        }.value
                    }
                } catch {
                    // 任一分组失败即停止后续合成，保留此前成功生成的 PSD。
                    failures.append("\(job.destinationURL.lastPathComponent)：\(error.localizedDescription)")
                    break
                }
                completedCount = index + 1
                progress = Double(completedCount) / Double(processingTotal)
            }

            isProcessing = false
            refreshPlan()
            if failures.isEmpty {
                validationMessage = "处理完成，共生成 \(completedCount) 个 PSD"
                playCompletionSound()
            } else {
                alertTitle = "处理已停止"
                alertMessage = failures.joined(separator: "\n")
                showAlert = true
                validationMessage = "遇到错误，已停止后续处理；已成功生成的 PSD 会保留"
            }
        }
    }

    // MARK: - 结果提示

    private func showError(_ error: Error) {
        alertTitle = "无法开始"
        alertMessage = error.localizedDescription
        showAlert = true
    }

    private func playCompletionSound() {
        if let url = Bundle.main.url(forResource: "complete", withExtension: "m4a") {
            completionSound = NSSound(contentsOf: url, byReference: true)
            completionSound?.play()
        } else {
            NSSound.beep()
        }
    }
}
