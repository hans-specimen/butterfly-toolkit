import SwiftUI
import ImageIO
import CoreImage

nonisolated enum AIImageReader {
    static func read(path: String, alpha: Bool = false, thumbnail: Bool = false) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceThumbnailMaxPixelSize: 280,
                                      kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = thumbnail ? CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                : CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        guard alpha else { return image }
        let mask = CIImage(cgImage: image).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        return CIContext().createCGImage(mask, from: mask.extent)
    }
}

struct AIThumbnail: View {
    var path: String?
    @State private var image: CGImage?
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFit() }
            else { Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary) }
        }
        .task(id: path) {
            image = nil
            guard let path else { return }
            let decoded = await Task.detached(priority: .utility) { AIImageReader.read(path: path, thumbnail: true) }.value
            if !Task.isCancelled { image = decoded }
        }
    }
}

enum AICompareMode: String, CaseIterable { case original = "原图", reference = "人工参考", alpha = "透明度" }
enum AIBackground: String, CaseIterable { case black = "黑底", white = "白底", checker = "透明格" }

struct AIImagePanel: View {
    let path: String?
    var deriveAlpha = false
    let title: String
    var subtitle: String = ""
    let imageSize: CGSize
    let background: AIBackground
    @Binding var viewport: AIViewport
    @State private var image: CGImage?
    @State private var loading = false
    @State private var dragStart: CGPoint?
    @State private var pinchStart: CGFloat?
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(title).fontWeight(.medium); Spacer(); Text(subtitle).foregroundStyle(.secondary).font(.caption) }
                .padding(.horizontal, 14).frame(height: 34).background(.background)
            GeometryReader { proxy in
                Canvas { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background == .white ? .white : Color(white: background == .black ? 0.065 : 0.82)))
                    if background == .checker {
                        for x in stride(from: 0, to: Int(size.width), by: 16) {
                            for y in stride(from: 0, to: Int(size.height), by: 16) where (x / 16 + y / 16) % 2 == 0 {
                                context.fill(Path(CGRect(x: x, y: y, width: 16, height: 16)), with: .color(Color(white: 0.94)))
                            }
                        }
                    }
                    if let image {
                        context.draw(Image(decorative: image, scale: 1).interpolation(viewport.zoom > 2 ? .none : .high), in: viewport.imageRect(image: imageSize, panel: size))
                    }
                }
                .overlay {
                    if loading { ProgressView().padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) }
                    else if image == nil {
                        Text(path == nil ? "暂无\(title)" : "图片无法读取，请检查文件是否仍在原位置")
                            .foregroundStyle(.secondary).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                    if dragStart == nil { dragStart = viewport.center }
                    viewport.move(translation: value.translation, scale: viewport.scale(image: imageSize, panel: proxy.size), start: dragStart ?? viewport.center)
                }.onEnded { _ in dragStart = nil })
                .simultaneousGesture(MagnificationGesture().onChanged { value in
                    if pinchStart == nil { pinchStart = viewport.zoom }
                    viewport.zoom = min(32, max(1, (pinchStart ?? 1) * value))
                }.onEnded { _ in pinchStart = nil })
                .onTapGesture(count: 2) { viewport.fit(imageSize) }
                .accessibilityLabel("\(title)，与另一侧同步缩放和平移")
            }
            .clipped()
        }
        .task(id: "\(path ?? "")|\(deriveAlpha)") {
            image = nil; loading = path != nil
            guard let path else { return }
            let alpha = deriveAlpha
            let decoded = await Task.detached(priority: .userInitiated) { AIImageReader.read(path: path, alpha: alpha) }.value
            if !Task.isCancelled { image = decoded; loading = false }
        }
    }
}

struct AICutoutView: View {
    @ObservedObject var store: AIWorkspaceStore
    @State private var mode: AICompareMode = .reference
    @State private var background: AIBackground = .black
    @State private var detail = false
    @State private var regionIndex = 0
    @State private var viewport = AIViewport()
    @State private var panelSize: CGSize = CGSize(width: 400, height: 500)

