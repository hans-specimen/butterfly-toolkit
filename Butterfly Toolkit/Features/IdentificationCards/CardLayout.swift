// 图鉴初始布局：根据正反面可见轮廓统一宽度或高度，避让文字由 Photoshop 的 Alpha 选择区完成。
import Foundation
import CoreGraphics

nonisolated enum CardLayout {
    struct Placement {
        let frames: [CGRect]
        let matchHeight: Bool
        let topAligned: Bool
        let bottomLimit: CGFloat
    }

    // MARK: - 正反面共同尺寸
    static func placement(front: CGSize, back: CGSize) -> Placement? {
        let sizes = [front, back]
        guard sizes.allSatisfy({ $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }) else { return nil }

        let boxWidth: CGFloat = 1920, boxHeight: CGFloat = 1600, boxTop: CGFloat = 100
        let inset: CGFloat = 25, tallInset: CGFloat = 60, maxOverflow: CGFloat = 150
        let preferredWidth = boxWidth - 2 * inset
        let frontRatio = front.height / front.width, backRatio = back.height / back.width
        let tallerRatio = max(frontRatio, backRatio), widerRatio = min(frontRatio, backRatio)
        let matchHeight = preferredWidth * tallerRatio > boxHeight
        let heightAtTallInset = (boxWidth - 2 * tallInset) * widerRatio
        let topAligned = matchHeight && heightAtTallInset > boxHeight
        let verticalInset = (boxHeight - preferredWidth * tallerRatio) / 2
        let width = verticalInset > 250 ? boxWidth : min(preferredWidth, (boxHeight - 2 * inset) / tallerRatio)
        // 同高时以较宽的一面限制宽度，另一面可以有更多侧边留白。
        let height = topAligned ? min(heightAtTallInset, boxHeight + maxOverflow) : min(preferredWidth * widerRatio, boxHeight)
        let frames = sizes.enumerated().map { index, size in
            let w = matchHeight ? height * (size.width / size.height) : width
            let h = matchHeight ? height : width * (size.height / size.width)
            let centerX: CGFloat = index == 0 ? 1000 : 3000
            let y = topAligned ? boxTop : boxTop + (boxHeight - h) / 2
            return CGRect(x: centerX - w / 2, y: y, width: w, height: h)
        }
        return Placement(frames: frames, matchHeight: matchHeight, topAligned: topAligned,
                         bottomLimit: boxTop + boxHeight + (topAligned ? maxOverflow : 0))
    }
}
