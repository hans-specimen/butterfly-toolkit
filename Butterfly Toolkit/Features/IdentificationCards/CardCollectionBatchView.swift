// 批量采集信息表单：粘贴多行表格，按标本列表顺序核对后统一保存。
import SwiftUI

struct CardCollectionBatchView: View {
    @ObservedObject var store: IdentificationCardsStore
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var writeError: String?

    var body: some View {
        let cards = store.session.records
        let parsed = Result { try CardCollectionInfo.parseBatch(source) }
        let rows = (try? parsed.get()) ?? []
        let matches = !cards.isEmpty && rows.count == cards.count

        VStack(alignment: .leading, spacing: 14) {
            Text("批量填写采集信息").font(.title2.bold())
            Text("每行对应左侧的一只标本。可粘贴「翅展（mm）、国家、采集点、日期」或原有采集表格。没有信息时保留空单元格。")
                .foregroundStyle(.secondary)
            TextEditor(text: $source)
                .font(.body)
                .frame(height: 132)
                .border(Color(nsColor: .separatorColor))
                .accessibilityLabel("采集信息表格")
                .onChange(of: source) { writeError = nil }

            if case .failure(let error) = parsed {
                Text(error.localizedDescription).foregroundStyle(.red)
            } else {
                Text("已识别 \(rows.count) 行 · \(cards.count) 只标本")
                    .foregroundStyle(!rows.isEmpty && !matches ? Color.orange : Color.secondary)
            }
            if let writeError { Text(writeError).foregroundStyle(.red) }

            List(Array(cards.enumerated()), id: \.element.id) { index, card in
                VStack(alignment: .leading, spacing: 3) {
                    let label = [card.input.specimenNumber, card.title].compactMap { $0 }.joined(separator: "  ")
                    Text("\(index + 1). \(label)").fontWeight(.medium)
                    if matches {
                        let info = rows[index].info
                        Text(info.formatted.isEmpty ? "留空" : info.formatted).foregroundStyle(.secondary)
                        ForEach(info.warnings, id: \.self) { warning in
                            Text(warning).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.vertical, 3)
            }
            .frame(height: 244)
            .accessibilityLabel("标本与采集信息对应预览")

            HStack {
                Text("应用后将替换对应标本的采集信息。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("应用到 \(cards.count) 只标本") {
                    do {
                        try store.applyCollectionBatch(rows, to: cards.map(\.id))
                        dismiss()
                    } catch {
                        writeError = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!matches || store.locked)
            }
        }
        .padding(24)
        .frame(width: 640)
    }
}
