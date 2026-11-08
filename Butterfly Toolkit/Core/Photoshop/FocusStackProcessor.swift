// 景深合成处理：按名称清单将每只蝴蝶的六张照片分成正、反面两组三张，生成 PSD 合成任务。
// 查找 Photoshop 并执行脚本，完成图层对齐、景深混合、背景填充和保存；供独立工具与照片工作流共用。

import AppKit
import Foundation

// MARK: - 错误、合成任务与批次计划

enum FocusStackError: LocalizedError, Sendable {
    case invalidInputFolder
    case invalidOutputFolder
    case noImages
    case emptyNames
    case invalidName(String)
    case duplicateName(String)
    case countMismatch(images: Int, names: Int)
    case photoshopNotFound
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidInputFolder:
            "原图文件夹不存在或无法读取。"
        case .invalidOutputFolder:
            "PSD 输出文件夹无法创建或写入。"
        case .noImages:
            "原图文件夹中没有找到支持的图片。"
        case .emptyNames:
            "请粘贴 PSD 名称清单，每行填写一只蝴蝶。"
        case .invalidName(let name):
            "名称“\(name)”包含 /、:，或已经带有 _F/_U 后缀。请只填写基础名称。"
        case .duplicateName(let name):
            "名称清单中存在重复项：\(name)"
        case .countMismatch(let images, let names):
            "照片有 \(images) 张，但 \(names) 行名称需要 \(names * 6) 张。每只蝴蝶必须正好对应 6 张照片。"
        case .photoshopNotFound:
            "没有找到 Adobe Photoshop。请先安装并启动 Photoshop 2026。"
        case .scriptFailed(let message):
            "Photoshop 处理失败：\(message)"
        }
    }
}

nonisolated struct FocusStackJob: Identifiable, Sendable {
    let id: Int
    let sourceFiles: [URL]
    let destinationURL: URL
    let butterflyName: String
    let side: String

    var sourceSummary: String {
        sourceFiles.map(\.lastPathComponent).joined(separator: "、")
    }
}

struct FocusStackPlan: Sendable {
    let jobs: [FocusStackJob]
    let imageCount: Int
    let butterflyCount: Int
    let skippedCount: Int

    var pendingJobs: [FocusStackJob] {
        jobs.filter { !FileManager.default.fileExists(atPath: $0.destinationURL.path) }
    }
}

