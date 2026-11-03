//
//  RotateView.swift
//  Butterfly Toolkit
//
//  功能说明：
//  1. 用户可以通过拖拽或文件选择器选择一个图片文件夹。
//  2. 用户可以选择 90°、180° 或 270° 的旋转角度。
//  3. 点击“开始旋转”后，程序会批量旋转文件夹内的图片。
//  4. 旋转后的图片会直接替换原图片。
//  5. 图片处理会放在后台线程中执行，避免界面卡顿。
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 图片批量旋转主界面

struct RotateView: View {

    // MARK: 页面状态

    /// 当前用户选择的文件夹地址。
    ///
    /// 当值为 nil 时，表示用户还没有选择文件夹。
    /// 当用户拖入文件夹或点击“浏览文件夹”后，会保存对应的 URL。
    @State private var folderURL: URL?

    /// 当前选择的旋转角度。
    ///
    /// 默认设置为 180°。
    @State private var angle = 180

    /// 当前是否有文件正被拖到文件夹选择区域上方。
    ///
    /// 用于改变拖拽区域的边框和背景效果，
    /// 给用户一个视觉反馈。
    @State private var isDropTargeted = false

    /// 当前是否正在处理图片。
    ///
    /// 当图片正在旋转时：
    /// - 禁止重新选择文件夹；
    /// - 禁止切换旋转角度；
    /// - 禁止重复点击开始按钮；
    /// - 按钮中显示加载动画。
    @State private var isProcessing = false

    /// 用户可以选择的旋转角度。
    ///
    /// 这里设置为常量，因为程序运行过程中不需要修改这些选项。
    private let angles = [90, 180, 270]

    // MARK: - 主界面

