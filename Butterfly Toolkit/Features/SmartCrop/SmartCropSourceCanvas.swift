// 在未旋转原图上选翅顶和完整主体框；缩放仅改变显示，所有草稿保存原图像素坐标。
import SwiftUI

nonisolated enum SmartCropInteraction { case none,tips,bounds }

nonisolated struct SmartCropCoordinates {
    let sourceSize: CGSize
    let viewSize: CGSize
    var scale: Double { min(viewSize.width/sourceSize.width,viewSize.height/sourceSize.height) }
    var imageRect: CGRect {
        CGRect(x: (viewSize.width-sourceSize.width*scale)/2,y: (viewSize.height-sourceSize.height*scale)/2,
               width: sourceSize.width*scale,height: sourceSize.height*scale)
    }
    func sourcePoint(_ p: CGPoint) -> CGPoint? {
        guard imageRect.contains(p) else { return nil }
        return CGPoint(x: (p.x-imageRect.minX)/scale,y: (p.y-imageRect.minY)/scale)
    }
    func viewPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: imageRect.minX+p.x*scale,y: imageRect.minY+p.y*scale) }
    func viewRect(_ r: CGRect) -> CGRect { CGRect(origin: viewPoint(r.origin),size: CGSize(width: r.width*scale,height: r.height*scale)) }
}

struct SmartCropSourceCanvas: View {
    let image: CGImage
    let sourceSize: CGSize
    let solution: GeometrySolution?
    let manualBounds: CGRect?
    let tips: [CGPoint]
    let interaction: SmartCropInteraction
    let zoom: Double
    var onPoint: (CGPoint) -> Void
    var onBounds: (CGRect) -> Void
    @State private var draft: CGRect?

    var body: some View {
        GeometryReader { viewport in
            ScrollView([.horizontal,.vertical]) {
                let size = CGSize(width: max(1,viewport.size.width)*zoom,height: max(1,viewport.size.height)*zoom)
                let map = SmartCropCoordinates(sourceSize: sourceSize,viewSize: size)
                Canvas { ctx,_ in
                    ctx.draw(Image(decorative: image,scale: 1),in: map.imageRect)
                    if let s = solution {
                        let sourceBounds = inversePath(s.subjectBounds,solution: s,map: map)
                        ctx.stroke(sourceBounds,with: .color(.green),style: StrokeStyle(lineWidth: 1.5,dash: [4,3]))
                        if s.isApplicable { ctx.stroke(inversePath(s.sourceCropRect,solution: s,map: map),with: .color(.orange),lineWidth: 2) }
                    }
                    if let b = draft ?? manualBounds { ctx.stroke(Path(map.viewRect(b)),with: .color(.green),lineWidth: 2) }
                    let selected = tips.isEmpty ? [solution?.leftWingTip,solution?.rightWingTip].compactMap { $0 } : tips
                    if selected.count == 2 {
                        var line = Path(); line.move(to: map.viewPoint(selected[0])); line.addLine(to: map.viewPoint(selected[1]))
                        ctx.stroke(line,with: .color(.cyan),lineWidth: 1.5)
                    }
                    for (i,p) in selected.enumerated() {
                        let q = map.viewPoint(p)
                        ctx.fill(Path(ellipseIn: CGRect(x: q.x-4,y: q.y-4,width: 8,height: 8)),with: .color(.cyan))
                        ctx.draw(Text("\(i+1)").font(.caption).foregroundStyle(.white),at: CGPoint(x: q.x+12,y: q.y-12))
                    }
                }
                .frame(width: size.width,height: size.height)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in
                    if interaction == .tips,let p = map.sourcePoint(value.location) { onPoint(p) }
                })
                .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                    guard interaction == .bounds,let start = map.sourcePoint(value.startLocation),let end = map.sourcePoint(value.location) else { return }
                    draft = CGRect(x: min(start.x,end.x),y: min(start.y,end.y),width: abs(start.x-end.x),height: abs(start.y-end.y))
                }.onEnded { _ in
                    defer { draft = nil }
                    if interaction == .bounds,let draft,draft.width >= 2,draft.height >= 2 { onBounds(draft) }
                },including: interaction == .bounds ? .all : .subviews)
            }
        }
        .background(.quaternary.opacity(0.3))
        .onChange(of: interaction) { draft = nil }
        .accessibilityLabel("原图交互预览，选择两个翅顶或拖动框定主体")
    }

    private func inversePath(_ rect: CGRect,solution: GeometrySolution,map: SmartCropCoordinates) -> Path {
        let pivot = solution.rotationPivot,a = -solution.angleDegrees * .pi/180,c = cos(a),s = sin(a)
        let points = [CGPoint(x: rect.minX,y: rect.minY),CGPoint(x: rect.maxX,y: rect.minY),CGPoint(x: rect.maxX,y: rect.maxY),CGPoint(x: rect.minX,y: rect.maxY)].map { p in
            map.viewPoint(CGPoint(x: pivot.x+c*(p.x-pivot.x)-s*(p.y-pivot.y),y: pivot.y+s*(p.x-pivot.x)+c*(p.y-pivot.y)))
        }
        var path = Path(); path.addLines(points); path.closeSubpath(); return path
    }
}
