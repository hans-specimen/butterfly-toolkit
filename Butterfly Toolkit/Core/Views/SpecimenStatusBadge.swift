// 标本列表状态胶囊，同时以文字和颜色区分当前进度。
import SwiftUI

struct SpecimenStatusBadge: View {
    enum Tone {
        case neutral, blue, amber, green, red, purple

        func color(in scheme: ColorScheme) -> Color {
            let dark = scheme == .dark
            switch self {
            case .neutral: return .secondary
            case .blue: return dark ? Color(red: 0.53, green: 0.76, blue: 1) : Color(red: 0.13, green: 0.34, blue: 0.63)
            case .amber: return dark ? Color(red: 1, green: 0.77, blue: 0.42) : Color(red: 0.50, green: 0.30, blue: 0.06)
            case .green: return dark ? Color(red: 0.48, green: 0.88, blue: 0.58) : Color(red: 0.09, green: 0.39, blue: 0.19)
            case .red: return dark ? Color(red: 1, green: 0.60, blue: 0.60) : Color(red: 0.65, green: 0.19, blue: 0.19)
            case .purple: return dark ? Color(red: 0.82, green: 0.69, blue: 1) : Color(red: 0.40, green: 0.25, blue: 0.65)
            }
        }
    }

    let title: String
    let tone: Tone
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let color = tone.color(in: colorScheme)
        Text(title)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}
