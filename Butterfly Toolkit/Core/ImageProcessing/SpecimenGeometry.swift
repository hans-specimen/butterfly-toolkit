// 共用标本主体边界、翅顶扶正与真实背景裁切算法；不依赖 Photoshop、外部引擎或文件协议。

import Foundation
import CoreGraphics

nonisolated enum GeometryProcessingError: LocalizedError {
    case invalidImage(String)
    var errorDescription: String? { switch self { case .invalidImage(let text): text } }
}

/// 坐标 x 向右、y 向下；版本标识由调用方提供并负责验证。
nonisolated struct GeometryImageInput: Sendable {
    var sourceVersion: String
    var sourcePixelSize: CGSize
    var coordinateOrigin: CGPoint
    var cropViewport: CGRect
}

// MARK: - 几何请求与坐标约定
nonisolated enum GeometryRatio: String, Codable, CaseIterable, Sendable {
    case adaptive, fiveByFour, elevenByEightPointFive, square
}

nonisolated enum GeometryAngleStrategy: Codable, Equatable, Sendable {
    case automaticWingTips
    case twoPoints(left: CGPoint, right: CGPoint)
    case manual(degrees: Double)
}

nonisolated struct GeometryRequest: Codable, Equatable, Sendable {
    var ratio: GeometryRatio = .adaptive
    var targetMargin: Double = 0.1
    var angleStrategy: GeometryAngleStrategy = .automaticWingTips
    var centerOverride: CGPoint?
}

/// 左右留白以输出宽度占比表示，上下留白以输出高度占比表示，均不是像素距离。
nonisolated struct WorkflowMargins: Codable, Equatable, Sendable {
    var left: Double
    var top: Double
    var right: Double
    var bottom: Double
}

nonisolated struct GeometrySolution: Codable, Equatable, Sendable {
    var sourceVersion: String
    /// 相对于指定保存快照的增量角度，不能据此重复执行已经完成的 PS 编辑。
    var angleDegrees: Double
    /// 采用源图坐标：x 向右、y 向下，正角度绕此中心顺时针旋转。
    var rotationPivot: CGPoint
    var leftWingTip: CGPoint?
    var rightWingTip: CGPoint?
    /// 主体边界与裁切框位于旋转后的源图平面，尚未平移裁切原点。
    var subjectBounds: CGRect
    var sourceCropRect: CGRect
    var outputSize: CGSize
    var actualMargins: WorkflowMargins
    var isApplicable: Bool
    var reason: String?
}

