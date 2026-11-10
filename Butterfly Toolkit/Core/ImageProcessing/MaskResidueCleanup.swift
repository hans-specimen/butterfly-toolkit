// 按可信轮廓距离分类外部残留；仅删除证据充分的背景，逐像素保留不确定细节。
import Foundation
import CoreGraphics

nonisolated enum MaskCleanupDecision: String, Codable, Sendable { case removedBackground, retainedDetail, uncertain }
nonisolated enum MaskCleanupReason: String, Codable, Sendable {
    case remoteHaze, edgeBand, nearContourDetail, connectedDetail, ambiguousConnection, noReliableCore
}
nonisolated struct MaskCleanupRegion: Codable, Equatable, Sendable {
    var bounds: CGRect
    var pixelCount: Int
    var decision: MaskCleanupDecision
    var reason: MaskCleanupReason
}
nonisolated struct MaskCleanupReport: Codable, Equatable, Sendable {
    var algorithmVersion: Int
    var removedPixelCount: Int
    var regions: [MaskCleanupRegion]
    var pixelSize: CGSize = .zero
}
nonisolated struct MaskCleanupResult: Sendable {
    var alpha: [UInt8]
    var subjectSupport: [UInt8]
    var coreSupport: [UInt8]
    var report: MaskCleanupReport
}

