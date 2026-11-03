import SwiftUI

struct AITrainingSourcesView: View {
    @ObservedObject var store: AIWorkspaceStore
    var navigate: (ToolPage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("方式一 · 已精扣的 PSD", systemImage: "square.3.layers.3d").font(.headline)
                        Text("从上到下：答案 → 原图 → 背景。自动提取并检查，其他结构直接报错。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("导入三层 PSD…") { store.choosePSDs() }.buttonStyle(.borderedProminent)
                            Button("打开待处理目录") { store.reveal(store.workspaceURL.appendingPathComponent("待处理PSD").path) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("方式二 · 修正 AI 结果", systemImage: "paintbrush.pointed").font(.headline)
                        Text("选择 AI 结果进入 PS，修改第一层并保存，再读取检查并确认答案。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("选择 AI 结果") { navigate(.aiCutout) }
                            Button("读取 PS 修正…") { store.choosePSDs(correction: true) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }.disabled(store.busy || store.catalog == nil)
            HStack {
                Text("素材：butterfly-ai-footage · 模型：butterfly-matte/models")
                Spacer()
                Button("打开素材库") { store.reveal(store.workspacePath) }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}
