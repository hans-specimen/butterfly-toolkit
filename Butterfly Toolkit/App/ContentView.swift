// 主窗口导航：定义工具页面及图标，组织侧边栏，并将选择路由到对应功能页面。
// 在窗口内持有 AI 与照片工作流状态，供切换页面时继续使用。
// 由 Hans 创建于 2026/8/4。

import SwiftUI

// MARK: - 工具页面与导航图标

enum ToolPage: String, CaseIterable, Identifiable {

    case photoWorkflow = "照片工作流"
    case identificationCards = "图鉴卡片"
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

        case .photoWorkflow: return "camera.macro"
        case .identificationCards: return "rectangle.on.rectangle"
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

// MARK: - 主窗口与共享状态

struct ContentView: View {

    @State private var selectedPage: ToolPage? = .aiCutout
    // 状态由主窗口持有，避免切换到其他工具时重新创建工作区。
    @StateObject private var aiStore = AIWorkspaceStore()
    @StateObject private var workflowStore = PhotoWorkflowStore()
    @StateObject private var cardsStore = IdentificationCardsStore()

    // MARK: - 侧边栏与详情页路由

    var body: some View {

        NavigationSplitView {

            List(selection: $selectedPage) {
                Section("标本照片") {
                    Label(ToolPage.photoWorkflow.rawValue, systemImage: ToolPage.photoWorkflow.icon).tag(ToolPage.photoWorkflow)
                    Label(ToolPage.identificationCards.rawValue, systemImage: ToolPage.identificationCards.icon).tag(ToolPage.identificationCards)
                }
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

            case .photoWorkflow:
                PhotoWorkflowView(store: workflowStore)

            case .identificationCards:
                IdentificationCardsView(store: cardsStore)

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

// MARK: - 界面预览

#Preview {
    ContentView()
}
