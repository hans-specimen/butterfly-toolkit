// 将清理诊断绑定到自动保存版本；人工保存不沿用历史删除位置。
import Foundation
import CoreGraphics

// MARK: - 报告身份校验
private nonisolated func readCleanupReport(url: URL?,fingerprint: String?,version: Int?) throws -> MaskCleanupReport? {
    if url == nil && fingerprint == nil && version == nil { return nil }
    guard let url,let fingerprint,let version,version == MaskResidueCleanup.algorithmVersion,
          try AIFileValidation.hash(url.path) == fingerprint else { throw WorkflowBridgeError.staleSource }
    let report = try JSONDecoder().decode(MaskCleanupReport.self,from: Data(contentsOf: url))
    guard report.algorithmVersion == version,try AIFileValidation.hash(url.path) == fingerprint else { throw WorkflowBridgeError.staleSource }
    return report
}
nonisolated extension MatteArtifact {
    func validatedCleanupReport() throws -> MaskCleanupReport? {
        let report = try readCleanupReport(url: cleanupReportURL,fingerprint: cleanupReportFingerprint,version: cleanupAlgorithmVersion)
        guard report == nil || report?.pixelSize == pixelSize else { throw WorkflowBridgeError.staleSource }
        return report
    }
}
nonisolated extension PSDSnapshot {
    func validatedCleanupReport() throws -> MaskCleanupReport? {
        guard cleanupSnapshotVersion == contentVersion,finalRoles == nil else { return nil }
        return try readCleanupReport(url: cleanupReportURL,fingerprint: cleanupReportFingerprint,version: cleanupAlgorithmVersion)
    }
    func attachingCleanup(from matte: MatteArtifact) -> Self {
        var result = self
        result.cleanupReportURL = matte.cleanupReportURL
        result.cleanupReportFingerprint = matte.cleanupReportFingerprint
        result.cleanupAlgorithmVersion = matte.cleanupAlgorithmVersion
        result.cleanupSnapshotVersion = matte.cleanupReportURL == nil ? nil : contentVersion
        result.cleanupGeometry = nil
        return result
    }
    func carryingCleanup(from previous: Self,geometry: GeometrySolution) -> Self {
        var result = self
        result.cleanupReportURL = nil; result.cleanupReportFingerprint = nil; result.cleanupAlgorithmVersion = nil
        result.cleanupSnapshotVersion = nil; result.cleanupGeometry = nil
        // 仅承接首次自动几何变换；后续保存、再次裁切不冒充原始清理分析。
        guard previous.cleanupSnapshotVersion == previous.contentVersion,previous.cleanupGeometry == nil,
              geometry.sourceVersion == previous.contentVersion,taskID == previous.taskID else { return result }
        result.cleanupReportURL = previous.cleanupReportURL
        result.cleanupReportFingerprint = previous.cleanupReportFingerprint
        result.cleanupAlgorithmVersion = previous.cleanupAlgorithmVersion
        result.cleanupSnapshotVersion = contentVersion; result.cleanupGeometry = geometry
        return result
    }
    func cleanupDisplayBounds(_ bounds: CGRect) -> CGRect {
        guard let g = cleanupGeometry else { return bounds }
        let points = [CGPoint(x: bounds.minX,y: bounds.minY),CGPoint(x: bounds.maxX,y: bounds.minY),CGPoint(x: bounds.maxX,y: bounds.maxY),CGPoint(x: bounds.minX,y: bounds.maxY)].map {
            let p = WorkflowPreviewCoordinates.rotate($0,degrees: g.angleDegrees,pivot: g.rotationPivot)
            return CGPoint(x: p.x-g.sourceCropRect.minX,y: p.y-g.sourceCropRect.minY)
        }
        let minX = points.map(\.x).min()!,minY = points.map(\.y).min()!
        return CGRect(x: minX,y: minY,width: points.map(\.x).max()!-minX,height: points.map(\.y).max()!-minY)
    }
}

// MARK: - 面向检查者的状态与位置
nonisolated enum WorkflowCleanupStatus {
    static func title(solution: GeometrySolution?,report: MaskCleanupReport?,targetMargin: Double) -> String {
        guard let solution else { return report == nil ? "" : "蒙版已处理" }
        guard solution.isApplicable else { return "自动裁切未应用" }
        if report?.regions.contains(where: { $0.decision == .uncertain }) == true { return "已裁切 · 残留待检查" }
        let m = solution.actualMargins
        if min(m.left,m.top,m.right,m.bottom)+0.001 < targetMargin { return "已裁切 · 留白不足" }
        return "已裁切"
    }
    static func message(region: MaskCleanupRegion,bounds: CGRect,size: CGSize) -> String {
        let horizontal = bounds.midX < size.width/3 ? "左" : (bounds.midX > size.width*2/3 ? "右" : "中")
        let vertical = bounds.midY < size.height/3 ? "上" : (bounds.midY > size.height*2/3 ? "下" : "部")
        let location = horizontal+vertical
        if region.decision == .removedBackground {
            return "\(location)\(region.reason == .edgeBand ? "边缘条带" : "背景淡斑")已清理"
        }
        if region.reason == .noReliableCore { return "无法确认主体，已保留全部蒙版，请检查" }
        return "\(location)有无法确定的细节或连接，已保留，请检查蒙版"
    }
}
