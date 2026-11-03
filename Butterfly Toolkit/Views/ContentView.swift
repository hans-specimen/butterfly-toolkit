//
//  ContentView.swift
//  Butterfly Toolkit
//
//  Created by Hans on 2026/8/4.
//

import SwiftUI

enum ToolPage: String, CaseIterable, Identifiable {

    case aiCutout = "AI 抠图"
    case aiSamples = "训练素材"
    case aiTraining = "模型训练"
    case aiModels = "模型版本"

    case rename = "批量重命名"
    case compress = "图片压缩"
    case rotate = "批量旋转"
    case smartCrop = "智能裁剪"
    case focusStack = "景深合成 PSD"
    case xianyuProduct = "闲鱼产品图"
    case psdExport = "PSD 批量导出"
    case transparentPNGTrim = "透明 PNG 裁切"
    case about = "关于"

    var id: String {
        rawValue
    }

    var icon: String {

        switch self {

        case .aiCutout: return "viewfinder"
        case .aiSamples: return "photo.stack"
        case .aiTraining: return "brain"
        case .aiModels: return "square.3.layers.3d"

        case .rename:
            return "textformat"

        case .compress:
            return "arrow.down.circle"

        case .rotate:
            return "rotate.right"

        case .smartCrop:
            return "crop"

        case .focusStack:
            return "square.3.layers.3d"

        case .xianyuProduct:
            return "photo.badge.plus"

        case .psdExport:
            return "doc.badge.arrow.up"

        case .transparentPNGTrim:
            return "crop"

        case .about:
            return "info.circle"
        }
    }
}

struct ContentView: View {

    @State private var selectedPage: ToolPage? = .aiCutout
    @StateObject private var aiStore = AIWorkspaceStore()

    var body: some View {

        NavigationSplitView {

            List(selection: $selectedPage) {
                Section("AI 工作区") {
                    ForEach([ToolPage.aiCutout, .aiSamples, .aiTraining, .aiModels]) { page in
                        Label(page.rawValue, systemImage: page.icon).tag(page)
                    }
                }
                Section("图片工具") {
                    ForEach([ToolPage.rename, .compress, .rotate, .smartCrop, .focusStack, .xianyuProduct, .psdExport, .transparentPNGTrim]) { page in
                        Label(page.rawValue, systemImage: page.icon).tag(page)
                    }
                }
                Section {
                    Label(ToolPage.about.rawValue, systemImage: ToolPage.about.icon).tag(ToolPage.about)
                }
            }
            .navigationTitle("Butterfly Toolkit")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)

        } detail: {

            switch selectedPage {

            case .aiCutout, .aiSamples, .aiTraining, .aiModels:
                AIWorkspaceView(store: aiStore, page: selectedPage ?? .aiCutout) { selectedPage = $0 }

            case .rename:
                RenameView()

            case .compress:
                CompressView()

            case .rotate:
                RotateView()

            case .smartCrop:
                SmartCropView()

            case .focusStack:
                FocusStackView()

            case .xianyuProduct:
                XianyuProductView()

            case .psdExport:
                PSDExportView()

            case .transparentPNGTrim:
                TransparentPNGTrimView()

            case .about:
                AboutView()

            case nil:
                Text("请选择一个工具")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(
            minWidth: 1200,
            minHeight: 720
        )
    }
}

#Preview {
    ContentView()
}
