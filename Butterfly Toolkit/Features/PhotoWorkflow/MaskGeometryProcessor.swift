// 从完整分辨率蒙版提取主体与翅顶，计算旋转裁切方案，并检查裁切区域是否具备真实背景。

import Foundation
import CoreGraphics

// MARK: - 分析输入与主体支持区域
/// 所有坐标均基于指定的当前保存 PSD，x 向右、y 向下。
nonisolated struct MaskGeometryInput: Sendable {
    var sourceVersion: String
    var sourcePixelSize: CGSize
    var maskURL: URL
    var validBackgroundAlphaURL: URL
    var coordinateOrigin: CGPoint
    /// 当前保存的可见画布，使用同一 PSD 坐标系，可能包含空白区域。
    var cropViewport: CGRect
}

// MARK: - 完整像素准备
nonisolated struct MaskGeometryProcessor: Sendable {
    /// 计算不绑定隔离域；界面通过此后台入口调用，避免阻塞 MainActor。
    func analyzeInBackground(input: MaskGeometryInput,request: GeometryRequest) async throws -> GeometrySolution {
        let task = Task.detached(priority: .userInitiated) { try analyze(input: input,request: request) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    func analyze(input: MaskGeometryInput,request: GeometryRequest) throws -> GeometrySolution {
        try prepare(input: input).analyze(request: request)
    }
    /// 预览编辑之间复用准备结果，避免重复解码、主体提取和背景索引。
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
        return try SpecimenGeometry.prepare(input: GeometryImageInput(sourceVersion: input.sourceVersion,
            sourcePixelSize: input.sourcePixelSize,coordinateOrigin: input.coordinateOrigin,cropViewport: input.cropViewport),
            mask: values,backgroundAlpha: alpha)
    }
}
