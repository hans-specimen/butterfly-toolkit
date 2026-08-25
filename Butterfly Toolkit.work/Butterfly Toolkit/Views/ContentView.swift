//
//  ContentView.swift
//  Butterfly Toolkit
//
//  Created by Hans on 2026/8/4.
//

import SwiftUI

enum ToolPage: String, CaseIterable, Identifiable {

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

    @State private var selectedPage: ToolPage? = .rename

    var body: some View {

        NavigationSplitView {

            List(
                ToolPage.allCases,
                selection: $selectedPage
            ) { page in

                Label(
                    page.rawValue,
                    systemImage: page.icon
                )
                .tag(page)
            }
            .navigationTitle("HANS蝴蝶工具")
            .frame(minWidth: 190)

        } detail: {

            switch selectedPage {

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
            minHeight: 800
        )
    }
}

#Preview {
    ContentView()
}