/// 仅用于分析的主体支持区域，也供导出布局复用，不能替换可编辑的 alpha。
nonisolated struct MeaningfulMaskSupport: Sendable {
    let pixels: [UInt8]
    let bounds: CGRect
    let width: Int
    let height: Int
    let coordinateOrigin: CGPoint
    let componentCount: Int
    /// 额外保留的小碎片需要人工检查；渲染仍使用原始 alpha。
    let detachedDetailCount: Int
    let wingBounds: CGRect
    let wingComponentCount: Int
    fileprivate let wingPixels: [UInt8]
    private let rowMin: [Int]
    private let rowMax: [Int]
    fileprivate var estimatedStorageBytes: Int { pixels.count + wingPixels.count + (rowMin.count + rowMax.count) * MemoryLayout<Int>.stride }

    init(values: [UInt8],width: Int,height: Int,origin: CGPoint) throws {
        // 此入口也处理人工保存和旧批次：完整范围必须包含每个实际非零 Alpha，不能再暗中清理。
        let core = try MaskResidueCleanup.trustedCore(values,width: width,height: height)
        let hasCore = core.contains(1)
        guard hasCore || values.lazy.filter({ $0 > 0 }).prefix(16).count == 16 else {
            throw GeometryProcessingError.invalidImage("蒙版没有可靠主体")
        }
        self.width = width; self.height = height; coordinateOrigin = origin
        var visited = [UInt8](repeating: 0,count: values.count),queue = [Int32]()
        var count = 0,wingCount = 0
        for start in values.indices {
            if start%65536 == 0 { try Task.checkCancellation() }
            guard values[start] > 0,visited[start] == 0 else { continue }
            count += 1; var hasCore = false,head = 0
            queue.removeAll(keepingCapacity: true); queue.append(Int32(start)); visited[start] = 1
            while head < queue.count {
                let i = Int(queue[head]); head += 1
                if head%65536 == 0 { try Task.checkCancellation() }
                hasCore = hasCore || core[i] > 0
                let x = i%width,y = i/width
                for ny in max(0,y-1)...min(height-1,y+1) { for nx in max(0,x-1)...min(width-1,x+1) {
                    let next = ny*width+nx
                    if values[next] > 0,visited[next] == 0 { visited[next] = 1; queue.append(Int32(next)) }
                } }
            }
            if hasCore { wingCount += 1 }
        }
        componentCount = count; wingComponentCount = wingCount; detachedDetailCount = count-wingCount
        var rowsMin = [Int](repeating: width,count: height),rowsMax = [Int](repeating: -1,count: height)
        var minX = width,minY = height,maxX = 0,maxY = 0
        var wingMinX = width,wingMinY = height,wingMaxX = 0,wingMaxY = 0
        for i in values.indices {
            if i%65536 == 0 { try Task.checkCancellation() }
            guard values[i] > 0 else { continue }
            let x = i%width,y = i/width
            if core[i] > 0 {
                wingMinX = min(wingMinX,x); wingMinY = min(wingMinY,y)
                wingMaxX = max(wingMaxX,x+1); wingMaxY = max(wingMaxY,y+1)
            }
            rowsMin[y] = min(rowsMin[y],x); rowsMax[y] = max(rowsMax[y],x)
            minX = min(minX,x); minY = min(minY,y); maxX = max(maxX,x+1); maxY = max(maxY,y+1)
        }
        pixels = visited; wingPixels = core; rowMin = rowsMin; rowMax = rowsMax
        bounds = CGRect(x: origin.x+Double(minX),y: origin.y+Double(minY),width: Double(maxX-minX),height: Double(maxY-minY))
        // 人工半透明成品仍能布局导出；无强核心时方向估计自然回退为原角度。
        wingBounds = hasCore ? CGRect(x: origin.x+Double(wingMinX),y: origin.y+Double(wingMinY),width: Double(wingMaxX-wingMinX),height: Double(wingMaxY-wingMinY)) : bounds
    }

    func rotatedBounds(angle: Double,pivot: CGPoint) -> CGRect {
        if abs(angle) < 1e-10 { return bounds }
        var minX = Double.infinity,minY = Double.infinity,maxX = -Double.infinity,maxY = -Double.infinity
        let transform = GeometryRotation(degrees: angle,pivot: pivot)
        // 逐行极值足以计算仿射变换后的边界，同时保留完整分辨率的细小连通附属物。
        for y in 0..<height {
            let left = rowMin[y],right = rowMax[y]
            if right < 0 { continue }
            for p in [CGPoint(x: Double(left)+coordinateOrigin.x,y: Double(y)+coordinateOrigin.y),
                      CGPoint(x: Double(right+1)+coordinateOrigin.x,y: Double(y)+coordinateOrigin.y),
                      CGPoint(x: Double(left)+coordinateOrigin.x,y: Double(y+1)+coordinateOrigin.y),
                      CGPoint(x: Double(right+1)+coordinateOrigin.x,y: Double(y+1)+coordinateOrigin.y)] {
                let q = transform.apply(p)
                minX = min(minX,q.x); maxX = max(maxX,q.x); minY = min(minY,q.y); maxY = max(maxY,q.y)
            }
        }
        return CGRect(x: minX,y: minY,width: maxX-minX,height: maxY-minY)
    }
}

