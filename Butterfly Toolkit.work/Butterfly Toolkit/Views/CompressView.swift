//
//  CompressView.swift
//  蝴蝶照片批量重命名
//
//  Created by Hans on 2026/8/4.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CompressView: View {

    @State private var folderURL: URL?
    @State private var imageCount = 0
    @State private var targetSize = "500"

    @State private var isDropTargeted = false
    @State private var isProcessing = false
    @State private var progress: Double = 0

    @State private var statusMessage = "请拖入需要压缩的图片文件夹"

    @State private var showAlert = false
    @State private var alertTitle = "提示"
    @State private var alertMessage = ""

    var body: some View {
        VStack(spacing: 24) {

            headerView

            dropArea

            informationView

            targetSizeView

            if isProcessing {
                VStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 420)

                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 16) {
                Button {
                    openSelectedFolder()
                } label: {
                    Label("打开原文件夹", systemImage: "folder")
                        .frame(width: 130)
                }
                .disabled(folderURL == nil || isProcessing)

                Button {
                    startCompression()
                } label: {
                    if isProcessing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 170)
                    } else {
                        Label("开始压缩", systemImage: "arrow.down.circle.fill")
                            .frame(width: 170)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(folderURL == nil || imageCount == 0 || isProcessing)
            }

            Text(statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .padding(34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(alertTitle, isPresented: $showAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private var headerView: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 54))

            Text("图片压缩")
                .font(.largeTitle)
                .bold()

            Text("将图片压缩到指定文件大小，并保存到新的文件夹")
                .foregroundStyle(.secondary)
        }
    }

    private var dropArea: some View {
        VStack(spacing: 13) {

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
                Text(folderURL.lastPathComponent)
                    .font(.title3)
                    .bold()

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

            Button {
                selectFolder()
            } label: {
                Label("浏览文件夹", systemImage: "folder")
            }
            .disabled(isProcessing)
        }
        .frame(maxWidth: 760)
        .frame(height: 210)
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
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else {
                return false
            }

            return receiveFolder(url)

        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }

    private var informationView: some View {
        HStack(spacing: 18) {
            informationCard(
                title: "图片数量",
                value: "\(imageCount)",
                icon: "photo.on.rectangle.angled"
            )

            informationCard(
                title: "输出格式",
                value: "JPG",
                icon: "doc"
            )

            informationCard(
                title: "输出目录",
                value: outputFolderName,
                icon: "folder"
            )
        }
        .frame(maxWidth: 760)
    }

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
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var targetSizeView: some View {
        HStack(spacing: 12) {
            Text("目标大小")

            TextField("例如 500", text: $targetSize)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)

            Text("KB / 张")
                .foregroundStyle(.secondary)
        }
    }

    private var outputFolderName: String {
        guard let size = Int(targetSize), size > 0 else {
            return "压缩后"
        }

        return "压缩后_\(size)KB"
    }

    private func selectFolder() {
        let panel = NSOpenPanel()

        panel.title = "选择图片文件夹"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        if panel.runModal() == .OK,
           let url = panel.url {
            _ = receiveFolder(url)
        }
    }

    private func receiveFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false

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

        folderURL = url
        refreshImageCount()

        return true
    }

    private func refreshImageCount() {
        guard let folderURL else {
            imageCount = 0
            return
        }

        let accessGranted =
            folderURL.startAccessingSecurityScopedResource()

        defer {
            if accessGranted {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let files = try ImageProcessor.imageFiles(
                in: folderURL
            )

            imageCount = files.count

            if files.isEmpty {
                statusMessage = "该文件夹中没有找到支持的图片"
            } else {
                statusMessage =
                    "已发现 \(files.count) 张图片，原图不会被修改"
            }

        } catch {
            imageCount = 0
            statusMessage =
                "读取文件夹失败：\(error.localizedDescription)"
        }
    }

    private func startCompression() {
        guard let folderURL else {
            showMessage(
                title: "未选择文件夹",
                message: "请先选择图片文件夹。"
            )
            return
        }

        guard let targetKilobytes = Int(targetSize),
              targetKilobytes > 0 else {
            showMessage(
                title: "目标大小错误",
                message: "请输入正确的目标大小，例如 500。"
            )
            return
        }

        isProcessing = true
        progress = 0
        statusMessage = "正在压缩图片……"

        let selectedFolder = folderURL
        let outputName = "压缩后_\(targetKilobytes)KB"

        Task {
            do {
                let result = try await compressFolder(
                    folderURL: selectedFolder,
                    outputFolderName: outputName,
                    targetKilobytes: targetKilobytes
                )

                await MainActor.run {
                    isProcessing = false
                    progress = 1
                    statusMessage =
                        "完成：成功压缩 \(result.successCount) 张图片"

                    showMessage(
                        title: "压缩完成",
                        message:
                            "成功压缩 \(result.successCount) 张图片。\n"
                            + "失败 \(result.failureCount) 张。\n\n"
                            + "结果已保存到：\(outputName)"
                    )
                }

            } catch {
                await MainActor.run {
                    isProcessing = false

                    showMessage(
                        title: "压缩失败",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func compressFolder(
        folderURL: URL,
        outputFolderName: String,
        targetKilobytes: Int
    ) async throws -> (
        successCount: Int,
        failureCount: Int
    ) {
        let accessGranted =
            folderURL.startAccessingSecurityScopedResource()

        defer {
            if accessGranted {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default

        let files = try ImageProcessor.imageFiles(
            in: folderURL
        )

        let outputFolder =
            folderURL.appendingPathComponent(
                outputFolderName,
                isDirectory: true
            )

        if fileManager.fileExists(
            atPath: outputFolder.path
        ) {
            try fileManager.removeItem(
                at: outputFolder
            )
        }

        try fileManager.createDirectory(
            at: outputFolder,
            withIntermediateDirectories: true
        )

        var successCount = 0
        var failureCount = 0

        for (index, sourceURL) in files.enumerated() {

            let baseName =
                sourceURL.deletingPathExtension()
                    .lastPathComponent

            let destinationURL =
                outputFolder
                    .appendingPathComponent(baseName)
                    .appendingPathExtension("jpg")

            do {
                try ImageProcessor.compressImage(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    targetKilobytes: targetKilobytes
                )

                successCount += 1

            } catch {
                failureCount += 1
            }

            let currentProgress =
                Double(index + 1) / Double(files.count)

            await MainActor.run {
                progress = currentProgress
                statusMessage =
                    "正在处理 \(index + 1) / \(files.count)"
            }
        }

        return (
            successCount,
            failureCount
        )
    }

    private func openSelectedFolder() {
        guard let folderURL else {
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting(
            [folderURL]
        )
    }

    private func showMessage(
        title: String,
        message: String
    ) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}

#Preview {
    CompressView()
}
