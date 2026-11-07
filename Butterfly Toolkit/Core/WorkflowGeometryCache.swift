import Foundation
import CoreGraphics

/// Session-local prepared mask/background analysis. Final geometry is always evaluated per request.
actor WorkflowGeometryCache {
    typealias Prepare = @Sendable (RoleImages) async throws -> PreparedMaskGeometry
    private struct Key: Hashable {
        let version: String
        let mask: String
        let base: String
        let coordinates: [Double]
        init(_ source: RoleImages) {
            version = source.snapshotVersion
            mask = source.maskPNG.standardizedFileURL.resolvingSymlinksInPath().path
            base = source.basePNG.standardizedFileURL.resolvingSymlinksInPath().path
            let extent = source.editableExtent,viewport = source.cropViewport
            coordinates = [source.pixelSize.width,source.pixelSize.height,source.coordinateOrigin.x,source.coordinateOrigin.y,
                extent.minX,extent.minY,extent.width,extent.height,viewport.minX,viewport.minY,viewport.width,viewport.height]
        }
    }
    private struct Entry {
        let analysis: PreparedMaskGeometry
        var use: UInt64
    }
    private struct Flight {
        let id: UUID
        let task: Task<PreparedMaskGeometry,Error>
    }
    private let maximumEntries: Int
    private let maximumBytes: Int
    private let prepare: Prepare
    private var entries: [Key: Entry] = [:]
    private var flights: [Key: Flight] = [:]
    private var generation: UInt64 = 0
    private var clock: UInt64 = 0
    // Retain the serial tail across removeAll so old and new generations cannot prepare concurrently.
    private var tail: Task<Void,Never>?
    private var tailID: UUID?
    private(set) var retainedBytes = 0
    private(set) var pendingRequestCount = 0
    var retainedCount: Int { entries.count }

    init(maximumEntries: Int = 4,maximumBytes: Int = 512 * 1024 * 1024,
         prepare: @escaping Prepare = { source in
             try MaskGeometryProcessor().prepare(input: MaskGeometryInput(sourceVersion: source.snapshotVersion,
                 sourcePixelSize: source.pixelSize,maskURL: source.maskPNG,validBackgroundAlphaURL: source.basePNG,
                 coordinateOrigin: source.coordinateOrigin,cropViewport: source.cropViewport))
         }) {
        self.maximumEntries = max(0,maximumEntries); self.maximumBytes = max(0,maximumBytes); self.prepare = prepare
    }

    func geometry(source: RoleImages,request: GeometryRequest,savedCandidate: GeometrySolution? = nil) async throws -> GeometrySolution {
        try Task.checkCancellation()
        pendingRequestCount += 1
        defer { pendingRequestCount -= 1 }
        let key = Key(source),analysis: PreparedMaskGeometry
        if var entry = entries[key] {
            clock &+= 1; entry.use = clock; entries[key] = entry; analysis = entry.analysis
        } else {
            let epoch = generation,flight: Flight
            if let existing = flights[key] { flight = existing }
            else {
                let previous = tail,prepare = prepare,id = UUID()
                let work = Task.detached(priority: .userInitiated) {
                    await previous?.value
                    return try await prepare(source)
                }
                flight = Flight(id: id,task: work); flights[key] = flight
                tail = Task.detached { _ = try? await work.value }; tailID = id
            }
            do { analysis = try await flight.task.value }
            catch {
                finish(key: key,id: flight.id,epoch: epoch)
                throw error
            }
            if generation == epoch,flights[key]?.id == flight.id {
                insert(analysis,key: key)
            }
            finish(key: key,id: flight.id,epoch: epoch)
        }
        // A cancelled waiter never cancels preparation shared with another preview or confirmation.
        try Task.checkCancellation()
        let solution = try await Task.detached(priority: .userInitiated) {
            if let savedCandidate { return try analysis.validate(solution: savedCandidate) }
            return try analysis.analyze(request: request)
        }.value
        try Task.checkCancellation()
        return solution
    }
    func removeAll() async {
        generation &+= 1; entries.removeAll(); retainedBytes = 0; flights.removeAll()
    }
    private func finish(key: Key,id: UUID,epoch: UInt64) {
        if generation == epoch,flights[key]?.id == id { flights[key] = nil }
        if tailID == id { tail = nil; tailID = nil }
    }
    private func insert(_ analysis: PreparedMaskGeometry,key: Key) {
        let bytes = analysis.estimatedStorageBytes
        guard maximumEntries > 0,bytes <= maximumBytes else { return }
        while entries.count >= maximumEntries || retainedBytes > maximumBytes - bytes {
            guard let oldest = entries.min(by: { $0.value.use < $1.value.use }) else { break }
            retainedBytes -= oldest.value.analysis.estimatedStorageBytes; entries[oldest.key] = nil
        }
        clock &+= 1; entries[key] = Entry(analysis: analysis,use: clock); retainedBytes += bytes
    }
}
