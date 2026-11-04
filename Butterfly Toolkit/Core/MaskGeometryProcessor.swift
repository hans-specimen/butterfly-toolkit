import Foundation
import CoreGraphics

/// All coordinates refer to the identified current saved PSD, x right/y down.
nonisolated struct MaskGeometryInput: Sendable {
    var sourceVersion: String
    var sourcePixelSize: CGSize
    var maskURL: URL
    var validBackgroundAlphaURL: URL
    var coordinateOrigin: CGPoint
    /// Current saved visible canvas in the same PSD frame; may include empty regions.
    var cropViewport: CGRect
}

/// Analysis-only support. Never use this to replace the editable alpha. Reused by asset layout.
nonisolated struct MeaningfulMaskSupport: Sendable {
    let pixels: [UInt8]
    let bounds: CGRect
    let width: Int
    let height: Int
    let coordinateOrigin: CGPoint
    let componentCount: Int
    /// Newly retained small fragments need visual review; rendering still uses the original alpha.
    let detachedDetailCount: Int
    let wingBounds: CGRect
    let wingComponentCount: Int
    fileprivate let wingPixels: [UInt8]
    private let rowMin: [Int]
    private let rowMax: [Int]

    init(values: [UInt8],width: Int,height: Int,origin: CGPoint) throws {
        self.width = width; self.height = height; coordinateOrigin = origin
        var labels = [Int32](repeating: 0,count: values.count),components = [MaskComponent()]
        var queue = [Int](); queue.reserveCapacity(values.count / 4)
        // Hysteresis retains every >0 pixel connected to a substantial component, including alpha1 hair.
        for start in values.indices where values[start] > 0 && labels[start] == 0 {
            let label = Int32(components.count); var component = MaskComponent(),head = 0
            queue.removeAll(keepingCapacity: true); queue.append(start); labels[start] = label
            while head < queue.count {
                let index = queue[head]; head += 1
                if head % 65536 == 0 { try Task.checkCancellation() }
                let x = index % width,y = index / width
                component.count += 1
                if values[index] >= 16 { component.strong += 1 }
                let dx = Double(x),dy = Double(y)
                component.x0 = min(component.x0,x); component.x1 = max(component.x1,x+1)
                component.y0 = min(component.y0,y); component.y1 = max(component.y1,y+1)
                component.sx += dx; component.sy += dy
                component.sxx += dx*dx; component.syy += dy*dy; component.sxy += dx*dy
                for ny in max(0,y-1)...min(height-1,y+1) {
                    for nx in max(0,x-1)...min(width-1,x+1) {
                        let next = ny*width+nx
                        if labels[next] == 0 && values[next] > 0 { labels[next] = label; queue.append(next) }
                    }
                }
            }
            components.append(component)
        }
        guard let largest = components.map(\.strong).max(),largest >= 16 else { throw WorkflowBridgeError.invalidImage("蒙版没有可靠主体") }
        let minimum = max(16,largest / 1000)
        let wingKept = components.map { $0.strong >= minimum }
        // Complete bounds also retain credible detached detail; wing estimation keeps its robust noise filter.
        let kept = components.map { $0.strong >= minimum || $0.isPlausibleDetail }
        componentCount = kept.filter { $0 }.count
        wingComponentCount = wingKept.filter { $0 }.count
        detachedDetailCount = componentCount-wingComponentCount
        var result = [UInt8](repeating: 0,count: values.count),wing = result
        var wingMinX = width,wingMinY = height,wingMaxX = 0,wingMaxY = 0
        var rowsMin = [Int](repeating: width,count: height),rowsMax = [Int](repeating: -1,count: height)
        var minX = width,minY = height,maxX = 0,maxY = 0
        for i in values.indices where kept[Int(labels[i])] {
            result[i] = 1
            let x = i % width,y = i / width
            if wingKept[Int(labels[i])] {
                wing[i] = 1
                wingMinX = min(wingMinX,x); wingMinY = min(wingMinY,y)
                wingMaxX = max(wingMaxX,x+1); wingMaxY = max(wingMaxY,y+1)
            }
            rowsMin[y] = min(rowsMin[y],x); rowsMax[y] = max(rowsMax[y],x)
            minX = min(minX,x); maxX = max(maxX,x+1); minY = min(minY,y); maxY = max(maxY,y+1)
        }
        pixels = result; wingPixels = wing; rowMin = rowsMin; rowMax = rowsMax
        wingBounds = CGRect(x: origin.x+Double(wingMinX),y: origin.y+Double(wingMinY),width: Double(wingMaxX-wingMinX),height: Double(wingMaxY-wingMinY))
        bounds = CGRect(x: origin.x+Double(minX),y: origin.y+Double(minY),width: Double(maxX-minX),height: Double(maxY-minY))
    }

    func rotatedBounds(angle: Double,pivot: CGPoint) -> CGRect {
        if abs(angle) < 1e-10 { return bounds }
        var minX = Double.infinity,minY = Double.infinity,maxX = -Double.infinity,maxY = -Double.infinity
        let transform = GeometryRotation(degrees: angle,pivot: pivot)
        // Row extrema suffice for affine bounds and preserve thin connected appendages at full resolution.
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

nonisolated struct MaskGeometryProcessor: Sendable {
    /// CPU work is nonisolated; UI callers use this entry point rather than blocking MainActor.
    func analyzeInBackground(input: MaskGeometryInput,request: GeometryRequest) async throws -> GeometrySolution {
        let task = Task.detached(priority: .userInitiated) { try analyze(input: input,request: request) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    func analyze(input: MaskGeometryInput,request: GeometryRequest) throws -> GeometrySolution {
        try prepare(input: input).analyze(request: request)
    }
    /// Retain this between preview edits: decode, support extraction and background indexing happen once.
    func prepare(input: MaskGeometryInput) throws -> PreparedMaskGeometry {
        guard !input.sourceVersion.isEmpty,input.sourcePixelSize.width.isFinite,input.sourcePixelSize.height.isFinite,
              input.sourcePixelSize.width > 0,input.sourcePixelSize.height > 0,
              input.coordinateOrigin.x.isFinite,input.coordinateOrigin.y.isFinite,
              !input.cropViewport.isInfinite,!input.cropViewport.isNull,
              input.cropViewport.origin.x.isFinite,input.cropViewport.origin.y.isFinite,
              input.cropViewport.size.width.isFinite,input.cropViewport.size.height.isFinite,
              input.cropViewport.size.width > 0,input.cropViewport.size.height > 0 else {
            throw WorkflowBridgeError.invalidImage("缺少源版本、完整像素尺寸、坐标起点或当前可见画布")
        }
        let mask = try WorkflowRaster.read(input.maskURL)
        let background = try WorkflowRaster.read(input.validBackgroundAlphaURL)
        guard mask.size == input.sourcePixelSize,background.size == mask.size,mask.orientation == 1,background.orientation == 1 else {
            throw WorkflowBridgeError.invalidImage("蒙版与有效背景的完整尺寸或方向不符")
        }
        let width = Int(mask.size.width),height = Int(mask.size.height)
        var values = [UInt8](repeating: 0,count: width*height),alpha = values
        for i in values.indices {
            let p = i*4
            guard mask.pixels[p+3] == 255,abs(Int(mask.pixels[p])-Int(mask.pixels[p+1])) <= 1,
                  abs(Int(mask.pixels[p])-Int(mask.pixels[p+2])) <= 1 else {
                throw WorkflowBridgeError.invalidImage("需要不透明 RGB 灰度蒙版，不能用透明结果代替")
            }
            values[i] = mask.pixels[p]; alpha[i] = background.pixels[p+3]
        }
        let support = try MeaningfulMaskSupport(values: values,width: width,height: height,origin: input.coordinateOrigin)
        return PreparedMaskGeometry(input: input,support: support,maskValues: values,
                                    background: GeometryBackground(alpha: alpha,width: width,height: height,origin: input.coordinateOrigin))
    }
}

nonisolated struct PreparedMaskGeometry: Sendable {
    let input: MaskGeometryInput
    let support: MeaningfulMaskSupport
    private let columnTops: [Int]
    private let columnCounts: [Int]
    private let leftArea: Int
    private let rightArea: Int
    private let background: GeometryBackground
    fileprivate init(input: MaskGeometryInput,support: MeaningfulMaskSupport,maskValues: [UInt8],background: GeometryBackground) {
        self.input = input; self.support = support; self.background = background
        let w = support.width,h = support.height,mid = support.wingBounds.midX-input.coordinateOrigin.x
        var tops = [Int](repeating: h,count: w),counts = [Int](repeating: 0,count: w),runs = [Int](repeating: 0,count: w),la = 0,ra = 0
        let depth = max(3,Int(support.wingBounds.height*0.06))
        // A wing edge has solid tissue beneath it; an oblique one-pixel antenna does not.
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
            throw WorkflowBridgeError.invalidImage("留白或中心参数无效")
        }
        let extent = CGRect(origin: input.coordinateOrigin,size: input.sourcePixelSize)
        let pivot = CGPoint(x: extent.midX,y: extent.midY)
        var angle = 0.0,left: CGPoint?,right: CGPoint?,review: String?
        switch request.angleStrategy {
        case .manual(let degrees):
            guard degrees.isFinite else { throw WorkflowBridgeError.invalidImage("角度无效") }
            angle = degrees.truncatingRemainder(dividingBy: 360)
        case .twoPoints(let l,let r):
            guard l.x.isFinite,l.y.isFinite,r.x.isFinite,r.y.isFinite,r.x-l.x > 1,
                  extent.contains(l),extent.contains(r) else { throw WorkflowBridgeError.invalidImage("请选择源图内左右两个不同翅顶") }
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
            let paddingWarning = insufficient && !(reason?.contains("留白不足") ?? false) ? "留白不足：已保留完整主体与真实背景" : nil
            let details = [reason,paddingWarning].compactMap { $0 }
            let detail = details.isEmpty ? nil : details.joined(separator: "；")
            return GeometrySolution(sourceVersion: input.sourceVersion,angleDegrees: applicable ? angle : 0,rotationPivot: pivot,
                leftWingTip: left,rightWingTip: right,subjectBounds: b,sourceCropRect: crop,outputSize: crop.size,
                actualMargins: margins,isApplicable: applicable,reason: detail)
        }
        let minW = Int(ceil(bounds.maxX-1e-8)-floor(bounds.minX+1e-8)),minH = Int(ceil(bounds.maxY-1e-8)-floor(bounds.minY+1e-8))
        let factor = 1-2*request.targetMargin
        // No valid rotated source rectangle exceeds width+height; cap an impossible request before Int conversion.
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
            return try background.findCrop(width: w,height: h,containing: bounds,center: center,angle: angle,pivot: pivot)
        }
        if let target = try crop(high) { return solution(crop: target,applicable: true,reason: review) }
        guard var best = try crop(low) else {
            let failure = units == nil ? "构图需调整：完整主体范围没有不露空的裁切结果" : "比例无法容纳主体：所选比例没有完整且不露空的裁切结果"
            return solution(crop: input.cropViewport,applicable: false,reason: [review,failure].compactMap { $0 }.joined(separator: "；"))
        }
        var a = low,b = high
        while a+1 < b {
            let mid = (a+b)/2
            if let candidate = try crop(mid) { a = mid; best = candidate } else { b = mid }
        }
        return solution(crop: best,applicable: true,reason: [review,"留白不足：已保留完整主体与真实背景"].compactMap { $0 }.joined(separator: "；"))
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
                // Thin vertical antennae may have depth, but lack a broad neighboring upper edge.
                return Double(coherent) >= Double(neighbors.count)*0.65
            }
            guard let top = candidates.map({ tops[$0] }).min() else { return nil }
            let crest = candidates.filter { tops[$0] <= top+1 }
            guard !crest.isEmpty,
                  !zip(crest,crest.dropFirst()).contains(where: { $0.1-$0.0 > max(2,Int(b.width*0.02)) }) else { return nil }
            // Choose a real contour pixel, never the average of disjoint peaks in empty air.
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

/// Conservative detached-detail evidence, not anatomical classification or alpha cleanup.
private nonisolated struct MaskComponent {
    var count = 0,strong = 0
    var x0 = Int.max,y0 = Int.max,x1 = 0,y1 = 0
    var sx = 0.0,sy = 0.0,sxx = 0.0,syy = 0.0,sxy = 0.0
    var isPlausibleDetail: Bool {
        guard count >= 2 else { return false } // Isolated single-pixel specks remain analysis noise.
        if strong >= 2 { return true }
        let n = Double(count),cx = sx/n,cy = sy/n
        let vx = max(0,sxx/n-cx*cx),vy = max(0,syy/n-cy*cy),covariance = sxy/n-cx*cy
        let difference = sqrt((vx-vy)*(vx-vy)+4*covariance*covariance)
        let major = (vx+vy+difference)/2,minor = max(0,(vx+vy-difference)/2)
        let elongated = major >= 9*max(0.25,minor)
        // Sparse bent/looping hair can be isotropic in PCA, yet still occupy very little of its bounding box.
        let sparse = max(x1-x0,y1-y0) >= 3 && Double(count) <= Double((x1-x0)*(y1-y0))*0.35
        return elongated || sparse
    }
}

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
    /// Source-space summed invalid pixels; opaque RGB sources need no allocation.
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
    func findCrop(width cw: Int,height ch: Int,containing b: CGRect,center: CGPoint,angle: Double,pivot: CGPoint) throws -> CGRect? {
        let rotation = GeometryRotation(degrees: angle,pivot: pivot)
        let domain = [CGPoint(x: origin.x,y: origin.y),CGPoint(x: origin.x+Double(width),y: origin.y),
                      CGPoint(x: origin.x+Double(width),y: origin.y+Double(height)),CGPoint(x: origin.x,y: origin.y+Double(height))].map { rotation.apply($0) }
        let x0 = max(Int(ceil(b.maxX-Double(cw)-1e-8)),Int(ceil(domain.map(\.x).min()!-1e-8)))
        let x1 = min(Int(floor(b.minX+1e-8)),Int(floor(domain.map(\.x).max()!-Double(cw)+1e-8)))
        let y0 = max(Int(ceil(b.maxY-Double(ch)-1e-8)),Int(ceil(domain.map(\.y).min()!-1e-8)))
        let y1 = min(Int(floor(b.minY+1e-8)),Int(floor(domain.map(\.y).max()!-Double(ch)+1e-8)))
        guard x0 <= x1,y0 <= y1 else { return nil }
        let desiredX = min(x1,max(x0,Int(round(center.x-Double(cw)/2)))),desiredY = min(y1,max(y0,Int(round(center.y-Double(ch)/2))))
        func attempt(_ y: Int) -> CGRect? {
            // Inverse-rotated corners impose linear x constraints. This avoids scanning empty rotation corners.
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
    private func isValid(_ rect: CGRect,rotation: GeometryRotation) -> Bool {
        guard let invalid else { return true } // Corners already checked against the real source extent.
        let polygon = [CGPoint(x: rect.minX,y: rect.minY),CGPoint(x: rect.maxX,y: rect.minY),CGPoint(x: rect.maxX,y: rect.maxY),CGPoint(x: rect.minX,y: rect.maxY)].map { rotation.inverse($0) }
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
        // Every source pixel touched by the inverse rectangle must have opaque real background.
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