    var body: some View {

        VStack(spacing: 26) {

            // 顶部预留空间，避免内容紧贴窗口顶部。
            Spacer(minLength: 10)

            // 页面顶部的旋转图标。
            Image(systemName: "rotate.right")
                .font(
                    .system(
                        size: 58,
                        weight: .medium
                    )
                )
                .foregroundStyle(.primary)

            // 页面主标题。
            Text("图片批量旋转")
                .font(.largeTitle)
                .bold()

            // 页面功能说明。
            Text("选择一个图片文件夹，直接旋转原图")
                .foregroundStyle(.secondary)

            // 文件夹选择与拖放区域。
            folderDropArea

            // 旋转角度选择区域。
            anglePicker

            // 开始旋转按钮。
            Button {

                // 点击按钮后直接开始旋转。
                //
                // 这里已经不再弹出二次确认窗口。
                rotateImages()

            } label: {

                HStack(spacing: 8) {

                    if isProcessing {

                        // 图片正在处理时显示加载动画。
                        ProgressView()
                            .controlSize(.small)

                    } else {

                        // 未处理时显示旋转图标。
                        Image(systemName: "rotate.right")

                    }

                    // 根据处理状态显示不同文字。
                    Text(
                        isProcessing
                        ? "正在旋转..."
                        : "开始旋转"
                    )

                }
                // 固定按钮内部内容尺寸，
                // 避免按钮文字变化时按钮宽度发生跳动。
                .frame(width: 220, height: 24)

            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            // 以下情况禁止点击按钮：
            // 1. 尚未选择文件夹；
            // 2. 当前正在处理图片。
            .disabled(
                folderURL == nil ||
                isProcessing
            )

            // 底部预留空间。
            Spacer(minLength: 10)

        }
        // 整个页面四周的内边距。
        .padding(40)

        // 设置页面最小尺寸。
        //
        // 当窗口缩小时，页面不会小于这个尺寸，
        // 避免控件挤压或显示不完整。
        .frame(
            minWidth: 680,
            minHeight: 650
        )
    }

    // MARK: - 文件夹拖放区域

    /// 用于选择文件夹或接收拖入文件夹的界面。
    ///
    /// 该区域会根据当前状态显示不同内容：
    ///
    /// 未选择文件夹时：
    /// - 显示添加文件夹图标；
    /// - 提示用户拖入文件夹；
    /// - 显示支持的图片格式。
    ///
    /// 已选择文件夹时：
    /// - 显示选择成功图标；
    /// - 显示文件夹名称；
    /// - 显示完整文件夹路径。
    private var folderDropArea: some View {

        VStack(spacing: 16) {

            // 根据是否已选择文件夹，显示不同图标。
            Image(
                systemName: folderURL == nil
                ? "folder.badge.plus"
                : "folder.fill.badge.checkmark"
            )
            .font(
                .system(
                    size: 52,
                    weight: .regular
                )
            )
            .foregroundStyle(
                folderURL == nil
                ? Color.secondary
                : Color.accentColor
            )

            if let folderURL {

                // MARK: 已选择文件夹时的界面

                Text("已选择文件夹")
                    .font(.title3)
                    .fontWeight(.semibold)

                // 显示文件夹名称。
                Text(folderURL.lastPathComponent)
                    .font(.body)
                    .foregroundStyle(.secondary)

                    // 最多显示一行。
                    .lineLimit(1)

                    // 内容过长时从中间省略，
                    // 这样通常可以同时看见路径开头和结尾。
                    .truncationMode(.middle)

                // 显示文件夹完整路径。
                Text(folderURL.path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 20)

            } else {

                // MARK: 尚未选择文件夹时的界面

                Text("把图片文件夹拖到这里")
                    .font(.title3)
                    .fontWeight(.semibold)

                // 提示支持的图片格式。
                //
                // 实际支持范围应当与
                // ImageProcessor.imageFiles(in:)
                // 中的格式判断保持一致。
                Text("支持 JPG、JPEG、PNG、TIF、TIFF")
                    .foregroundStyle(.secondary)

            }

            // 浏览或重新选择文件夹按钮。
            Button {

                selectFolder()

            } label: {

                Label(
                    folderURL == nil
                    ? "浏览文件夹"
                    : "重新选择",
                    systemImage: "folder"
                )

            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            // 图片处理期间禁止重新选择文件夹，
            // 防止正在处理时 folderURL 发生变化。
            .disabled(isProcessing)

        }
        // 让拖放区域尽可能填满可用宽度。
        .frame(maxWidth: .infinity)

        // 设置拖放区域固定高度。
        .frame(height: 280)

        // MARK: 拖放区域背景

        .background {

            RoundedRectangle(cornerRadius: 22)
                .fill(
                    isDropTargeted

                    // 文件拖入区域时，显示强调色背景。
                    ? Color.accentColor.opacity(0.10)

                    // 普通状态下使用浅灰色背景。
                    : Color.secondary.opacity(0.06)
                )

        }

        // MARK: 拖放区域边框

        .overlay {

            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(
                    isDropTargeted
                    ? Color.accentColor
                    : Color.secondary.opacity(0.55),

                    style: StrokeStyle(

                        // 文件拖入时边框稍微加粗。
                        lineWidth: isDropTargeted
                        ? 3
                        : 2,

                        // 设置虚线样式。
                        dash: [10, 8]
                    )
                )

        }

        // 文件拖入时轻微放大，
        // 增加操作反馈。
        .scaleEffect(
            isDropTargeted
            ? 1.01
            : 1
        )

        // 为放大和颜色变化添加动画。
        .animation(
            .easeInOut(duration: 0.15),
            value: isDropTargeted
        )

        // 明确整个圆角矩形区域都可以接收拖放。
        .contentShape(
            RoundedRectangle(cornerRadius: 22)
        )

        // 接收 Finder 中拖入的 URL。
        .dropDestination(for: URL.self) { urls, _ in

            // 检查拖入的 URL 中是否包含文件夹。
            handleDroppedURLs(urls)

        } isTargeted: { targeted in

            // 当拖拽内容进入或离开区域时，
            // 更新视觉状态。
            isDropTargeted = targeted

        }
    }

    // MARK: - 旋转角度选择区域

    /// 用于选择图片旋转角度。
    private var anglePicker: some View {

        VStack(spacing: 12) {

            Text("旋转角度")
                .font(.headline)

            // 分段选择器。
            Picker(
                "旋转角度",
                selection: $angle
            ) {

                // 根据 angles 数组生成选项。
                ForEach(angles, id: \.self) { value in

                    Text("\(value)°")
                        .tag(value)

                }

            }
            .pickerStyle(.segmented)

            // 因为上方已经单独显示“旋转角度”，
            // 因此隐藏 Picker 自带的标题。
            .labelsHidden()

            // 设置选择器固定宽度。
            .frame(width: 300)

            // 图片处理期间禁止切换角度。
            .disabled(isProcessing)

        }
    }

    // MARK: - 浏览文件夹

    /// 打开 macOS 文件夹选择器，让用户选择图片文件夹。
    private func selectFolder() {

        // NSOpenPanel 是 macOS 原生文件选择面板。
        let panel = NSOpenPanel()

        // 设置窗口标题。
        panel.title = "选择图片文件夹"

        // 设置右下角确认按钮的文字。
        panel.prompt = "选择"

        // 设置文件选择窗口中的说明文字。
        panel.message = "请选择需要批量旋转图片的文件夹"

        // 允许选择文件夹。
        panel.canChooseDirectories = true

        // 不允许选择普通文件。
        panel.canChooseFiles = false

        // 每次只允许选择一个文件夹。
        panel.allowsMultipleSelection = false

        // 不允许用户在选择窗口中创建新文件夹。
        panel.canCreateDirectories = false

        // 显示文件选择窗口。
        //
        // 当用户点击“选择”时，
        // runModal() 会返回 .OK。
        if panel.runModal() == .OK,
           let selectedURL = panel.url {

            // 保存用户选择的文件夹 URL。
            folderURL = selectedURL

        }
    }

    // MARK: - 接收拖入的文件夹

    /// 检查用户拖入的内容，并寻找其中的文件夹。
    ///
    /// - Parameter urls:
    ///   用户从 Finder 中拖入的 URL 数组。
    ///
    /// - Returns:
    ///   如果成功找到并接收文件夹，返回 true；
    ///   如果没有找到文件夹，返回 false。
    private func handleDroppedURLs(
        _ urls: [URL]
    ) -> Bool {

        // 图片正在处理时，不接受新的拖放内容。
        guard !isProcessing else {
            return false
        }

        // 用户可能一次拖入多个项目，
        // 因此逐个检查。
        for url in urls {

            do {

                // 获取 URL 是否为文件夹的信息。
                let resourceValues =
                    try url.resourceValues(
                        forKeys: [.isDirectoryKey]
                    )

                // 找到文件夹后立即保存并返回。
                if resourceValues.isDirectory == true {

                    folderURL = url
                    return true

                }

            } catch {

                // 如果某个 URL 无法读取，
                // 跳过它并继续检查下一个。
                continue

            }
        }

        // 如果拖入的内容中没有文件夹，
        // 显示错误提示。
        showAlert(
            title: "无法选择",
            message: "请拖入一个文件夹，而不是单个文件。"
        )

        return false
    }

    // MARK: - 开始批量旋转

    /// 扫描所选文件夹，并批量旋转其中的图片。
    private func rotateImages() {

        // 确保用户已经选择了文件夹。
        guard let folder = folderURL else {
            return
        }

        /*
         先保存当前旋转角度。

         后面的图片处理会进入后台线程。
         提前保存为普通常量，可以避免后台线程直接读取
         SwiftUI 的 @State 属性。
         */
        let selectedAngle = angle

        // 立即进入处理状态。
        //
        // 设置后：
        // - 按钮会显示加载动画；
        // - 文件夹选择按钮会被禁用；
        // - 旋转角度选择器会被禁用；
        // - 开始按钮本身也会被禁用。
        isProcessing = true

        /*
         使用后台线程处理图片。

         如果直接在主线程中读取和旋转大量图片，
         SwiftUI 界面可能会卡死，窗口无法拖动，
         按钮也无法及时刷新。

         qos: .userInitiated 表示：
         这是由用户主动发起，并希望尽快完成的任务。
         */
        DispatchQueue.global(
            qos: .userInitiated
        ).async {

            /*
             对于启用了 App Sandbox 的 macOS 应用，
             用户通过文件选择器获取的文件夹可能属于
             Security-Scoped Resource。

             调用 startAccessingSecurityScopedResource()
             可以在处理期间请求访问该文件夹。
             */
            let didAccessSecurityResource =
                folder.startAccessingSecurityScopedResource()

            /*
             defer 中的代码会在当前作用域结束前自动执行。

             无论图片处理成功、失败还是提前抛出错误，
             都会停止访问安全作用域资源。
             */
            defer {

                if didAccessSecurityResource {

                    folder.stopAccessingSecurityScopedResource()

                }
            }

            do {

                /*
                 获取文件夹中的图片文件。

                 ImageProcessor.imageFiles(in:)
                 应负责：
                 - 遍历文件夹；
                 - 筛选支持的图片格式；
                 - 返回图片文件 URL 数组。
                 */
                let images =
                    try ImageProcessor.imageFiles(
                        in: folder
                    )

                // 成功旋转的图片数量。
                var success = 0

                // 旋转失败的图片数量。
                var failed = 0

                // 逐张处理图片。
                for file in images {

                    do {

                        // 旋转当前图片并替换原文件。
                        try rotateSingleImage(
                            file,
                            degrees: selectedAngle
                        )

                        success += 1

                    } catch {

                        // 单张图片失败时不终止整个任务，
                        // 而是记录失败数量并继续处理下一张。
                        failed += 1

                        // 在 Xcode 控制台输出详细错误，
                        // 方便开发期间排查问题。
                        print(
                            """
                            旋转失败：
                            文件：\(file.path)
                            错误：\(error)
                            """
                        )

                    }
                }

                /*
                 所有图片处理完成后，
                 回到主线程更新 SwiftUI 状态和显示窗口。

                 SwiftUI 的界面状态应在主线程修改。
                 */
                DispatchQueue.main.async {

                    // 结束处理状态。
                    isProcessing = false

                    // 创建完成提示窗口。
                    let alert = NSAlert()

                    alert.messageText = "旋转完成"

                    // 根据处理结果显示不同内容。
                    if images.isEmpty {

                        // 文件夹内没有支持的图片。
                        alert.alertStyle = .informational
                        alert.informativeText =
                            "所选文件夹中没有找到支持的图片。"

                    } else if failed == 0 {

                        // 所有图片都处理成功。
                        alert.alertStyle = .informational
                        alert.informativeText =
                            "成功旋转 \(success) 张图片。"

                    } else {

                        // 部分图片处理失败。
                        alert.alertStyle = .warning
                        alert.informativeText =
                            """
                            成功旋转：\(success) 张
                            旋转失败：\(failed) 张
                            """

                    }

                    // 为弹窗添加确定按钮。
                    alert.addButton(withTitle: "确定")

                    // 显示弹窗。
                    alert.runModal()

                }

            } catch {

                /*
                 如果在扫描文件夹或读取文件列表时发生整体错误，
                 回到主线程结束处理状态并显示错误信息。
                 */
                DispatchQueue.main.async {

                    isProcessing = false

                    showAlert(
                        title: "旋转失败",
                        message: error.localizedDescription,
                        style: .critical
                    )

                }
            }
        }
    }

    // MARK: - 旋转单张图片

    /// 旋转一张图片，并使用旋转后的图片替换原图片。
    ///
    /// 该方法不会直接把处理结果写入原文件，
    /// 而是先生成一个临时文件，成功后再替换原图。
    ///
    /// 这样可以降低图片处理失败时原文件损坏或丢失的风险。
    ///
    /// - Parameters:
    ///   - file: 需要旋转的原图片 URL。
    ///   - degrees: 旋转角度，例如 90、180 或 270。
    private func rotateSingleImage(
        _ file: URL,
        degrees: Int
    ) throws {

        // 获取系统默认文件管理器。
        let fileManager = FileManager.default

        /*
         在原图片所在目录中创建临时文件地址。

         例如原文件：
         /Pictures/test.jpg

         临时文件可能是：
         /Pictures/.rotate-随机UUID.jpg

         保留原扩展名的原因是，
         ImageProcessor 可以根据扩展名决定图片输出格式。
         */
        let temporaryURL = file
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".rotate-\(UUID().uuidString)"
            )
            .appendingPathExtension(
                file.pathExtension
            )

        /*
         如果处理过程中失败，
         defer 会自动清理遗留的临时文件。

         如果替换成功，临时文件通常已经被移动或删除，
         此时 fileExists 会返回 false。
         */
        defer {

            if fileManager.fileExists(
                atPath: temporaryURL.path
            ) {

                try? fileManager.removeItem(
                    at: temporaryURL
                )

            }
        }

        /*
         调用 ImageProcessor 完成真正的图片旋转。

         sourceURL：
         原始图片地址。

         destinationURL：
         旋转后的临时图片地址。

         degrees：
         旋转角度。
         */
        try ImageProcessor.rotateImage(
            sourceURL: file,
            destinationURL: temporaryURL,
            degrees: degrees
        )

        /*
         使用临时文件替换原文件。

         相比下面这种方式：

         1. 删除原文件；
         2. 把临时文件移动过去；

         replaceItemAt 更安全。

         因为如果直接删除原文件后，
         移动临时文件的操作又恰好失败，
         原图就可能永久丢失。
         */
        _ = try fileManager.replaceItemAt(
            file,
            withItemAt: temporaryURL,
            backupItemName: nil,
            options: []
        )
    }

    // MARK: - 显示提示框

    /// 显示一个通用的 macOS 提示窗口。
    ///
    /// - Parameters:
    ///   - title: 提示框标题。
    ///   - message: 提示框详细内容。
    ///   - style: 提示框样式，默认为警告样式。
    private func showAlert(
        title: String,
        message: String,
        style: NSAlert.Style = .warning
    ) {

        // 创建 macOS 原生提示框。
        let alert = NSAlert()

        // 设置提示框样式。
        alert.alertStyle = style

        // 设置标题。
        alert.messageText = title

        // 设置详细说明。
        alert.informativeText = message

        // 添加确定按钮。
        alert.addButton(withTitle: "确定")

        // 显示提示框。
        alert.runModal()
    }
}

// MARK: - Xcode 预览

#Preview {

    RotateView()
        .frame(
            width: 760,
            height: 700
        )

}
