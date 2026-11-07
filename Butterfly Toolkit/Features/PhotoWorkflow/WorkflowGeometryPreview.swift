import SwiftUI
import ImageIO

nonisolated struct WorkflowPreviewImageIdentity: Equatable, Sendable {
    var sourceVersion: String
    var url: URL
    var maximumPixelSize: Int
}

nonisolated struct WorkflowPreviewGate: Sendable {
    private(set) var token = UUID()
    private(set) var sourceVersion = ""
    private(set) var canConfirm = false
    mutating func begin(sourceVersion: String) -> UUID {
        token = UUID(); self.sourceVersion = sourceVersion; canConfirm = false; return token
    }
    @discardableResult mutating func accept(token: UUID,sourceVersion: String,valid: Bool) -> Bool {
        guard token == self.token,sourceVersion == self.sourceVersion else { return false }
        canConfirm = valid; return true
    }
}

nonisolated struct WorkflowPreviewCoordinates: Sendable {
    var sourceRect: CGRect
    var viewSize: CGSize
    var zoom: Double = 1
    var scale: Double { min(viewSize.width/sourceRect.width,viewSize.height/sourceRect.height)*zoom }
    func viewPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: viewSize.width/2+(p.x-sourceRect.midX)*scale,y: viewSize.height/2+(p.y-sourceRect.midY)*scale)
    }
    func sourcePoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: sourceRect.midX+(p.x-viewSize.width/2)/scale,y: sourceRect.midY+(p.y-viewSize.height/2)/scale)
    }
    func viewRect(_ rect: CGRect) -> CGRect { CGRect(origin: viewPoint(rect.origin),size: CGSize(width: rect.width*scale,height: rect.height*scale)) }
    static func rotate(_ p: CGPoint,degrees: Double,pivot: CGPoint) -> CGPoint {
        let a = degrees * .pi/180,c = cos(a),s = sin(a),x = p.x-pivot.x,y = p.y-pivot.y
        return CGPoint(x: pivot.x+c*x-s*y,y: pivot.y+s*x+c*y)
    }
}

/// Full editable-extent thumbnails are decoded off the UI actor; source geometry always stays full resolution.
actor WorkflowPreviewService {
    private var images: [String: CGImage] = [:]
    private var prepared: [String: PreparedMaskGeometry] = [:]
    private var preparing: [String: Task<PreparedMaskGeometry,Error>] = [:]
    private var decoding: [String: Task<CGImage,Error>] = [:]
    func image(url: URL,version: String,maximumPixelSize: Int = 2048) async throws -> CGImage {
        let key = "\(version)|\(url.path)|\(maximumPixelSize)"
        if let cached = images[key] { return cached }
        if let pending = decoding[key] { return try await pending.value }
        let pending = Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways: true,kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,kCGImageSourceCreateThumbnailWithTransform: true,kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw WorkflowBridgeError.invalidImage("预览无法解码") }
            return image
        }
        decoding[key] = pending
        let result: CGImage
        do { result = try await pending.value; decoding[key] = nil }
        catch { decoding[key] = nil; throw error }
        // Full details belong only to the visible store face, never to this shared thumbnail cache.
        if maximumPixelSize <= 2048 {
            if images.count >= 12 { images.removeAll() }
            images[key] = result
        }
        return result
    }
    func geometry(source: RoleImages,request: GeometryRequest,savedCandidate: GeometrySolution? = nil) async throws -> GeometrySolution {
        let key = "\(source.snapshotVersion)|\(source.maskPNG.path)|\(source.basePNG.path)"
        let analysis: PreparedMaskGeometry
        if let cached = prepared[key] { analysis = cached }
        else {
            let pending = preparing[key] ?? Task.detached(priority: .userInitiated) {
                try MaskGeometryProcessor().prepare(input: MaskGeometryInput(sourceVersion: source.snapshotVersion,sourcePixelSize: source.pixelSize,maskURL: source.maskPNG,validBackgroundAlphaURL: source.basePNG,coordinateOrigin: source.coordinateOrigin,cropViewport: source.cropViewport))
            }
            preparing[key] = pending
            do { analysis = try await pending.value; preparing[key] = nil }
            catch { preparing[key] = nil; throw error }
            if prepared.count >= 2 { prepared.removeAll() }; prepared[key] = analysis
        }
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            if let savedCandidate { return try analysis.validate(solution: savedCandidate) }
            return try analysis.analyze(request: request)
        }.value
    }
    func preview(source: RoleImages,solution: GeometrySolution,maximumPixelSize: Int = 2048) async throws -> CGImage {
        guard source.snapshotVersion == solution.sourceVersion else { throw WorkflowBridgeError.staleSource }
        let image = try await image(url: source.basePNG,version: source.snapshotVersion,maximumPixelSize: maximumPixelSize)
        return try await Task.detached {
            let crop = solution.sourceCropRect,scale = min(1,Double(maximumPixelSize)/max(crop.width,crop.height))
            let w = max(1,Int((crop.width*scale).rounded())),h = max(1,Int((crop.height*scale).rounded()))
            guard let ctx = CGContext(data: nil,width: w,height: h,bitsPerComponent: 8,bytesPerRow: w*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw WorkflowBridgeError.invalidImage("预览画布不可用") }
            ctx.translateBy(x: 0,y: Double(h)); ctx.scaleBy(x: scale,y: -scale)
            ctx.translateBy(x: -crop.minX,y: -crop.minY)
            ctx.translateBy(x: solution.rotationPivot.x,y: solution.rotationPivot.y); ctx.rotate(by: solution.angleDegrees * .pi/180); ctx.translateBy(x: -solution.rotationPivot.x,y: -solution.rotationPivot.y)
            ctx.translateBy(x: source.coordinateOrigin.x,y: source.coordinateOrigin.y+source.pixelSize.height); ctx.scaleBy(x: 1,y: -1)
            ctx.draw(image,in: CGRect(origin: .zero,size: source.pixelSize))
            guard let output = ctx.makeImage() else { throw WorkflowBridgeError.invalidImage("预览生成失败") }; return output
        }.value
    }
}