// MARK: - 内存像素入口
nonisolated enum SpecimenGeometry {
    static func prepare(input: GeometryImageInput,mask: [UInt8],backgroundAlpha: [UInt8]? = nil) throws -> PreparedMaskGeometry {
        let size = input.sourcePixelSize
        guard size.width.isFinite,size.height.isFinite,size.width > 0,size.height > 0,
              size.width <= Double(Int32.max),size.height <= Double(Int32.max),
              size.width.rounded() == size.width,size.height.rounded() == size.height,
              !input.sourceVersion.isEmpty,input.coordinateOrigin.x.isFinite,input.coordinateOrigin.y.isFinite,
              !input.cropViewport.isNull,!input.cropViewport.isInfinite,
              input.cropViewport.origin.x.isFinite,input.cropViewport.origin.y.isFinite,
              input.cropViewport.width.isFinite,input.cropViewport.height.isFinite,
              input.cropViewport.width > 0,input.cropViewport.height > 0 else {
            throw GeometryProcessingError.invalidImage("图像尺寸、版本或坐标无效")
        }
        let w = Int(size.width),h = Int(size.height)
        guard mask.count == w*h,backgroundAlpha.map({ $0.count == mask.count }) ?? true else {
            throw GeometryProcessingError.invalidImage("蒙版与背景尺寸不符")
        }
        let support = try MeaningfulMaskSupport(values: mask,width: w,height: h,origin: input.coordinateOrigin)
        return PreparedMaskGeometry(input: input,support: support,maskValues: mask,
            background: GeometryBackground(alpha: backgroundAlpha ?? [],width: w,height: h,origin: input.coordinateOrigin))
    }
}