struct FocusStackProcessor {
    private nonisolated static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "tif", "tiff", "png"
    ]

    // MARK: - 输入校验与正反面分组

    nonisolated static func makePlan(
        inputFolder: URL,
        outputFolder: URL,
        namesText: String
    ) throws -> FocusStackPlan {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inputFolder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw FocusStackError.invalidInputFolder
        }

        let names = try parseNames(namesText)
        let files = try FileManager.default.contentsOfDirectory(
            at: inputFolder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
        .sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        guard !files.isEmpty else { throw FocusStackError.noImages }
        guard files.count == names.count * 6 else {
            throw FocusStackError.countMismatch(images: files.count, names: names.count)
        }

        do {
            try FileManager.default.createDirectory(
                at: outputFolder,
                withIntermediateDirectories: true
            )
        } catch {
            throw FocusStackError.invalidOutputFolder
        }

        var jobs: [FocusStackJob] = []
        var skipped = 0
        // 自然排序后的每六张对应一只标本：前三张为正面 F，后三张为反面 U。
        for (butterflyIndex, name) in names.enumerated() {
            for (sideIndex, side) in ["F", "U"].enumerated() {
                let first = butterflyIndex * 6 + sideIndex * 3
                let destination = outputFolder
                    .appendingPathComponent("\(name)_\(side)")
                    .appendingPathExtension("psd")
                if FileManager.default.fileExists(atPath: destination.path) {
                    skipped += 1
                }
                jobs.append(
                    FocusStackJob(
                        id: jobs.count,
                        sourceFiles: Array(files[first..<(first + 3)]),
                        destinationURL: destination,
                        butterflyName: name,
                        side: side
                    )
                )
            }
        }

        return FocusStackPlan(
            jobs: jobs,
            imageCount: files.count,
            butterflyCount: names.count,
            skippedCount: skipped
        )
    }

    // MARK: - Photoshop 查找与脚本执行

    nonisolated static func photoshopApplicationName() -> String? {
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard let topLevelEntries = try? FileManager.default.contentsOfDirectory(
            at: applications,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        // Adobe 通常把应用放在“/Applications/Adobe Photoshop 2026/”
        // 这样的同名文件夹里，也兼容直接位于 /Applications 的安装方式。
        var entries = topLevelEntries
        for folder in topLevelEntries where folder.pathExtension.isEmpty {
            if let children = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                entries.append(contentsOf: children)
            }
        }

        return entries
            .filter {
                let name = $0.deletingPathExtension().lastPathComponent
                return $0.pathExtension.lowercased() == "app" &&
                    name.localizedCaseInsensitiveContains("Adobe Photoshop")
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending
            }
            .first?
            .deletingPathExtension()
            .lastPathComponent
    }

    nonisolated static func process(
        _ job: FocusStackJob,
        photoshopApplicationName: String,
        workflowPNGExportScript: String? = nil
    ) throws {
        // 已有 PSD 直接跳过，避免重复执行覆盖用户已经编辑的结果。
        guard !FileManager.default.fileExists(atPath: job.destinationURL.path) else { return }

        let temporaryFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ButterflyFocusStack-\(UUID().uuidString)", isDirectory: true)
        let jsxURL = temporaryFolder.appendingPathComponent("FocusStack.jsx")
        defer { try? FileManager.default.removeItem(at: temporaryFolder) }

        do {
            try FileManager.default.createDirectory(at: temporaryFolder, withIntermediateDirectories: true)
            try jsx(for: job, workflowPNGExportScript: workflowPNGExportScript).write(to: jsxURL, atomically: true, encoding: .utf8)
        } catch {
            throw FocusStackError.scriptFailed("无法创建临时处理脚本。")
        }

        let appleScript = """
        tell application "\(appleScriptEscaped(photoshopApplicationName))"
            activate
            do javascript file (POSIX file "\(appleScriptEscaped(jsxURL.path))")
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let stderr = Pipe()
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw FocusStackError.scriptFailed(error.localizedDescription)
        }

        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw FocusStackError.scriptFailed(errorText.isEmpty ? "未知脚本错误" : errorText)
        }
        guard FileManager.default.fileExists(atPath: job.destinationURL.path) else {
            throw FocusStackError.scriptFailed("Photoshop 没有生成 \(job.destinationURL.lastPathComponent)。")
        }
    }

    // MARK: - 名称与路径约束

    nonisolated private static func parseNames(_ text: String) throws -> [String] {
        let names = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { throw FocusStackError.emptyNames }

        var seen = Set<String>()
        for name in names {
            let lower = name.lowercased()
            guard !name.contains("/"), !name.contains(":"),
                  !lower.hasSuffix("_f"), !lower.hasSuffix("_u"),
                  !lower.hasSuffix(".psd") else {
                throw FocusStackError.invalidName(name)
            }
            let key = name.precomposedStringWithCanonicalMapping.lowercased()
            guard seen.insert(key).inserted else {
                throw FocusStackError.duplicateName(name)
            }
        }
        return names
    }

    // MARK: - 景深合成脚本生成

    // 可选导出脚本在保存 PSD 后执行，工作流可复用尚未关闭的文档。
    nonisolated static func jsx(for job: FocusStackJob, workflowPNGExportScript: String? = nil) -> String {
        let sources = job.sourceFiles
            .map { "\"\(jsxEscaped($0.path))\"" }
            .joined(separator: ", ")
        return """
        #target photoshop
        app.bringToFront();
        app.displayDialogs = DialogModes.NO;

        (function () {
            function selectEveryLayer(document) {
                if (document.layers.length === 0) {
                    throw new Error("文档中没有可选择的图层。");
                }
                for (var layerIndex = 0; layerIndex < document.layers.length; layerIndex++) {
                    var select = new ActionDescriptor();
                    var layerReference = new ActionReference();
                    layerReference.putIdentifier(
                        charIDToTypeID("Lyr "),
                        document.layers[layerIndex].id
                    );
                    select.putReference(charIDToTypeID("null"), layerReference);
                    if (layerIndex > 0) {
                        select.putEnumerated(
                            stringIDToTypeID("selectionModifier"),
                            stringIDToTypeID("selectionModifierType"),
                            stringIDToTypeID("addToSelection")
                        );
                    }
                    select.putBoolean(charIDToTypeID("MkVs"), false);
                    executeAction(charIDToTypeID("slct"), select, DialogModes.NO);
                }
            }

            var sources = [\(sources)];
            var destination = "\(jsxEscaped(job.destinationURL.path))";
            var stackDocument = null;

            try {
                stackDocument = app.open(new File(sources[0]));
                // 直接打开 JPG 时首层是锁定的 Background；载入堆栈得到的则是普通图层。
                // 先解除背景层属性，否则 Photoshop 的“Select All Layers”不可用。
                if (stackDocument.activeLayer.isBackgroundLayer) {
                    stackDocument.activeLayer.isBackgroundLayer = false;
                }
                stackDocument.activeLayer.name = new File(sources[0]).name;

                for (var i = 1; i < sources.length; i++) {
                    var sourceDocument = app.open(new File(sources[i]));
                    // 依次追加到底部，最终保持第1张在最上、第3张在最下。
                    sourceDocument.activeLayer.duplicate(stackDocument, ElementPlacement.PLACEATEND);
                    sourceDocument.close(SaveOptions.DONOTSAVECHANGES);
                    app.activeDocument = stackDocument;
                    stackDocument.activeLayer.name = new File(sources[i]).name;
                }

                app.activeDocument = stackDocument;
                selectEveryLayer(stackDocument);

                try {
                    // Photoshop 的脚本事件 Algn + ADSContent 等同于界面中的
                    // “自动对齐图层 > 自动”，并使用默认的镜头校正关闭状态。
                    var align = new ActionDescriptor();
                    var alignReference = new ActionReference();
                    alignReference.putEnumerated(
                        charIDToTypeID("Lyr "),
                        charIDToTypeID("Ordn"),
                        charIDToTypeID("Trgt")
                    );
                    align.putReference(charIDToTypeID("null"), alignReference);
                    align.putEnumerated(
                        charIDToTypeID("Usng"),
                        stringIDToTypeID("alignDistributeSelector"),
                        stringIDToTypeID("ADSContent")
                    );
                    executeAction(charIDToTypeID("Algn"), align, DialogModes.NO);
                } catch (alignError) {
                    throw new Error("自动对齐图层失败：" + alignError.message);
                }

                selectEveryLayer(stackDocument);
                try {
                    var blend = new ActionDescriptor();
                    blend.putEnumerated(
                        charIDToTypeID("Aply"),
                        stringIDToTypeID("autoBlendType"),
                        stringIDToTypeID("maxDOF")
                    );
                    blend.putBoolean(charIDToTypeID("ClrC"), true);
                    blend.putBoolean(stringIDToTypeID("autoTransparencyFill"), false);
                    executeAction(stringIDToTypeID("mergeAlignedLayers"), blend, DialogModes.NO);
                } catch (blendError) {
                    throw new Error("自动混合图层失败：" + blendError.message);
                }

                try {
                    var make = new ActionDescriptor();
                    var reference = new ActionReference();
                    reference.putClass(stringIDToTypeID("contentLayer"));
                    make.putReference(charIDToTypeID("null"), reference);
                    var layer = new ActionDescriptor();
                    var solid = new ActionDescriptor();
                    var color = new ActionDescriptor();
                    color.putDouble(charIDToTypeID("Rd  "), 116);
                    color.putDouble(charIDToTypeID("Grn "), 191);
                    color.putDouble(charIDToTypeID("Bl  "), 255);
                    solid.putObject(charIDToTypeID("Clr "), charIDToTypeID("RGBC"), color);
                    layer.putObject(charIDToTypeID("Type"), stringIDToTypeID("solidColorLayer"), solid);
                    make.putObject(charIDToTypeID("Usng"), stringIDToTypeID("contentLayer"), layer);
                    executeAction(charIDToTypeID("Mk  "), make, DialogModes.NO);
                    stackDocument.activeLayer.name = "Background #74BFFF";
                    stackDocument.activeLayer.move(
                        stackDocument.layers[stackDocument.layers.length - 1],
                        ElementPlacement.PLACEAFTER
                    );
                } catch (fillError) {
                    throw new Error("创建纯色填充图层失败：" + fillError.message);
                }

                var psdOptions = new PhotoshopSaveOptions();
                psdOptions.layers = true;
                psdOptions.embedColorProfile = true;
                psdOptions.maximizeCompatibility = true;
                try {
                    stackDocument.saveAs(new File(destination), psdOptions, true, Extension.LOWERCASE);
                } catch (saveError) {
                    throw new Error("保存 PSD 失败：" + saveError.message);
                }
                \(workflowPNGExportScript.map { "try { (function(){" + $0 + "}()); } catch (pngError) {}" } ?? "")
                stackDocument.close(SaveOptions.DONOTSAVECHANGES);
            } catch (error) {
                if (stackDocument) {
                    try { stackDocument.close(SaveOptions.DONOTSAVECHANGES); } catch (_) {}
                }
                throw error;
            }
        }());
        """
    }

    // MARK: - 脚本字符串转义

    nonisolated private static func jsxEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    nonisolated private static func appleScriptEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