struct WorkflowGeometryPreview: View {
    var image: CGImage?
    var source: RoleImages?
    var solution: GeometrySolution?
    var square: SquareLayout?
    var zoom: Double
    var background: String
    var showSafeFrame = true
    var interactionStarted: TimeInterval?
    var onSourcePoint: (CGPoint) -> Void = { _ in }
    var onMoveChanged: (CGSize) -> Void = { _ in }
    var onMoveEnded: (CGSize) -> Void = { _ in }
    var body: some View {
        GeometryReader { geo in
            let rect = displayRect
            let map = WorkflowPreviewCoordinates(sourceRect: rect,viewSize: geo.size,zoom: zoom)
            Canvas { ctx,size in
                defer {
                    #if DEBUG
                    if let interactionStarted,image != nil {
                        let elapsed = (ProcessInfo.processInfo.systemUptime-interactionStarted)*1000
                        Task { await WorkflowPreviewMetrics.shared.record(started: interactionStarted,milliseconds: elapsed) }
                    }
                    #endif
                }
                let previewColor: Color = background == "天蓝" ? Color(red: 116/255.0,green: 191/255.0,blue: 1) : (background == "黑" ? .black : .white)
                ctx.fill(Path(CGRect(origin: .zero,size: size)),with: .color(previewColor))
                if background == "棋盘" {
                    for y in stride(from: 0,to: Int(size.height),by: 20) { for x in stride(from: 0,to: Int(size.width),by: 20) where (x/20+y/20)%2 == 0 {
                        ctx.fill(Path(CGRect(x: x,y: y,width: 20,height: 20)),with: .color(.gray.opacity(0.2)))
                    } }
                }
                guard let image,let source else { return }
                if let square,let solution {
                    let b = solution.subjectBounds,s = min(Double(square.canvasSide-2*square.safeMargin)/b.width,Double(square.canvasSide-2*square.safeMargin)/b.height)
                    let target = CGRect(x: square.center.x+(source.coordinateOrigin.x-b.midX)*s,y: square.center.y+(source.coordinateOrigin.y-b.midY)*s,width: source.pixelSize.width*s,height: source.pixelSize.height*s)
                    let canvas = CGRect(x: 0,y: 0,width: square.canvasSide,height: square.canvasSide)
                    let subject = CGRect(x: square.center.x-b.width*s/2,y: square.center.y-b.height*s/2,width: b.width*s,height: b.height*s)
                    var pixels = ctx
                    pixels.clip(to: Path(map.viewRect(subject.intersection(canvas))))
                    pixels.draw(Image(decorative: image,scale: 1),in: map.viewRect(target))
                    ctx.stroke(Path(map.viewRect(canvas)),with: .color(canvas.contains(subject) ? .gray : .red),lineWidth: 2)
                    if showSafeFrame { ctx.stroke(Path(map.viewRect(CGRect(x: square.safeMargin,y: square.safeMargin,width: square.canvasSide-2*square.safeMargin,height: square.canvasSide-2*square.safeMargin))),with: .color(.orange),lineWidth: 2) }
                    ctx.stroke(Path(map.viewRect(subject)),with: .color(.green),style: StrokeStyle(lineWidth: 1.5,dash: [6,4]))
                } else {
                    // Empty transformed source/background remains visibly red rather than being filled as valid photo.
                    if let solution,!solution.isApplicable { ctx.fill(Path(map.viewRect(solution.sourceCropRect)),with: .color(.red.opacity(0.25))) }
                    if let solution {
                        let pivot = map.viewPoint(solution.rotationPivot)
                        ctx.translateBy(x: pivot.x,y: pivot.y); ctx.rotate(by: .degrees(solution.angleDegrees)); ctx.translateBy(x: -pivot.x,y: -pivot.y)
                    }
                    ctx.draw(Image(decorative: image,scale: 1),in: map.viewRect(CGRect(origin: source.coordinateOrigin,size: source.pixelSize)))
                    if let solution {
                        let pivot = map.viewPoint(solution.rotationPivot)
                        ctx.translateBy(x: pivot.x,y: pivot.y); ctx.rotate(by: .degrees(-solution.angleDegrees)); ctx.translateBy(x: -pivot.x,y: -pivot.y)
                        ctx.stroke(Path(map.viewRect(solution.subjectBounds)),with: .color(.green),lineWidth: 1)
                        ctx.stroke(Path(map.viewRect(solution.sourceCropRect)),with: .color(solution.isApplicable ? .orange : .red),lineWidth: 2)
                        for p in [solution.leftWingTip,solution.rightWingTip].compactMap({ $0 }) {
                            let q = map.viewPoint(WorkflowPreviewCoordinates.rotate(p,degrees: solution.angleDegrees,pivot: solution.rotationPivot))
                            ctx.fill(Path(ellipseIn: CGRect(x: q.x-4,y: q.y-4,width: 8,height: 8)),with: .color(.cyan))
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                var point = map.sourcePoint(value.location)
                if square == nil,let solution { point = WorkflowPreviewCoordinates.rotate(point,degrees: -solution.angleDegrees,pivot: solution.rotationPivot) }
                onSourcePoint(point)
            })
            .simultaneousGesture(DragGesture(minimumDistance: 5)
                .onChanged { value in onMoveChanged(CGSize(width: value.translation.width/map.scale,height: value.translation.height/map.scale)) }
                .onEnded { value in onMoveEnded(CGSize(width: value.translation.width/map.scale,height: value.translation.height/map.scale)) })
        }.clipped().overlay { if image == nil { ProgressView("加载当前保存版本…") } }
    }
    private var displayRect: CGRect {
        if let square { return CGRect(x: 0,y: 0,width: square.canvasSide,height: square.canvasSide).insetBy(dx: -120,dy: -120) }
        guard let source else { return CGRect(x: 0,y: 0,width: 100,height: 100) }
        return source.editableExtent.union(solution?.sourceCropRect ?? source.cropViewport).insetBy(dx: -80,dy: -80)
    }
}

#if DEBUG
/// Opt-in native Canvas-closure latency, not a claim about display presentation timing.
private actor WorkflowPreviewMetrics {
    static let shared = WorkflowPreviewMetrics()
    private var recorded: Set<TimeInterval> = []
    func record(started: TimeInterval,milliseconds: Double) {
        guard let path = ProcessInfo.processInfo.environment["BUTTERFLY_WORKFLOW_PREVIEW_METRICS"],recorded.insert(started).inserted,
              path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") else { return }
        let line = "{\"event\":\"native-canvas-closure\",\"started\":\(started),\"milliseconds\":\(milliseconds)}\n"
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) { try? Data().write(to: url) }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        defer { try? file.close() }; _ = try? file.seekToEnd(); try? file.write(contentsOf: Data(line.utf8))
    }
}
#endif