// MARK: - 构图求解与已保存方案校验
nonisolated struct PreparedMaskGeometry: Sendable {
    let input: GeometryImageInput
    let support: MeaningfulMaskSupport
    private let columnTops: [Int]
    private let columnCounts: [Int]
    private let leftArea: Int
    private let rightArea: Int
    private let background: GeometryBackground
    /// 仅统计保留的数组数据，不包含临时解码、标签缓冲区及分配器开销。
    var estimatedStorageBytes: Int {
        support.estimatedStorageBytes + (columnTops.count + columnCounts.count) * MemoryLayout<Int>.stride
            + (background.invalid?.count ?? 0) * MemoryLayout<UInt32>.stride
    }
    fileprivate init(input: GeometryImageInput,support: MeaningfulMaskSupport,maskValues: [UInt8],background: GeometryBackground) {
        self.input = input; self.support = support; self.background = background
        let w = support.width,h = support.height,mid = support.wingBounds.midX-input.coordinateOrigin.x
        var tops = [Int](repeating: h,count: w),counts = [Int](repeating: 0,count: w),runs = [Int](repeating: 0,count: w),la = 0,ra = 0
        let depth = max(3,Int(support.wingBounds.height*0.06))
        // 翅缘下方应有连续实体区域，用此条件排除斜向单像素触角。
        for y in stride(from: h-1,through: 0,by: -1) { for x in 0..<w {
            if support.wingPixels[y*w+x] != 0 && maskValues[y*w+x] >= 128 {
                counts[x] += 1; runs[x] += 1
                if runs[x] >= depth { tops[x] = y }
                if Double(x) < mid { la += 1 } else { ra += 1 }
            } else { runs[x] = 0 }
        } }
        columnTops = tops; columnCounts = counts; leftArea = la; rightArea = ra
    }

    func analyze(request: GeometryRequest) throws -> GeometrySolution {
        try Task.checkCancellation()
        guard request.targetMargin.isFinite,(0..<0.5).contains(request.targetMargin),
              request.centerOverride.map({ $0.x.isFinite && $0.y.isFinite }) ?? true else {
            throw GeometryProcessingError.invalidImage("留白或中心参数无效")
        }
        let extent = CGRect(origin: input.coordinateOrigin,size: input.sourcePixelSize)
        let pivot = CGPoint(x: extent.midX,y: extent.midY)
        var angle = 0.0,left: CGPoint?,right: CGPoint?,review: String?
        switch request.angleStrategy {
        case .manual(let degrees):
            guard degrees.isFinite else { throw GeometryProcessingError.invalidImage("角度无效") }
            angle = degrees.truncatingRemainder(dividingBy: 360)
        case .twoPoints(let l,let r):
            guard l.x.isFinite,l.y.isFinite,r.x.isFinite,r.y.isFinite,r.x-l.x > 1,
                  extent.contains(l),extent.contains(r) else { throw GeometryProcessingError.invalidImage("请选择源图内左右两个不同翅顶") }
            left = l; right = r; angle = -atan2(r.y-l.y,r.x-l.x)*180 / .pi
        case .automaticWingTips:
            (left,right,review) = wingTips()
            if review == nil,let l = left,let r = right { angle = -atan2(r.y-l.y,r.x-l.x)*180 / .pi }
        }
        if support.detachedDetailCount > 0 {
            review = [review,"完整范围含分离细节，请检查蒙版"].compactMap { $0 }.joined(separator: "；")
        }
        let bounds = support.rotatedBounds(angle: angle,pivot: pivot)
        let center = request.centerOverride ?? CGPoint(x: bounds.midX,y: bounds.midY)
        let units: (Int,Int)?
        switch request.ratio {
        case .adaptive: units = nil
        case .fiveByFour: units = (5,4)
        case .elevenByEightPointFive: units = (22,17)
        case .square: units = (1,1)
        }
        func solution(crop: CGRect,applicable: Bool,reason: String?) -> GeometrySolution {
            let b = applicable ? bounds : support.bounds
            let margins = WorkflowMargins(left: (b.minX-crop.minX)/crop.width,top: (b.minY-crop.minY)/crop.height,
                                          right: (crop.maxX-b.maxX)/crop.width,bottom: (crop.maxY-b.maxY)/crop.height)
            let insufficient = applicable && min(margins.left,margins.top,margins.right,margins.bottom) < request.targetMargin-1/min(crop.width,crop.height)
            let paddingWarning = insufficient && !(reason?.contains("留白不足") ?? false) ? "留白不足：完整主体已保留，原图有效背景不足以达到目标留白" : nil
            let details = [reason,paddingWarning].compactMap { $0 }
            let detail = details.isEmpty ? nil : details.joined(separator: "；")
            return GeometrySolution(sourceVersion: input.sourceVersion,angleDegrees: applicable ? angle : 0,rotationPivot: pivot,
                leftWingTip: left,rightWingTip: right,subjectBounds: b,sourceCropRect: crop,outputSize: crop.size,
                actualMargins: margins,isApplicable: applicable,reason: detail)
        }
        let minW = Int(ceil(bounds.maxX-1e-8)-floor(bounds.minX+1e-8)),minH = Int(ceil(bounds.maxY-1e-8)-floor(bounds.minY+1e-8))
        let factor = 1-2*request.targetMargin
        // 有效旋转源区域的边长不会超过原宽高之和；转为 Int 前限制不可实现的留白请求。
        let maximumSide = input.sourcePixelSize.width+input.sourcePixelSize.height+2
        let low: Int,high: Int
        let size: (Int) -> (Int,Int)
        if let (uw,uh) = units {
            low = max((minW+uw-1)/uw,(minH+uh-1)/uh)
            high = max(low,Int(ceil(min(maximumSide/Double(min(uw,uh)),max(bounds.width/factor/Double(uw),bounds.height/factor/Double(uh)))-1e-8)))
            size = { ($0*uw,$0*uh) }
        } else {
            let targetW = max(minW,Int(ceil(min(maximumSide,bounds.width/factor)-1e-8))),targetH = max(minH,Int(ceil(min(maximumSide,bounds.height/factor)-1e-8)))
            low = 0; high = max(targetW-minW,targetH-minH)
            size = { step in
                guard high > 0 else { return (minW,minH) }
                return (minW+Int(ceil(Double(targetW-minW)*Double(step)/Double(high))),
                        minH+Int(ceil(Double(targetH-minH)*Double(step)/Double(high))))
            }
        }
        func crop(_ step: Int) throws -> CGRect? {
            let (w,h) = size(step)
            return try background.findCrop(width: w,height: h,containing: bounds,center: center,angle: angle,pivot: pivot,allowRepositioning: request.centerOverride != nil)
        }
        if let target = try crop(high) { return solution(crop: target,applicable: true,reason: review) }
        guard var best = try crop(low) else {
            let failure = units == nil ? "构图需调整：完整主体范围没有不露空的裁切结果" : "比例无法容纳主体：所选比例没有完整且不露空的裁切结果"
            return solution(crop: input.cropViewport,applicable: false,reason: [review,failure].compactMap { $0 }.joined(separator: "；"))
        }
        // 目标留白无法实现时，在可行最小框与目标框之间搜索更大的有效裁切。
        var a = low,b = high
        while a+1 < b {
            let mid = (a+b)/2
            if let candidate = try crop(mid) { a = mid; best = candidate } else { b = mid }
        }
        return solution(crop: best,applicable: true,reason: [review,"留白不足：完整主体已保留，原图有效背景不足以达到目标留白"].compactMap { $0 }.joined(separator: "；"))
    }

    /// 精确校验已保存的构图，不重新估算翅顶或另选裁切框。
    @discardableResult
    func validate(solution: GeometrySolution) throws -> GeometrySolution {
        let rect = solution.sourceCropRect
        guard solution.sourceVersion == input.sourceVersion, solution.isApplicable,
              solution.angleDegrees.isFinite, solution.rotationPivot.x.isFinite, solution.rotationPivot.y.isFinite,
              rect == rect.integral, rect.size == solution.outputSize,
              rect.width > 0, rect.height > 0,
              rect.contains(support.rotatedBounds(angle: solution.angleDegrees,pivot: solution.rotationPivot)),
              background.isValid(rect,rotation: GeometryRotation(degrees: solution.angleDegrees,pivot: solution.rotationPivot)) else {
            throw GeometryProcessingError.invalidImage("当前蒙版或真实背景不再适合此构图，请调整后重新确认")
        }
        var current = solution
        let bounds = support.rotatedBounds(angle: solution.angleDegrees,pivot: solution.rotationPivot)
        current.subjectBounds = bounds
        current.actualMargins = WorkflowMargins(left: (bounds.minX-rect.minX)/rect.width,top: (bounds.minY-rect.minY)/rect.height,
            right: (rect.maxX-bounds.maxX)/rect.width,bottom: (rect.maxY-bounds.maxY)/rect.height)
        return current
    }

    private func wingTips() -> (CGPoint?,CGPoint?,String?) {
        let b = support.wingBounds,o = input.coordinateOrigin
        let mid = b.midX-o.x,tops = columnTops,counts = columnCounts
        func point(left: Bool) -> CGPoint? {
            let x0 = Int(b.minX-o.x),x1 = Int(b.maxX-o.x)
            let candidates = (x0..<x1).filter { x in
                guard (left ? Double(x) < mid-b.width*0.08 : Double(x) > mid+b.width*0.08),
                      Double(counts[x]) >= b.height*0.12,tops[x] < support.height else { return false }
                let radius = max(2,Int(b.width*0.01)),neighbors = max(0,x-radius)...min(support.width-1,x+radius)
                let coherent = neighbors.filter { abs(tops[$0]-tops[x]) <= Int(b.height*0.04) }.count
                // 细长竖直触角可能满足深度条件，但周围缺少足够宽的连续上缘。
                return Double(coherent) >= Double(neighbors.count)*0.65
            }
            guard let top = candidates.map({ tops[$0] }).min() else { return nil }
            let crest = candidates.filter { tops[$0] <= top+1 }
            guard !crest.isEmpty,
                  !zip(crest,crest.dropFirst()).contains(where: { $0.1-$0.0 > max(2,Int(b.width*0.02)) }) else { return nil }
            // 选择真实轮廓像素，避免对分离峰值取平均后落在空白处。
            let x = crest[crest.count/2]
            return CGPoint(x: Double(x)+o.x+0.5,y: Double(tops[x])+o.y)
        }
        let l = point(left: true),r = point(left: false)
        guard let l,let r else { return (l,r,"角度需调整：无法可靠定位左右翅膀上缘") }
        let balance = Double(min(leftArea,rightArea))/Double(max(1,max(leftArea,rightArea)))
        let extent = CGRect(origin: o,size: input.sourcePixelSize)
        let touchesEdge = b.minX <= extent.minX || b.minY <= extent.minY || b.maxX >= extent.maxX || b.maxY >= extent.maxY
        guard support.wingComponentCount == 1,balance >= 0.65,abs(r.y-l.y) <= b.height*0.2,
              r.x-l.x >= b.width*0.45,!touchesEdge else {
            return (l,r,"角度需调整：翅区缺损、不对称或完整性不确定，已保留原角度")
        }
        return (l,r,nil)
    }
}

