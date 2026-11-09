// 清除远离可信主体、完全由微弱 Alpha 组成的分离残留；保留连通边缘与临近细毛。
import Foundation
import CoreGraphics

nonisolated enum MaskResidueCleanup {
    static func clean(_ values: [UInt8],width: Int,height: Int) throws -> [UInt8] {
        guard width > 0,height > 0,width <= Int.max / height,values.count == width*height else {
            throw GeometryProcessingError.invalidImage("蒙版尺寸不符")
        }
        struct Component {
            var strong = 0
            var bounds = CGRect.null
        }
        var labels = [Int32](repeating: 0,count: values.count),components = [Component()]
        var queue = [Int](); queue.reserveCapacity(values.count/4)
        for start in values.indices where values[start] > 0 && labels[start] == 0 {
            let label = Int32(components.count)
            var component = Component(),head = 0,minX = width,minY = height,maxX = 0,maxY = 0
            queue.removeAll(keepingCapacity: true); queue.append(start); labels[start] = label
            while head < queue.count {
                let i = queue[head]; head += 1
                if head % 65536 == 0 { try Task.checkCancellation() }
                let x = i%width,y = i/width
                if values[i] >= 16 {
                    component.strong += 1
                    minX = min(minX,x); minY = min(minY,y); maxX = max(maxX,x+1); maxY = max(maxY,y+1)
                }
                for ny in max(0,y-1)...min(height-1,y+1) {
                    for nx in max(0,x-1)...min(width-1,x+1) {
                        let next = ny*width+nx
                        if values[next] > 0 && labels[next] == 0 { labels[next] = label; queue.append(next) }
                    }
                }
            }
            if component.strong > 0 { component.bounds = CGRect(x: minX,y: minY,width: maxX-minX,height: maxY-minY) }
            components.append(component)
        }
        let largest = components.map(\.strong).max() ?? 0
        // 没有可信主体时不猜测；后续主体/空蒙版校验仍负责拒绝不可靠输入。
        guard largest >= 16 else { return values }
        let minimum = max(16,largest/1000)
        let bounds = components.filter { $0.strong >= minimum }.reduce(CGRect.null) { $0.union($1.bounds) }
        let halo = max(3,ceil(Double(max(width,height))*0.01))
        let protected = bounds.insetBy(dx: -halo,dy: -halo)
        var keep = components.map { $0.strong > 0 }
        // 使用实际像素判断临近关系，不能让一个包围主体的大残留框蒙混过关。
        for i in values.indices where values[i] > 0 && !keep[Int(labels[i])] {
            if protected.contains(CGPoint(x: i%width,y: i/width)) { keep[Int(labels[i])] = true }
        }
        var result = values
        for i in values.indices where values[i] > 0 && !keep[Int(labels[i])] { result[i] = 0 }
        return result
    }
}
