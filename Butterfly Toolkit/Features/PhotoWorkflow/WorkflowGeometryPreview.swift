// 管理预览图解码与版本确认门槛，并绘制几何构图、方形安全框及可回传源坐标的交互画布。

import SwiftUI
import ImageIO

// MARK: - 预览身份与坐标转换
nonisolated struct WorkflowPreviewImageIdentity: Equatable, Sendable {
    var sourceVersion: String
    var url: URL
    var maximumPixelSize: Int
}

nonisolated struct WorkflowPreviewGate: Sendable {
    private(set) var token = UUID()
    private(set) var sourceVersion = ""
    private(set) var canConfirm = false
    // 每次请求立即撤销确认资格，只有相同令牌与保存版本的结果才能重新开启。
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

// MARK: - 异步预览服务
nonisolated protocol WorkflowPreviewServing: Sendable {
    func image(url: URL,version: String,maximumPixelSize: Int) async throws -> CGImage
    func geometry(source: RoleImages,request: GeometryRequest,savedCandidate: GeometrySolution?) async throws -> GeometrySolution
}

/// 完整可编辑区域的缩略图在界面隔离域外解码，几何计算始终保留完整源分辨率。
actor WorkflowPreviewService: WorkflowPreviewServing {
    private var images: [String: CGImage] = [:]
    private let geometryCache: WorkflowGeometryCache
    init(geometry: WorkflowGeometryCache = WorkflowGeometryCache()) { geometryCache = geometry }
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
        // 完整细节图仅由界面当前面持有，不放入共享缩略图缓存。
        if maximumPixelSize <= 2048 {
            if images.count >= 12 { images.removeAll() }
            images[key] = result
        }
        return result
    }
    func geometry(source: RoleImages,request: GeometryRequest,savedCandidate: GeometrySolution? = nil) async throws -> GeometrySolution {
        try await geometryCache.geometry(source: source,request: request,savedCandidate: savedCandidate)
    }

}

// MARK: - 构图画布与交互
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
                    // 无效构图以红色提示源图或背景空缺，避免将其显示为有效照片区域。
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
                // 点击点先从显示坐标回到画布，再逆旋转到未变换的源图坐标。
                if square == nil,let solution { point = WorkflowPreviewCoordinates.rotate(point,degrees: -solution.angleDegrees,pivot: solution.rotationPivot) }
                onSourcePoint(point)
            })
            .simultaneousGesture(DragGesture(minimumDistance: 5)
                .onChanged { value in onMoveChanged(CGSize(width: value.translation.width/map.scale,height: value.translation.height/map.scale)) }
                .onEnded { value in onMoveEnded(CGSize(width: value.translation.width/map.scale,height: value.translation.height/map.scale)) })
        }.clipped().overlay { if image == nil { ProgressView("加载当前保存版本…") } }
    }
    var displayRect: CGRect {
        if let square { return CGRect(x: 0,y: 0,width: square.canvasSide,height: square.canvasSide).insetBy(dx: -120,dy: -120) }
        guard let source else { return CGRect(x: 0,y: 0,width: 100,height: 100) }
        return source.editableExtent.union(solution?.sourceCropRect ?? source.cropViewport).insetBy(dx: -80,dy: -80)
    }
}

// MARK: - 可选预览性能记录
#if DEBUG
/// 按需记录原生 Canvas 闭包延迟，不代表画面实际显示到屏幕的时间。
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
