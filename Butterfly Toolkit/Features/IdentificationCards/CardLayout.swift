// 图鉴初始布局：可见轮廓中心对齐，长形优先统一高度，避让文字由 Photoshop 的 Alpha 选择区完成。
import Foundation
import CoreGraphics

nonisolated enum CardLayout {
    static func frames(front: CGSize, back: CGSize) -> [CGRect] {
        let sizes = [front,back]
        guard sizes.allSatisfy({ $0.width > 0 && $0.height > 0 }) else { return [] }
        let tall = sizes.contains { $0.height * 1880 / $0.width > 1600 }
        let height = min(1750, sizes.map { 1880 * $0.height / $0.width }.min()!)
        return sizes.enumerated().map { index, size in
            let scale = tall ? height / size.height : 1880 / size.width
            let w = size.width * scale, h = size.height * scale
            return CGRect(x: CGFloat(index == 0 ? 1000 : 3000) - w / 2, y: tall ? 100 : 900 - h / 2, width: w, height: h)
        }
    }
}