nonisolated enum MaskResidueCleanup {
    static let algorithmVersion = 1
    // MARK: - 固定策略（距离以最长边归一，Alpha 为 8 bit）
    private enum Policy {
        static let seed: UInt8 = 128
        static let reconstruction: UInt8 = 32
        static let hazeMean = 8.0,hazePercentile = 16
        static let bandMean = 16.0,bandPercentile = 64,bandBrightFraction = 0.1
        static let bandMinimumThickness = 3.0,bandMaximumThicknessFraction = 0.005,bandAspect = 12.0
        static let edgeLengthFraction = 0.05,elongation = 9.0,sparseFraction = 0.35
        static func halo(_ width: Int,_ height: Int) -> Int { max(3,Int(ceil(Double(max(width,height))*0.01))) }
    }
    static func clean(_ values: [UInt8],width: Int,height: Int) throws -> [UInt8] {
        try analyze(values,width: width,height: height).alpha
    }
    private static func validate(_ values: [UInt8],_ width: Int,_ height: Int) throws {
        try Task.checkCancellation()
        guard width > 0,height > 0,width <= Int.max/height,values.count == width*height,
              values.count <= Int(Int32.max) else { throw GeometryProcessingError.invalidImage("蒙版尺寸不符") }
    }

    // MARK: - 多阈值可信核心（几何分析也使用，不执行清理）
    static func trustedCore(_ values: [UInt8],width: Int,height: Int) throws -> [UInt8] {
        try validate(values,width,height)
        var labels = [Int32](repeating: 0,count: values.count),strong = [0]
        var queue = [Int32](); queue.reserveCapacity(values.count/4)
        for start in values.indices {
            if start%65536 == 0 { try Task.checkCancellation() }
            guard values[start] >= Policy.reconstruction,labels[start] == 0 else { continue }
            let label = Int32(strong.count)
            queue.removeAll(keepingCapacity: true); queue.append(Int32(start)); labels[start] = label
            var head = 0,count = 0
            while head < queue.count {
                let i = Int(queue[head]); head += 1
                if head%65536 == 0 { try Task.checkCancellation() }
                if values[i] >= Policy.seed { count += 1 }
                let x = i%width,y = i/width
                for ny in max(0,y-1)...min(height-1,y+1) { for nx in max(0,x-1)...min(width-1,x+1) {
                    let next = ny*width+nx
                    if values[next] >= Policy.reconstruction,labels[next] == 0 { labels[next] = label; queue.append(Int32(next)) }
                } }
            }
            strong.append(count)
        }
        let minimum = max(16,(strong.max() ?? 0)/1000)
        var core = [UInt8](repeating: 0,count: values.count)
        for i in core.indices {
            if i%65536 == 0 { try Task.checkCancellation() }
            if strong[Int(labels[i])] >= minimum { core[i] = 1 }
        }
        return core
    }

    // MARK: - 连通区域分类
    static func analyze(_ values: [UInt8],width: Int,height: Int) throws -> MaskCleanupResult {
        let core = try trustedCore(values,width: width,height: height)
        var report = MaskCleanupReport(algorithmVersion: algorithmVersion,removedPixelCount: 0,regions: [],pixelSize: CGSize(width: width,height: height))
        guard core.contains(1) else {
            report.regions = [MaskCleanupRegion(bounds: CGRect(x: 0,y: 0,width: width,height: height),pixelCount: values.filter { $0 > 0 }.count,decision: .uncertain,reason: .noReliableCore)]
            return MaskCleanupResult(alpha: values,subjectSupport: values.map { $0 > 0 ? 1 : 0 },coreSupport: core,report: report)
        }
        let halo = Policy.halo(width,height),distance = try contourDistance(core,width: width,height: height,limit: halo*3+1)
        var visited = [UInt8](repeating: 0,count: values.count),alpha = values
        var queue = [Int32](); queue.reserveCapacity(values.count/4)
        for start in values.indices {
            if start%65536 == 0 { try Task.checkCancellation() }
            guard values[start] > 0,visited[start] == 0 else { continue }
            queue.removeAll(keepingCapacity: true); queue.append(Int32(start)); visited[start] = 1
            var head = 0,sum = 0,coreCount = 0,near = false,high = 0
            var histogram = [Int](repeating: 0,count: 256)
            var x0 = width,y0 = height,x1 = 0,y1 = 0
            var farX0 = width,farY0 = height,farX1 = 0,farY1 = 0,farCount = 0
            var sx = 0.0,sy = 0.0,sxx = 0.0,syy = 0.0,sxy = 0.0
            while head < queue.count {
                let i = Int(queue[head]); head += 1
                if head%65536 == 0 { try Task.checkCancellation() }
                let x = i%width,y = i/width,v = Int(values[i]),dx = Double(x),dy = Double(y)
                sum += v; histogram[v] += 1; if v >= 64 { high += 1 }; coreCount += Int(core[i])
                near = near || distance[i] <= halo*3
                x0 = min(x0,x); y0 = min(y0,y); x1 = max(x1,x+1); y1 = max(y1,y+1)
                sx += dx; sy += dy; sxx += dx*dx; syy += dy*dy; sxy += dx*dy
                if distance[i] > halo*3 {
                    farCount += 1; farX0 = min(farX0,x); farY0 = min(farY0,y); farX1 = max(farX1,x+1); farY1 = max(farY1,y+1)
                }
                for ny in max(0,y-1)...min(height-1,y+1) { for nx in max(0,x-1)...min(width-1,x+1) {
                    let next = ny*width+nx
                    if values[next] > 0,visited[next] == 0 { visited[next] = 1; queue.append(Int32(next)) }
                } }
            }
            let n = queue.count,mean = Double(sum)/Double(n)
            var cumulative = 0,p90 = 0
            for v in 1...255 { cumulative += histogram[v]; if cumulative*10 >= n*9 { p90 = v; break } }
            let bounds = CGRect(x: x0,y: y0,width: x1-x0,height: y1-y0)
            let vx = max(0,sxx/Double(n)-pow(sx/Double(n),2)),vy = max(0,syy/Double(n)-pow(sy/Double(n),2))
            let cov = sxy/Double(n)-sx*sy/pow(Double(n),2),delta = sqrt(pow(vx-vy,2)+4*cov*cov)
            let elongated = (vx+vy+delta)/2 >= Policy.elongation*max(0.25,(vx+vy-delta)/2)
            let sparse = Double(n) < bounds.width*bounds.height*Policy.sparseFraction
            let edgeBand = isEdgeBand(bounds,width: width,height: height,halo: halo)
            var diagnosticBounds = bounds,diagnosticCount = n
            let decision: MaskCleanupDecision,reason: MaskCleanupReason
            if coreCount > 0 {
                let far = CGRect(x: farX0,y: farY0,width: max(0,farX1-farX0),height: max(0,farY1-farY0))
                // 连到核心的弱桥不自动切断；对弱连接之后远处沿边延展的区域提示人工检查。
                let ambiguous = farCount >= 16 && touchesLongEdge(far,width: width,height: height,halo: halo)
                decision = ambiguous ? .uncertain : .retainedDetail
                reason = ambiguous ? .ambiguousConnection : .connectedDetail
                if ambiguous { diagnosticBounds = far; diagnosticCount = farCount }
            } else if near {
                decision = .retainedDetail; reason = .nearContourDetail
            } else if edgeBand && mean <= Policy.bandMean && p90 <= Policy.bandPercentile && Double(high)/Double(n) <= Policy.bandBrightFraction && histogram[128...255].allSatisfy({ $0 == 0 }) {
                decision = .removedBackground; reason = .edgeBand
            } else if !elongated && !sparse && mean <= Policy.hazeMean && p90 <= Policy.hazePercentile && high == 0 {
                decision = .removedBackground; reason = .remoteHaze
            } else {
                decision = .uncertain; reason = .ambiguousConnection
            }
            if decision == .removedBackground {
                for i in queue { alpha[Int(i)] = 0 }
                report.removedPixelCount += n
            }
            report.regions.append(MaskCleanupRegion(bounds: diagnosticBounds,pixelCount: diagnosticCount,decision: decision,reason: reason))
        }
        try Task.checkCancellation()
        return MaskCleanupResult(alpha: alpha,subjectSupport: alpha.map { $0 > 0 ? 1 : 0 },coreSupport: core,report: report)
    }
    private static func touchesLongEdge(_ b: CGRect,width: Int,height: Int,halo: Int) -> Bool {
        ((b.minY <= Double(halo) || b.maxY >= Double(height-halo)) && b.width >= max(16,Double(width)*Policy.edgeLengthFraction)) ||
        ((b.minX <= Double(halo) || b.maxX >= Double(width-halo)) && b.height >= max(16,Double(height)*Policy.edgeLengthFraction))
    }
    private static func isEdgeBand(_ b: CGRect,width: Int,height: Int,halo: Int) -> Bool {
        let thickness = max(5,Double(max(width,height))*Policy.bandMaximumThicknessFraction)
        // 一两像素宽的独立片段仍可能是真实触角，贴边不能成为删除理由。
        return min(b.width,b.height) >= Policy.bandMinimumThickness && touchesLongEdge(b,width: width,height: height,halo: halo) &&
            ((b.width >= b.height*Policy.bandAspect && b.height <= thickness) || (b.height >= b.width*Policy.bandAspect && b.width <= thickness))
    }

    // MARK: - 到实际轮廓的截断 3–4 距离变换（线性时间，2 byte/像素）
    private static func contourDistance(_ core: [UInt8],width: Int,height: Int,limit: Int) throws -> [UInt16] {
        let cap = UInt16(min(Int(UInt16.max)-4,limit))
        var d = core.map { $0 > 0 ? UInt16(0) : cap }
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                let i = y*width+x
                if x > 0 { d[i] = min(d[i],d[i-1]+3) }
                if y > 0 {
                    d[i] = min(d[i],d[i-width]+3)
                    if x > 0 { d[i] = min(d[i],d[i-width-1]+4) }
                    if x+1 < width { d[i] = min(d[i],d[i-width+1]+4) }
                }
            }
        }
        for y in stride(from: height-1,through: 0,by: -1) {
            try Task.checkCancellation()
            for x in stride(from: width-1,through: 0,by: -1) {
                let i = y*width+x
                if x+1 < width { d[i] = min(d[i],d[i+1]+3) }
                if y+1 < height {
                    d[i] = min(d[i],d[i+width]+3)
                    if x > 0 { d[i] = min(d[i],d[i+width-1]+4) }
                    if x+1 < width { d[i] = min(d[i],d[i+width+1]+4) }
                }
            }
        }
        return d
    }
}
