// 图鉴和照片工作流共用固定间距的标本卡片，选中样式不改变行尺寸。
import SwiftUI

struct SpecimenSelectionRows<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let selectedIDs: Set<Item.ID>
    let currentID: Item.ID?
    @ViewBuilder let row: (Int, Item, Bool, Bool) -> Row

    var body: some View {
        LazyVStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let selected = selectedIDs.contains(item.id)
                let current = item.id == currentID
                let card = RoundedRectangle(cornerRadius: 9)

                row(index, item, selected, current)
                    .background {
                        card.fill(Color.primary.opacity(0.035))
                        card.fill(Color.accentColor.opacity(current ? 0.23 : selected ? 0.13 : 0))
                    }
                    .overlay {
                        card.strokeBorder(selected ? Color(nsColor: .systemGreen) : .clear, lineWidth: 2)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
            }
        }
        .padding(8)
    }
}