    var body: some View {
        if let sample = store.selected {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(sample.name).font(.headline).lineLimit(1).help(sample.name)
                            Text(sample.dimensions + " · " + sample.color).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("观察范围", selection: $detail) {
                            Text("整图").tag(false); Text("缘毛细节").tag(true)
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 168)
                    }
                    HStack {
                        Picker("对比内容", selection: $mode) {
                            ForEach(AICompareMode.allCases.filter { sample.reference != nil || $0 == .original }, id: \.self) { value in
                                Text(value.rawValue).tag(value)
                            }
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 244)
                        Spacer(minLength: 8)
                        if detail && !sample.rois.isEmpty {
                            Picker("区域", selection: $regionIndex) {
                                ForEach(Array(sample.rois.enumerated()), id: \.offset) { index, region in Text(region.name).tag(index) }
                            }.labelsHidden().frame(maxWidth: 115)
                        }
                        Picker("背景", selection: $background) {
                            ForEach(AIBackground.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(width: 95)
                    }
                }.padding(16)
                Divider()
                GeometryReader { proxy in
                    HStack(spacing: 1) {
                        AIImagePanel(path: leftPath(sample), deriveAlpha: mode == .alpha && sample.alpha == nil,
                                     title: mode == .alpha ? "人工透明度" : mode.rawValue,
                                     subtitle: mode == .original ? "原始底图" : store.record(for: sample).referenceKind,
                                     imageSize: sample.pixelSize, background: background, viewport: $viewport)
                        AIImagePanel(path: mode == .alpha ? sample.predictionAlpha : sample.prediction,
                                     title: mode == .alpha ? "AI 透明度" : "AI 结果", subtitle: "基础模型",
                                     imageSize: sample.pixelSize, background: background, viewport: $viewport)
                    }.background(Color(nsColor: .separatorColor))
                        .onAppear { panelSize = CGSize(width: (proxy.size.width - 1) / 2, height: proxy.size.height - 34) }
                        .onChange(of: proxy.size) { _, size in panelSize = CGSize(width: (size.width - 1) / 2, height: size.height - 34) }
                }
                HStack(spacing: 10) {
                    Image(systemName: "arrow.left.and.right")
                    Text("同一原图坐标 · 同步查看").lineLimit(1)
                    Spacer()
                    Button { viewport.zoom = max(1, viewport.zoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }.help("两侧同步缩小")
                    Slider(value: $viewport.zoom, in: 1...32).frame(width: 90).accessibilityLabel("同步缩放")
                    Button { viewport.zoom = min(32, viewport.zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }.help("两侧同步放大")
                    Text("\(Int(viewport.scale(image: sample.pixelSize, panel: panelSize) * 100))%")
                        .monospacedDigit().frame(width: 40)
                    Button("适合窗口") { detail = false; viewport.fit(sample.pixelSize) }
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 40)
                Divider()
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(store.samples) { item in
                            Button { store.selectedID = item.id } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    AIThumbnail(path: item.reference ?? item.original).frame(width: 126, height: 76).padding(5)
                                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(store.selectedID == item.id ? Color.accentColor : .clear, lineWidth: 2))
                                    Text(item.name).font(.caption).lineLimit(1).frame(width: 136, alignment: .leading)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).help(item.name).accessibilityLabel("选择样本 \(item.name)")
                        }
                    }.padding(14)
                }.frame(height: 124)
            }
            .onChange(of: sample.id, initial: true) { _, _ in
                detail = false; regionIndex = 0; viewport.fit(sample.pixelSize)
                if sample.reference == nil { mode = .original }
            }
            .onChange(of: detail) { _, value in if value { focusRegion(sample) } else { viewport.fit(sample.pixelSize) } }
            .onChange(of: regionIndex) { _, _ in if detail { focusRegion(sample) } }
        } else {
            ContentUnavailableView {
                Label("添加图片，开始抠图", systemImage: "photo.on.rectangle")
            } description: {
                Text("支持 PNG、JPEG，可多选，无需人工答案。训练素材请在独立页面导入。")
            } actions: {
                Button("添加待抠图片…", action: store.chooseImages).buttonStyle(.borderedProminent).disabled(store.busy)
            }
        }
    }
    private func leftPath(_ sample: AISample) -> String? {
        switch mode { case .original: sample.original; case .reference: sample.reference; case .alpha: sample.alpha ?? sample.reference }
    }
    private func focusRegion(_ sample: AISample) {
        let region = sample.rois.indices.contains(regionIndex) ? sample.rois[regionIndex] : AIRegion(name: "自由查看", x: Double(sample.width) / 2 - 160, y: Double(sample.height) / 2 - 160, width: 320, height: 320)
        viewport.center = region.center
        let fit = min(panelSize.width / CGFloat(sample.width), panelSize.height / CGFloat(sample.height))
        viewport.zoom = min(32, max(1, min(panelSize.width / region.width, panelSize.height / region.height) / max(fit, 0.001)))
    }
}