// MARK: - 连通细节与背景几何
private nonisolated struct GeometryRotation {
    let c: Double,s: Double,pivot: CGPoint
    init(degrees: Double,pivot: CGPoint) {
        let a = degrees * .pi / 180
        let rawC = cos(a),rawS = sin(a)
        c = abs(rawC) < 1e-12 ? 0 : rawC; s = abs(rawS) < 1e-12 ? 0 : rawS; self.pivot = pivot
    }
    func apply(_ p: CGPoint) -> CGPoint {
        CGPoint(x: pivot.x+c*(p.x-pivot.x)-s*(p.y-pivot.y),y: pivot.y+s*(p.x-pivot.x)+c*(p.y-pivot.y))
    }
    func inverse(_ p: CGPoint) -> CGPoint {
        CGPoint(x: pivot.x+c*(p.x-pivot.x)+s*(p.y-pivot.y),y: pivot.y-s*(p.x-pivot.x)+c*(p.y-pivot.y))
    }
}

private nonisolated struct GeometryBackground: Sendable {
    let width: Int,height: Int,origin: CGPoint
    /// 源坐标系中的无效像素积分表；完全不透明的源图不需要分配此表。
    let invalid: [UInt32]?
    init(alpha: [UInt8],width: Int,height: Int,origin: CGPoint) {
        self.width = width; self.height = height; self.origin = origin
        if !alpha.contains(where: { $0 != 255 }) { invalid = nil; return }
        var sums = [UInt32](repeating: 0,count: (width+1)*(height+1))
        for y in 0..<height {
            var row: UInt32 = 0
            for x in 0..<width {
                if alpha[y*width+x] != 255 { row += 1 }
                sums[(y+1)*(width+1)+x+1] = sums[y*(width+1)+x+1]+row
            }
        }
        invalid = sums
    }
    func findCrop(width cw: Int,height ch: Int,containing b: CGRect,center: CGPoint,angle: Double,pivot: CGPoint,allowRepositioning: Bool) throws -> CGRect? {
        let rotation = GeometryRotation(degrees: angle,pivot: pivot)
        if !allowRepositioning {
            // 自动构图保持主体居中，由调用方缩减留白以适应真实背景。
            let x = (center.x-Double(cw)/2).rounded(),y = (center.y-Double(ch)/2).rounded()
            let rect = CGRect(x: x,y: y,width: Double(cw),height: Double(ch))
            return rect.contains(b) && isValid(rect,rotation: rotation) ? rect : nil
        }
        let domain = [CGPoint(x: origin.x,y: origin.y),CGPoint(x: origin.x+Double(width),y: origin.y),
                      CGPoint(x: origin.x+Double(width),y: origin.y+Double(height)),CGPoint(x: origin.x,y: origin.y+Double(height))].map { rotation.apply($0) }
        let x0 = max(Int(ceil(b.maxX-Double(cw)-1e-8)),Int(ceil(domain.map(\.x).min()!-1e-8)))
        let x1 = min(Int(floor(b.minX+1e-8)),Int(floor(domain.map(\.x).max()!-Double(cw)+1e-8)))
        let y0 = max(Int(ceil(b.maxY-Double(ch)-1e-8)),Int(ceil(domain.map(\.y).min()!-1e-8)))
        let y1 = min(Int(floor(b.minY+1e-8)),Int(floor(domain.map(\.y).max()!-Double(ch)+1e-8)))
        guard x0 <= x1,y0 <= y1 else { return nil }
        let desiredX = min(x1,max(x0,Int(round(center.x-Double(cw)/2)))),desiredY = min(y1,max(y0,Int(round(center.y-Double(ch)/2))))
        func attempt(_ y: Int) -> CGRect? {
            // 反向旋转后的四角给出 x 的线性约束，避免扫描旋转产生的空角。
            var lo = Double(x0),hi = Double(x1)
            for dx in [0.0,Double(cw)] { for dy in [0.0,Double(ch)] {
                let q = rotation.inverse(CGPoint(x: dx,y: Double(y)+dy))
                for (coefficient,constant,minimum,maximum) in [(rotation.c,q.x,origin.x,origin.x+Double(width)),(-rotation.s,q.y,origin.y,origin.y+Double(height))] {
                    if abs(coefficient) < 1e-12 {
                        if constant < minimum-1e-8 || constant > maximum+1e-8 { return nil }
                    } else {
                        let a = (minimum-constant)/coefficient,b = (maximum-constant)/coefficient
                        lo = max(lo,min(a,b)); hi = min(hi,max(a,b))
                    }
                }
            } }
            let first = Int(ceil(lo-1e-8)),last = Int(floor(hi+1e-8))
            guard first <= last else { return nil }
            let wanted = min(last,max(first,desiredX))
            for distance in 0...max(wanted-first,last-wanted) {
                for x in distance == 0 ? [wanted] : [wanted-distance,wanted+distance] where x >= first && x <= last {
                    let rect = CGRect(x: x,y: y,width: cw,height: ch)
                    if isValid(rect,rotation: rotation) { return rect }
                }
            }
            return nil
        }
        for distance in 0...max(desiredY-y0,y1-desiredY) {
            try Task.checkCancellation()
            for y in distance == 0 ? [desiredY] : [desiredY-distance,desiredY+distance] where y >= y0 && y <= y1 {
                if let result = attempt(y) { return result }
            }
        }
        return nil
    }
    fileprivate func isValid(_ rect: CGRect,rotation: GeometryRotation) -> Bool {
        let polygon = [CGPoint(x: rect.minX,y: rect.minY),CGPoint(x: rect.maxX,y: rect.minY),CGPoint(x: rect.maxX,y: rect.maxY),CGPoint(x: rect.minX,y: rect.maxY)].map { rotation.inverse($0) }
        guard polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
            $0.x >= origin.x-1e-8 && $0.x <= origin.x+Double(width)+1e-8 &&
            $0.y >= origin.y-1e-8 && $0.y <= origin.y+Double(height)+1e-8 }) else { return false }
        guard let invalid else { return true }
        let stride = width+1
        func empty(x0: Int,y0: Int,x1: Int,y1: Int) -> Bool {
            let a = invalid[y1*stride+x1],b = invalid[y0*stride+x1],c = invalid[y1*stride+x0],d = invalid[y0*stride+x0]
            return Int64(a)+Int64(d)-Int64(b)-Int64(c) == 0
        }
        let minY = max(0,Int(floor(polygon.map(\.y).min()!-origin.y+1e-8))),maxY = min(height,Int(ceil(polygon.map(\.y).max()!-origin.y-1e-8)))
        if abs(rotation.s) < 1e-10 || abs(rotation.c) < 1e-10 {
            let minX = max(0,Int(floor(polygon.map(\.x).min()!-origin.x+1e-8))),maxX = min(width,Int(ceil(polygon.map(\.x).max()!-origin.x-1e-8)))
            return empty(x0: minX,y0: minY,x1: maxX,y1: maxY)
        }
        // 逆变换矩形触及的每个源像素都必须具有不透明的真实背景。
        for row in minY..<maxY {
            let lower = origin.y+Double(row),upper = lower+1
            var xs: [Double] = []
            for i in polygon.indices {
                let a = polygon[i],b = polygon[(i+1)%polygon.count]
                if a.y >= lower && a.y <= upper { xs.append(a.x) }
                for y in [lower,upper] where y >= min(a.y,b.y) && y <= max(a.y,b.y) && abs(b.y-a.y) > 1e-12 {
                    xs.append(a.x+(b.x-a.x)*(y-a.y)/(b.y-a.y))
                }
            }
            guard let first = xs.min(),let last = xs.max() else { continue }
            let x0 = max(0,Int(floor(first-origin.x+1e-8))),x1 = min(width,Int(ceil(last-origin.x-1e-8)))
            if !empty(x0: x0,y0: row,x1: x1,y1: row+1) { return false }
        }
        return true
    }
}
