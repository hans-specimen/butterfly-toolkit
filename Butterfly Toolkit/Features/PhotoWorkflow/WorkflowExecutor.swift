import Foundation
import CoreGraphics
import CryptoKit

/// Owns cached live state. All expensive services suspend off MainActor; publication is synchronous
/// inside this actor so a revision cannot change between its last check and replacing an output.
actor WorkflowExecutor {
    nonisolated struct Services: Sendable {
        var stack: @Sendable (FocusStackJob, UUID) async throws -> PSDSnapshot
        var refresh: @Sendable (URL, UUID, [WorkflowSourceFile]?) async throws -> PSDSnapshot
        var exportStack: @Sendable (PSDSnapshot) async throws -> StackPNG
        var infer: @Sendable (StackPNG) async throws -> MatteArtifact
        var install: @Sendable (PSDSnapshot, MatteArtifact) async throws -> PSDSnapshot
        var extract: @Sendable (PSDSnapshot) async throws -> RoleImages
        var analyze: @Sendable (RoleImages, GeometryRequest) async throws -> GeometrySolution
        var validateGeometry: @Sendable (RoleImages, GeometrySolution) async throws -> GeometrySolution
        var apply: @Sendable (PSDSnapshot, GeometrySolution) async throws -> PSDSnapshot
        var render: @Sendable (WorkflowAssetKind, RoleImages?, SquareLayout, URL?, URL?, URL) async throws -> Void
        var publish: @Sendable (URL, WorkflowArtifact) throws -> WorkflowArtifact
        var recover: @Sendable (WorkflowArtifact) throws -> WorkflowArtifact?
        var contentFingerprint: @Sendable (RoleImages) async throws -> String
        var validateInstalledMatte: @Sendable (RoleImages, StackPNG, MatteArtifact) async throws -> Void

        var endInferenceSession: @Sendable () async -> Void = {}

        static func live(bridge: PhotoshopWorkflowBridge, matte: WorkflowMatteService, geometry: WorkflowGeometryCache = WorkflowGeometryCache()) -> Self {
            let renderer = WorkflowAssetRenderer(), artifacts = WorkflowArtifactStore()
            return Self(stack: { try await bridge.stack(job: $0,owner: $1) },
                refresh: { try await bridge.refreshSavedPSD(document: $0,owner: $1,expectedSources: $2) },
                exportStack: { try await bridge.exportStackPNG(snapshot: $0) },
                infer: { try await matte.infer(input: $0) },
                install: { try await bridge.installMatte(snapshot: $0,matte: $1) },
                extract: { try await bridge.extractRoles(snapshot: $0) },
                analyze: { roles, request in try await geometry.geometry(source: roles,request: request) },
                validateGeometry: { roles, solution in
                    try await geometry.geometry(source: roles,request: GeometryRequest(),savedCandidate: solution)
                },
                apply: { try await bridge.applyGeometry(snapshot: $0,solution: $1) },
                render: { kind, roles, layout, source, watermark, destination in
                    try await Task.detached {
                        switch kind {
                        case .hd: guard let roles else { throw WorkflowStateError.invalidTransition }; try renderer.renderHD(roles: roles,destination: destination)
                        case .png4k: guard let roles else { throw WorkflowStateError.invalidTransition }; try renderer.render4K(roles: roles,layout: layout,destination: destination)
                        case .white1k, .footage, .xianyu: throw WorkflowStateError.invalidTransition
                        }
                    }.value
                },
                publish: { try artifacts.publish(temp: $0,artifact: $1) },recover: { try artifacts.recover(artifact: $0) },
                contentFingerprint: { roles in try await Task.detached {
                    try WorkflowExecutor.fingerprint([AIFileValidation.hash(roles.basePNG.path), WorkflowExecutor.encoded(roles.coordinateOrigin), WorkflowExecutor.encoded(roles.cropViewport)])
                }.value },
                validateInstalledMatte: { roles, input, matte in try await Task.detached {
                    guard try AIFileValidation.hash(input.pngURL.path) == input.fingerprint,
                          try AIFileValidation.hash(matte.alphaURL.path) == matte.alphaFingerprint,
                          try AIFileValidation.hash(matte.cutoutURL.path) == matte.cutoutFingerprint,
                          input.fingerprint == matte.inputPNGFingerprint, matte.pixelSize == input.pixelSize,
                          matte.orientation == 1, input.orientation == 1,
                          roles.coordinateOrigin == .zero, roles.pixelSize == input.pixelSize,
                          roles.editableExtent == CGRect(origin: .zero,size: input.pixelSize),
                          roles.cropViewport == CGRect(origin: .zero,size: input.pixelSize) else { throw WorkflowBridgeError.staleSource }
                    let original = try WorkflowRaster.read(input.pngURL), base = try WorkflowRaster.read(roles.basePNG)
                    let expectedMask = try WorkflowRaster.read(matte.alphaURL), mask = try WorkflowRaster.read(roles.maskPNG)
                    let expectedCutout = try WorkflowRaster.read(matte.cutoutURL), cutout = try WorkflowRaster.read(roles.cutoutPNG)
                    guard [original,base,expectedMask,mask,expectedCutout,cutout].allSatisfy({ $0.size == input.pixelSize && $0.orientation == 1 }),
                          original.pixels == base.pixels, original.profileData == base.profileData,
                          zip(expectedMask.pixels,mask.pixels).allSatisfy({ abs(Int($0)-Int($1)) <= 1 }),
                          zip(expectedCutout.pixels,cutout.pixels).allSatisfy({ abs(Int($0)-Int($1)) <= 4 }) else { throw WorkflowBridgeError.staleSource }
                    try WorkflowRaster.validateMatte(original: base,alpha: mask,cutout: cutout,respectSourceAlpha: true)
                }.value },endInferenceSession: { await matte.shutdown() })
        }

    }

    private let store: WorkflowBatchStore
    private let services: Services
    private let coordinator: PhotoshopExecutionCoordinator
    private var batches: [UUID: WorkflowBatch] = [:]
    private var manifests: [UUID: URL] = [:]
    private var saves: [UUID: Task<Void, Error>] = [:]
    private var running: Set<UUID> = []
    private var manual: [UUID: UUID] = [:]
    private var confirming: Set<UUID> = []
    private var stageRuns: [UUID: [UUID: Task<Void,Error>]] = [:]
    private let exportLimit: Int
    private let matteLimit: Int

    init(store: WorkflowBatchStore = WorkflowBatchStore(), services: Services,
         coordinator: PhotoshopExecutionCoordinator = .shared, exportLimit: Int = 2, matteLimit: Int = 2) {
        self.store = store; self.services = services; self.coordinator = coordinator
        self.exportLimit = max(1,min(2,exportLimit)); self.matteLimit = max(1,min(2,matteLimit))
    }

    func register(batch: WorkflowBatch, manifestURL: URL) async throws {
        guard batches[batch.id] == nil else { throw WorkflowStateError.invalidTransition }
        var value = batch
        value.selectedDerivativeKinds = []
        value.watermarkURL = nil
        try value.validate(); try value.validateStart(); try value.validateOutputURL(manifestURL)
        for task in value.sideTasks {
            if let saved = task.snapshot { try value.validateOutputURL(saved.workingURL) }
        }
        batches[value.id] = value; manifests[value.id] = manifestURL
        try await persist(value.id)
        for task in value.activeTasks { try await cleanMatteTemporaryFiles(value.id, task.id) }
    }
    func register(manifestURL: URL) async throws -> UUID {
        let value = try await store.load(from: manifestURL)
        guard batches[value.id] == nil else { return value.id }
        try await register(batch: value,manifestURL: manifestURL)
        return value.id
    }
    func batch(batchID: UUID) throws -> WorkflowBatch {
        guard let value = batches[batchID] else { throw WorkflowStateError.unknownTask }; return value
    }

    /// A narrow optimistic update API for checkpoint toggles, sources, presets and explicit exclusions.
    func update(batchID: UUID, event: WorkflowEvent) async throws {
        try reduce(batchID,event); try await persist(batchID)
    }
    func setExportDirectory(batchID: UUID, kind: WorkflowAssetKind, directory: URL) async throws {
        guard kind == .hd || kind == .png4k, directory.isFileURL,
              !running.contains(batchID), !confirming.contains(batchID), manual[batchID] == nil else {
            throw WorkflowStateError.invalidTransition
        }
        let value = try batch(batchID: batchID)
        guard value.exportDirectory(for: kind) != directory else { return }
        try edit(batchID) { batch in
            var locations = batch.outputLocations ?? WorkflowOutputLocations(hd: batch.exportDirectory(for: .hd), png4k: batch.exportDirectory(for: .png4k))
            if kind == .hd { locations.hd = directory } else { locations.png4k = directory }
            batch.outputLocations = locations
            for index in batch.specimens.indices {
                for side in WorkflowSide.allCases {
                    var task = side == .front ? batch.specimens[index].front : batch.specimens[index].back
                    // Published files retain their independent ownership receipts in the old folder.
                    task.artifacts.removeAll { $0.kind == kind }
                    if !batch.specimens[index].isExcluded {
                        if task[kind.stage].state == .completed || task[kind.stage].state == .failed {
                            task[kind.stage].state = .pending; task[kind.stage].error = nil
                            task[kind.stage].outputVersion = nil; task[kind.stage].confirmedVersion = nil
                            if kind == .png4k, task[.geometry].state == .completed,
                               let snapshot = task.snapshot, task.roleImages?.snapshotVersion == snapshot.contentVersion {
                                task[.png4k].state = .waitingReview
                                task[.png4k].outputVersion = try Self.fingerprint([snapshot.contentVersion, Self.encoded(task.squareLayout)])
                            }
                        }
                        task[kind.stage].revision += 1
                        if kind == .hd && task[.geometry].state == .completed { task.exportHD = true }
                        if kind == .png4k { task.fourKExportRequested = nil }
                    }
                    if side == .front { batch.specimens[index].front = task } else { batch.specimens[index].back = task }
                }
            }
        }
        try await persist(batchID)
    }

    func pause(batchID: UUID) async {
        guard let value = batches[batchID] else { return }
        try? reduce(batchID,.cancelRunning(expectedRevision: value.revision))
        for run in stageRuns[batchID]?.values ?? [:].values { run.cancel() }
        try? await persist(batchID)
        await services.endInferenceSession()
    }
    func continueAutomatic(batchID: UUID) async throws {
        guard !running.contains(batchID) else { throw WorkflowStateError.invalidTransition }
        if let owner = manual[batchID] {
            let before = try task(batchID,owner)
            guard let snapshot = before.snapshot else { throw WorkflowStateError.invalidTransition }
            let saved = try await services.refresh(snapshot.workingURL,owner,nil)
            try check(batchID,before,stage: .geometry,allowPaused: true)
            guard saved.contentVersion == snapshot.contentVersion, saved.roles == snapshot.roles,
                  saved.pixelSize == snapshot.pixelSize, saved.structureSummary == snapshot.structureSummary,
                  manual[batchID] == owner else { throw WorkflowStateError.staleVersion }
            if saved.roles != nil {
                _ = try await services.extract(saved)
                try check(batchID,before,stage: .geometry,allowPaused: true)
            }
            manual.removeValue(forKey: batchID)
            await coordinator.endManualEditing(owner: owner)
        }
        let value = try batch(batchID: batchID)
        try reduce(batchID,.resume(expectedRevision: value.revision)); try await persist(batchID)
        try await runPending(batchID: batchID)
    }
    func beginManualEditing(batchID: UUID, taskID: UUID) async throws -> URL {
        guard let task = try batch(batchID: batchID).task(id: taskID), let snapshot = task.snapshot,
              manual[batchID] == nil || manual[batchID] == taskID else { throw WorkflowStateError.invalidTransition }
        await pause(batchID: batchID)
        try await coordinator.beginManualEditing(owner: taskID)
        manual[batchID] = taskID
        return snapshot.workingURL
    }
    /// Caller supplies the observed edit class; bridge verifies saved, stable roles under the manual lease.
    func refreshSavedPSD(batchID: UUID, taskID: UUID, change: WorkflowPSDChange) async throws {
        let before = try task(batchID,taskID)
        guard let old = before.snapshot else { throw WorkflowStateError.invalidTransition }
        let saved = try await services.refresh(old.workingURL,taskID,nil)
        try check(batchID,before,stage: .geometry,allowPaused: true)
        if saved.contentVersion != old.contentVersion {
            try reduce(batchID,.savedPSDChanged(taskID: taskID,snapshot: saved,change: change,
                expectedSourceVersion: before.sourceRevision,expectedSnapshotVersion: old.contentVersion))
        }
        try mutateTask(batchID,taskID) { $0.geometryApplySourceVersion = nil }
        if saved.roles != nil {
            let roles = try await services.extract(saved)
            guard try task(batchID,taskID).snapshot?.contentVersion == saved.contentVersion else { throw WorkflowStateError.staleVersion }
            try mutateTask(batchID,taskID) { $0.roleImages = roles }
        }
        try await persist(batchID)
    }

    func runPending(batchID: UUID) async throws {
        guard !confirming.contains(batchID) else { return }
        try await runStages(batchID: batchID)
    }
    private func runStages(batchID: UUID) async throws {
        guard !running.contains(batchID), manual[batchID] == nil else { return }
        _ = try batch(batchID: batchID); running.insert(batchID); defer { running.remove(batchID) }
        do {
            while !(try batch(batchID: batchID)).isPaused {
                try Task.checkCancellation()
                var advanced = false
                for stage in WorkflowStage.processingStages {
                    let value = try batch(batchID: batchID)
                    let ids = value.activeTasks.filter { $0[stage].state == .pending && eligible($0,stage: stage,batch: value) }.map(\.id)
                    if !ids.isEmpty {
                        let limit = stage == .matte ? matteLimit : (stage == .hd || stage == .png4k ? exportLimit : 1)
                        try await runStageTasks(batchID: batchID,stage: stage,taskIDs: ids,limit: limit)
                        advanced = true
                    }
                    if stage == .matte { await services.endInferenceSession() }
                    if try batch(batchID: batchID).isPaused { break }
                }
                try await finish4KIntents(batchID)
                if try await advanceUncheckedReviews(batchID) { advanced = true }
                if !advanced { break }
            }
        } catch is CancellationError {
            await services.endInferenceSession()
            let value = try batch(batchID: batchID)
            try reduce(batchID,.cancelRunning(expectedRevision: value.revision)); try await persist(batchID)
            throw CancellationError()
        } catch {
            await services.endInferenceSession(); throw error
        }
        await services.endInferenceSession()
    }

    private func runStageTasks(batchID: UUID,stage: WorkflowStage,taskIDs: [UUID],limit: Int) async throws {
        defer { stageRuns[batchID] = nil }
        do {
            try await withThrowingTaskGroup(of: UUID.self) { group in
                var pending = taskIDs.makeIterator(), exhausted = false, active = 0
                while !exhausted || active > 0 {
                    while active < limit && !exhausted {
                        try Task.checkCancellation()
                        guard let id = pending.next() else { exhausted = true; break }
                        let value = try batch(batchID: batchID)
                        guard let item = value.activeTasks.first(where: { $0.id == id }),item[stage].state == .pending,
                              eligible(item,stage: stage,batch: value) else { continue }
                        let run = Task { try await self.execute(batchID,id,stage: stage) }
                        stageRuns[batchID,default: [:]][id] = run
                        group.addTask {
                            try await withTaskCancellationHandler { try await run.value } onCancel: { run.cancel() }
                            return id
                        }
                        active += 1
                    }
                    if active > 0,let id = try await group.next() { stageRuns[batchID]?[id] = nil; active -= 1 }
                }
            }
        } catch is CancellationError {
            // Explicit pause has already persisted pending states; parent cancellation still propagates.
            let paused = try batch(batchID: batchID).isPaused
            if Task.isCancelled || !paused { throw CancellationError() }
        }
    }

    private func advanceUncheckedReviews(_ batchID: UUID) async throws -> Bool {
        let value = try batch(batchID: batchID)
        guard !value.isPaused else { return false }
        var advanced = false
        for specimen in value.specimens where !specimen.isExcluded {
            let pair = [specimen.front, specimen.back]
            if value.checkGeometry == false && pair.allSatisfy({ $0[.geometry].state == .waitingReview }) {
                guard pair.allSatisfy({ $0.geometrySolution?.isApplicable == true }) else {
                    throw WorkflowBridgeError.invalidImage("\(specimen.baseName) 的自动构图未通过检查，请手动调整后确认")
                }
                try await applyGeometryConfirmation(batchID: batchID, solutions: Dictionary(uniqueKeysWithValues: pair.map { ($0.id, $0.geometrySolution!) }), exportHD: true)
                advanced = true
            }
            if value.check4K == false && value.exportDirectory(for: .png4k) != nil && pair.allSatisfy({ $0[.png4k].state == .waitingReview && $0.fourKExportRequested != true }) {
                try await prepare4KExport(batchID: batchID, layouts: Dictionary(uniqueKeysWithValues: pair.map { ($0.id, $0.squareLayout) }))
                advanced = true
            }
        }
        return advanced
    }

    func continueAfterReview(batchID: UUID, stage: WorkflowStage, specimenIDs: [UUID]) async throws {
        let value = try batch(batchID: batchID)
        guard Set(specimenIDs) == Set(value.specimens.filter { !$0.isExcluded }.map(\.id)) else { throw WorkflowStateError.invalidTransition }
        guard stage == .stack || stage == .matte else { throw WorkflowStateError.invalidTransition }
        for before in value.activeTasks {
            guard let snapshot = before.snapshot else { throw WorkflowStateError.invalidTransition }
            let saved = try await services.refresh(snapshot.workingURL,before.id,nil)
            try check(batchID,before,stage: stage,allowPaused: true)
            guard saved.contentVersion == snapshot.contentVersion, saved.roles == snapshot.roles,
                  saved.pixelSize == snapshot.pixelSize else { throw WorkflowStateError.staleVersion }
        }
        let expected = Dictionary(uniqueKeysWithValues: value.activeTasks.map { ($0.id,$0) })
        try checkSelection(batchID,expected,stage: stage,presets: value.presets,allowPaused: true)
        if let owner = manual.removeValue(forKey: batchID) { await coordinator.endManualEditing(owner: owner) }
        var current = try batch(batchID: batchID)
        if current.isPaused { try reduce(batchID,.resume(expectedRevision: current.revision)); current = try batch(batchID: batchID) }
        try reduce(batchID,.continueBatch(stage: stage,expectedRevision: current.revision))
        try await persist(batchID); try await runPending(batchID: batchID)
    }

    func confirmGeometry(batchID: UUID, solutions: [UUID: GeometrySolution], exportHD: Bool) async throws {
        guard !confirming.contains(batchID), !running.contains(batchID) else { throw WorkflowStateError.invalidTransition }
        confirming.insert(batchID); defer { confirming.remove(batchID) }
        try await applyGeometryConfirmation(batchID: batchID, solutions: solutions, exportHD: exportHD)
        try await runStages(batchID: batchID)
    }

    private func applyGeometryConfirmation(batchID: UUID, solutions: [UUID: GeometrySolution], exportHD: Bool) async throws {
        let ids = try selectedSpecimens(batchID,sideIDs: Set(solutions.keys),stage: .geometry)
        guard manual[batchID] == nil, !(try batch(batchID: batchID)).isPaused else { throw WorkflowStateError.invalidTransition }
        let presets = try batch(batchID: batchID).presets
        var expected = try Dictionary(uniqueKeysWithValues: solutions.keys.map { ($0,try task(batchID,$0)) })
        var validated = solutions
        for id in solutions.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let before = expected[id]!
            guard before.roleImages != nil, let solution = solutions[id],
                  before.geometryApplySourceVersion == nil, solution.sourceVersion == before.snapshot?.contentVersion,
                  solution.isApplicable else { throw WorkflowStateError.staleVersion }
            let currentRoles = try await readCurrentRoles(batchID,before,stage: .geometry)
            try checkSelection(batchID,expected,stage: .geometry,presets: presets)
            validated[id] = try await services.validateGeometry(currentRoles,solution)
            try checkSelection(batchID,expected,stage: .geometry,presets: presets)
        }
        for id in solutions.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            try checkSelection(batchID,expected,stage: .geometry,presets: presets)
            var before = try task(batchID,id)
            let solution = validated[id]!
            if before[.geometry].state == .completed, before.geometrySolution == solution {
                try mutateTask(batchID,id) { $0.exportHD = exportHD }
                if exportHD && before[.hd].outputVersion == "not-selected" { try invalidateOutputs(batchID,id,from: .hd) }
                expected[id] = try task(batchID,id)
                continue
            }
            if before[.geometry].state == .completed {
                try mutateTask(batchID,id) { $0[.geometry].state = .waitingReview; $0[.geometry].confirmedVersion = nil; $0[.geometry].revision += 1 }
                try invalidateOutputs(batchID,id,from: .hd)
                before = try task(batchID,id)
            }
            guard let snapshot = before.snapshot, solution.sourceVersion == snapshot.contentVersion,
                  before[.geometry].state == .waitingReview else { throw WorkflowStateError.staleVersion }
            try mutateTask(batchID,id) { $0.exportHD = exportHD; $0.geometryApplySourceVersion = snapshot.contentVersion }
            expected[id] = try task(batchID,id)
            try await persist(batchID)
            do {
                try checkSelection(batchID,expected,stage: .geometry,presets: presets)
                let saved = try await services.apply(snapshot,solution)
                try checkSelection(batchID,expected,stage: .geometry,presets: presets)
                // Applying geometry is intentionally never blindly retried after an interrupted write.
                let roles = try await services.extract(saved)
                try checkSelection(batchID,expected,stage: .geometry,presets: presets)
                var currentFit = solution
                currentFit.sourceVersion = saved.contentVersion; currentFit.angleDegrees = 0
                currentFit.rotationPivot = CGPoint(x: roles.cropViewport.midX,y: roles.cropViewport.midY)
                currentFit.subjectBounds = solution.subjectBounds.offsetBy(dx: -solution.sourceCropRect.minX,dy: -solution.sourceCropRect.minY)
                currentFit.sourceCropRect = roles.cropViewport; currentFit.outputSize = roles.cropViewport.size
                guard saved.pixelSize == solution.outputSize, roles.snapshotVersion == saved.contentVersion else { throw WorkflowBridgeError.invalidStructure }
                currentFit = try await services.validateGeometry(roles,currentFit)
                try checkSelection(batchID,expected,stage: .geometry,presets: presets)
                try mutateTask(batchID,id) {
                    $0.snapshot = saved; $0.roleImages = roles; $0.geometrySolution = currentFit
                    $0.geometryApplySourceVersion = nil; $0[.geometry].outputVersion = saved.contentVersion
                    $0[.geometry].revision += 1
                }
                expected[id] = try task(batchID,id)
                try await persist(batchID)
                try checkSelection(batchID,expected,stage: .geometry,presets: presets)
            } catch {
                await pause(batchID: batchID)
                throw error
            }
        }
        try checkSelection(batchID,expected,stage: .geometry,presets: presets)
        let value = try batch(batchID: batchID)
        var versions: [UUID: String] = [:]
        for id in solutions.keys {
            guard let version = value.task(id: id)?[.geometry].outputVersion else { throw WorkflowStateError.staleVersion }
            versions[id] = version
        }
        try reduce(batchID,.confirmSelected(specimenIDs: ids,stage: .geometry,outputVersions: versions,expectedRevision: value.revision))
        expected = try Dictionary(uniqueKeysWithValues: solutions.keys.map { ($0,try task(batchID,$0)) })
        try await persist(batchID)
        try checkSelection(batchID,expected,stage: .geometry,presets: presets)
    }

    func confirm4K(batchID: UUID, layouts: [UUID: SquareLayout]) async throws {
        guard try batch(batchID: batchID).exportDirectory(for: .png4k) != nil else {
            throw WorkflowBridgeError.invalidImage("请先选择 PNG4K 输出文件夹")
        }
        guard !confirming.contains(batchID), !running.contains(batchID) else { throw WorkflowStateError.invalidTransition }
        confirming.insert(batchID); defer { confirming.remove(batchID) }
        try await prepare4KExport(batchID: batchID, layouts: layouts)
        try await runStages(batchID: batchID)
    }

    private func prepare4KExport(batchID: UUID, layouts: [UUID: SquareLayout]) async throws {
        _ = try selectedSpecimens(batchID,sideIDs: Set(layouts.keys),stage: .png4k)
        guard manual[batchID] == nil, !(try batch(batchID: batchID)).isPaused else { throw WorkflowStateError.invalidTransition }
        let presets = try batch(batchID: batchID).presets
        var expected = try Dictionary(uniqueKeysWithValues: layouts.keys.map { ($0,try task(batchID,$0)) })
        for layout in layouts.values {
            guard layout.canvasSide == 4096, layout.safeMargin >= 0, layout.safeMargin < 2048,
                  layout.center.x.isFinite, layout.center.y.isFinite else { throw WorkflowStateError.invalidTransition }
        }
        for id in layouts.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            _ = try await readCurrentRoles(batchID,expected[id]!,stage: .png4k)
            try checkSelection(batchID,expected,stage: .png4k,presets: presets)
        }
        try checkSelection(batchID,expected,stage: .png4k,presets: presets)
        for (id,layout) in layouts {
            try invalidateOutputs(batchID,id,from: .png4k)
            try mutateTask(batchID,id) {
                $0.squareLayout = layout; $0.fourKExportRequested = true
                $0[.png4k].state = .pending; $0[.png4k].confirmedVersion = nil; $0[.png4k].revision += 1
            }
            expected[id] = try task(batchID,id)
        }
        try await persist(batchID)
        do { try checkSelection(batchID,expected,stage: .png4k,presets: presets) }
        catch {
            for (id,authorized) in expected {
                let current = try task(batchID,id)
                if current[.png4k].revision == authorized[.png4k].revision, current.fourKExportRequested == true {
                    try mutateTask(batchID,id) { $0.fourKExportRequested = nil }
                }
            }
            try await persist(batchID)
            throw error
        }
    }

    func retry(batchID: UUID, specimenIDs: [UUID], stage: WorkflowStage) async throws {
        let value = try batch(batchID: batchID)
        guard WorkflowStage.processingStages.contains(stage), !specimenIDs.isEmpty, Set(specimenIDs).isSubset(of: Set(value.specimens.filter { !$0.isExcluded }.map(\.id))) else { throw WorkflowStateError.invalidTransition }
        for specimen in value.specimens where specimenIDs.contains(specimen.id) {
            for side in [specimen.front,specimen.back] where side[stage].state == .failed {
                guard side.geometryApplySourceVersion == nil else { throw WorkflowStateError.invalidTransition }
                try mutateTask(batchID,side.id) { $0[stage].state = .pending; $0[stage].error = nil; $0[stage].revision += 1 }
            }
        }
        try await persist(batchID); try await runPending(batchID: batchID)
    }

    private func execute(_ batchID: UUID, _ id: UUID, stage: WorkflowStage) async throws {
        try Task.checkCancellation()
        let value = try batch(batchID: batchID)
        guard let pending = value.activeTasks.first(where: { $0.id == id }),pending[stage].state == .pending,
              eligible(pending,stage: stage,batch: value) else { return }
        try reduce(batchID,.stageStarted(taskID: id,stage: stage,expectedVersion: pending[stage].revision))
        var before = try task(batchID,id)
        try await persist(batchID)
        do {
            try Task.checkCancellation()
            try check(batchID,before,stage: stage)
            var output = ""
            switch stage {
            case .stack:
                let value = try batch(batchID: batchID)
                let specimen = value.specimens.first { $0.front.id == id || $0.back.id == id }!
                if before.stackAttemptURL == nil {
                    let attempt = value.sourceDirectory.appendingPathComponent("\(specimen.baseName)_\(before.side.fileSuffix).psd")
                    try value.validateOutputURL(attempt)
                    try mutateTask(batchID,id) { $0.stackAttemptURL = attempt }; try await persist(batchID)
                    before = try task(batchID,id)
                }
                let url = before.stackAttemptURL!
                try value.validateOutputURL(url)
                let saved: PSDSnapshot
                if FileManager.default.fileExists(atPath: url.path) {
                    saved = try await services.refresh(url,id,before.sources.files)
                } else {
                    for source in before.sources.files {
                        guard try AIFileValidation.hash(source.url.path) == source.fingerprint else { throw WorkflowBridgeError.staleSource }
                    }
                    let job = FocusStackJob(id: 0,sourceFiles: before.sources.files.map(\.url),destinationURL: url,butterflyName: specimen.baseName,side: before.side.fileSuffix)
                    saved = try await services.stack(job,id)
                }
                try check(batchID,before,stage: stage)
                guard saved.taskID == id, saved.workingURL == url else { throw WorkflowBridgeError.ownershipConflict }
                try mutateTask(batchID,id) { $0.snapshot = saved }; output = saved.contentVersion
            case .matte:
                guard let snapshot = before.snapshot else { throw WorkflowStateError.invalidTransition }
                let saved: PSDSnapshot
                if snapshot.roles != nil {
                    _ = try await services.extract(snapshot); saved = snapshot
                } else {
                    let input: StackPNG
                    if let cached = before.stackPNG, cached.snapshotVersion == snapshot.contentVersion { input = cached }
                    else {
                        input = try await services.exportStack(snapshot)
                        try check(batchID,before,stage: stage)
                        try mutateTask(batchID,id) { $0.stackPNG = input }; try await persist(batchID)
                    }
                    let matte: MatteArtifact
                    if let cached = before.matteArtifact, cached.inputPNGFingerprint == input.fingerprint { matte = cached }
                    else {
                        matte = try await services.infer(input)
                        try check(batchID,before,stage: stage)
                        // The old snapshot and validated immutable AI result are durable before PS publication.
                        try mutateTask(batchID,id) { $0.matteArtifact = matte }; try await persist(batchID)
                    }
                    try check(batchID,before,stage: stage)
                    if before.matteArtifact != nil {
                        let current = try await services.refresh(snapshot.workingURL,id,nil)
                        try check(batchID,before,stage: stage)
                        if current.contentVersion != snapshot.contentVersion {
                            guard current.roles?.isValid == true else { throw WorkflowBridgeError.staleSource }
                            let roles = try await services.extract(current)
                            try await services.validateInstalledMatte(roles,input,matte)
                            try check(batchID,before,stage: stage)
                            saved = current
                        } else { saved = try await services.install(snapshot,matte) }
                    } else { saved = try await services.install(snapshot,matte) }
                }
                try check(batchID,before,stage: stage)
                guard saved.roles?.isValid == true else { throw WorkflowBridgeError.invalidStructure }
                try mutateTask(batchID,id) { $0.snapshot = saved }; output = saved.contentVersion
            case .geometry:
                guard before.geometryApplySourceVersion == nil, let saved = before.snapshot else { throw WorkflowStateError.invalidTransition }
                let roles = try await services.extract(saved)
                try check(batchID,before,stage: stage)
                guard roles.snapshotVersion == saved.contentVersion else { throw WorkflowStateError.staleVersion }
                let solution: GeometrySolution
                if before.geometryRevalidationRequired, var candidate = before.geometrySolution {
                    // Prior geometry is already present in the saved PSD. Recheck its current fit only.
                    candidate.sourceVersion = saved.contentVersion; candidate.angleDegrees = 0
                    candidate.rotationPivot = CGPoint(x: roles.cropViewport.midX,y: roles.cropViewport.midY)
                    candidate.sourceCropRect = roles.cropViewport; candidate.outputSize = roles.cropViewport.size
                    do { candidate = try await services.validateGeometry(roles,candidate) }
                    catch { candidate.isApplicable = false; candidate.reason = error.localizedDescription }
                    solution = candidate
                } else if before.lastPSDChange == .geometry {
                    var candidate = before.geometrySolution ?? GeometrySolution(sourceVersion: saved.contentVersion,angleDegrees: 0,
                        rotationPivot: CGPoint(x: roles.cropViewport.midX,y: roles.cropViewport.midY),subjectBounds: roles.cropViewport,
                        sourceCropRect: roles.cropViewport,outputSize: roles.cropViewport.size,
                        actualMargins: WorkflowMargins(left: 0,top: 0,right: 0,bottom: 0),isApplicable: true)
                    candidate.sourceVersion = saved.contentVersion; candidate.angleDegrees = 0
                    candidate.sourceCropRect = roles.cropViewport; candidate.outputSize = roles.cropViewport.size
                    do { candidate = try await services.validateGeometry(roles,candidate) }
                    catch { candidate.isApplicable = false; candidate.reason = error.localizedDescription }
                    solution = candidate
                } else { solution = try await services.analyze(roles,before.geometryRequest) }
                try check(batchID,before,stage: stage)
                try mutateTask(batchID,id) { $0.roleImages = roles; $0.geometrySolution = solution }
                output = saved.contentVersion
            case .hd:
                if before.exportHD == false { output = "not-selected" }
                else {
                    guard before.exportHD == true else { throw WorkflowStateError.invalidTransition }
                    output = try await asset(batchID,id,kind: .hd).fileFingerprint
                }
            case .png4k:
                if before.fourKExportRequested == true { output = try await asset(batchID,id,kind: .png4k).fileFingerprint }
                else { output = try Self.fingerprint([before.snapshot?.contentVersion ?? "",Self.encoded(before.squareLayout)]) }
            case .derivatives:
                throw WorkflowStateError.invalidTransition
            }
            let final = try task(batchID,id)
            guard final[stage].revision == before[stage].revision, final.sourceRevision == before.sourceRevision,
                  !(try batch(batchID: batchID)).isPaused else { throw WorkflowStateError.staleVersion }
            try reduce(batchID,.stageCompleted(taskID: id,stage: stage,expectedVersion: before[stage].revision,outputVersion: output))
            try await persist(batchID)
            if stage == .matte { try await cleanMatteTemporaryFiles(batchID, id) }
        } catch is CancellationError { throw CancellationError() }
        catch {
            let current = try task(batchID,id)
            if current[stage].revision == before[stage].revision, current[stage].state == .running {
                if try batch(batchID: batchID).isPaused {
                    try mutateTask(batchID,id) { $0[stage].state = .pending; $0[stage].revision += 1 }
                } else {
                    try reduce(batchID,.stageFailed(taskID: id,stage: stage,expectedVersion: current[stage].revision,reason: error.localizedDescription))
                }
                try await persist(batchID)
            }
        }
    }

    private func cleanMatteTemporaryFiles(_ batchID: UUID, _ id: UUID) async throws {
        let value = try batch(batchID: batchID), task = try task(batchID, id)
        guard task.snapshot?.roles?.isValid == true,
              task[.matte].state == .completed || task[.matte].state == .waitingReview else { return }
        let work = value.outputDirectory.appendingPathComponent(".work")
        let urls = [task.stackPNG?.pngURL, task.stackPNG?.validBackgroundAlphaURL,
                    task.matteArtifact?.alphaURL, task.matteArtifact?.cutoutURL].compactMap { $0 }
        // The saved PSD and completed stage are durable before any temporary image disappears.
        for url in Set(urls) where url.pathExtension.lowercased() == "png" &&
            ["data/processed", "AI"].contains(where: { WorkflowBatch.isContained(url, in: work.appendingPathComponent($0)) }) {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        try mutateTask(batchID, id) { $0.stackPNG = nil; $0.matteArtifact = nil }
        try await persist(batchID)
    }

    private func asset(_ batchID: UUID, _ id: UUID, kind: WorkflowAssetKind) async throws -> WorkflowArtifact {
        let before = try task(batchID,id), value = try batch(batchID: batchID)
        let stage = kind.stage
        guard kind == .hd || kind == .png4k,
              let directory = value.exportDirectory(for: kind) else {
            throw WorkflowBridgeError.invalidImage("请先选择\(kind == .hd ? "堆栈原图" : "PNG4K")输出文件夹")
        }
        guard let roles = before.roleImages, roles.snapshotVersion == before.snapshot?.contentVersion else { throw WorkflowStateError.staleVersion }
        let source = kind == .hd ? try await services.contentFingerprint(roles) : try Self.fingerprint([roles.snapshotVersion,Self.encoded(before.geometrySolution)])
        let preset = try presetFingerprint(kind,batch: value,task: before)
        let specimen = value.specimens.first { $0.front.id == id || $0.back.id == id }!
        let url = directory.appendingPathComponent("\(specimen.baseName)_\(before.side.fileSuffix).\(kind == .hd ? "jpg" : "png")")
        try value.validateArtifactURL(url, kind: kind)
        let recipe = WorkflowArtifact(ownerTaskID: id,kind: kind,url: url,sourceFingerprint: source,presetFingerprint: preset,fileFingerprint: "",state: .pending)
        try check(batchID,before,stage: stage)
        if let existing = before.artifacts.last(where: { Self.sameRecipe($0,recipe) && $0.state == .completed }),
           let recovered = try services.recover(existing) { return recovered }
        // Receipt/recipe intent precedes file writes, allowing recovery when batch.json misses completion.
        if !before.artifacts.contains(where: { Self.sameRecipe($0,recipe) }) {
            try mutateTask(batchID,id) { $0.artifacts.append(recipe) }; try await persist(batchID)
        }
        if let recovered = try services.recover(recipe) {
            try check(batchID,before,stage: stage)
            try recordArtifact(batchID,id,recovered); try await persist(batchID); return recovered
        }
        let temp = value.outputDirectory.appendingPathComponent(".work/\(id)/\(UUID())/output.\(kind == .hd ? "jpg" : "png")")
        try value.validateOutputURL(temp)
        try FileManager.default.createDirectory(at: temp.deletingLastPathComponent(),withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp.deletingLastPathComponent()) }
        do {
            try await services.render(kind,before.roleImages,before.squareLayout,nil,nil,temp)
            try Task.checkCancellation()
            try check(batchID,before,stage: stage)
            let current = try task(batchID,id), latest = try batch(batchID: batchID)
            guard try presetFingerprint(kind,batch: latest,task: current) == preset,
                  current.artifacts.contains(where: { Self.sameRecipe($0,recipe) }) else { throw WorkflowStateError.staleVersion }
            try latest.validateArtifactURL(url, kind: kind); try latest.validateOutputURL(temp)
            // No await between the fence and publication: actor reentrancy cannot publish obsolete bytes.
            let result = try services.publish(temp,recipe)
            try recordArtifact(batchID,id,result); try await persist(batchID); return result
        } catch {
            if (try? check(batchID,before,stage: stage)) != nil {
                var failed = recipe; failed.state = .failed
                try recordArtifact(batchID,id,failed); try await persist(batchID)
            }
            throw error
        }
    }

    private func finish4KIntents(_ batchID: UUID) async throws {
        let value = try batch(batchID: batchID)
        guard !value.isPaused else { return }
        let selected = value.specimens.filter { !$0.isExcluded && [$0.front,$0.back].allSatisfy { task in
            task.fourKExportRequested == true && task[.png4k].state == .waitingReview &&
            task.artifacts.contains { artifact in artifact.kind == .png4k && artifact.state == .completed && artifact.fileFingerprint == task[.png4k].outputVersion }
        } }
        guard !selected.isEmpty else { return }
        let tasks = selected.flatMap { [$0.front,$0.back] }
        let versions = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id,$0[.png4k].outputVersion!) })
        try reduce(batchID,.confirmSelected(specimenIDs: Set(selected.map(\.id)),stage: .png4k,outputVersions: versions,expectedRevision: value.revision))
        for task in tasks { try mutateTask(batchID,task.id) { $0.fourKExportRequested = false } }
        try await persist(batchID)
    }

    private func readCurrentRoles(_ batchID: UUID, _ before: WorkflowSideTask, stage: WorkflowStage) async throws -> RoleImages {
        guard let snapshot = before.snapshot else { throw WorkflowStateError.invalidTransition }
        let roles = try await services.extract(snapshot)
        try check(batchID,before,stage: stage)
        guard roles.snapshotVersion == snapshot.contentVersion else { throw WorkflowStateError.staleVersion }
        try mutateTask(batchID,before.id) { $0.roleImages = roles }
        return roles
    }
    private func selectedSpecimens(_ batchID: UUID, sideIDs: Set<UUID>, stage: WorkflowStage) throws -> Set<UUID> {
        let value = try batch(batchID: batchID)
        let selected = value.specimens.filter { sideIDs.contains($0.front.id) || sideIDs.contains($0.back.id) }
        let tasks = selected.flatMap { [$0.front,$0.back] }
        guard !selected.isEmpty, selected.allSatisfy({ !$0.isExcluded }), Set(tasks.map(\.id)) == sideIDs,
              tasks.allSatisfy({ ($0[stage].state == .waitingReview || ($0[stage].state == .completed && $0[stage].confirmedVersion == $0[stage].outputVersion)) && $0.snapshot != nil && $0.roleImages?.snapshotVersion == $0.snapshot?.contentVersion }) else {
            throw WorkflowStateError.invalidTransition
        }
        return Set(selected.map(\.id))
    }
    private func eligible(_ task: WorkflowSideTask, stage: WorkflowStage, batch: WorkflowBatch) -> Bool {
        if stage == .hd && task.exportHD != false && batch.exportDirectory(for: .hd) == nil { return false }
        guard !batch.isPaused, WorkflowStage.processingStages.prefix(while: { $0 != stage }).allSatisfy({ task[$0].state == .completed }) else { return false }
        if stage != .stack, !batch.activeTasks.allSatisfy({ $0[.stack].state == .completed }) { return false }
        if stage != .stack && stage != .matte, !batch.activeTasks.allSatisfy({ $0[.matte].state == .completed }) { return false }
        return true
    }
    private func checkSelection(_ batchID: UUID, _ expected: [UUID: WorkflowSideTask], stage: WorkflowStage, presets: WorkflowPresets, allowPaused: Bool = false) throws {
        guard try batch(batchID: batchID).presets == presets else { throw WorkflowStateError.staleVersion }
        for (id,before) in expected {
            try check(batchID,before,stage: stage,allowPaused: allowPaused)
            let current = try task(batchID,id)
            guard current[stage] == before[stage], current.stackAttemptURL == before.stackAttemptURL,
                  current.geometryApplySourceVersion == before.geometryApplySourceVersion,
                  current.exportHD == before.exportHD, current.fourKExportRequested == before.fourKExportRequested,
                  current.geometrySolution == before.geometrySolution, current.squareLayout == before.squareLayout else {
                throw WorkflowStateError.staleVersion
            }
        }
    }
    private func check(_ batchID: UUID, _ before: WorkflowSideTask, stage: WorkflowStage, allowPaused: Bool = false) throws {
        let value = try batch(batchID: batchID), now = try task(batchID,before.id)
        guard (allowPaused || !value.isPaused), now.sourceRevision == before.sourceRevision, now.sources == before.sources,
              now[stage].revision == before[stage].revision, now.snapshot?.contentVersion == before.snapshot?.contentVersion,
              !value.specimens.contains(where: { $0.isExcluded && ($0.front.id == before.id || $0.back.id == before.id) }) else { throw WorkflowStateError.staleVersion }
    }
    private func task(_ batchID: UUID, _ taskID: UUID) throws -> WorkflowSideTask {
        guard let task = try batch(batchID: batchID).task(id: taskID) else { throw WorkflowStateError.unknownTask }; return task
    }
    private func reduce(_ id: UUID, _ event: WorkflowEvent) throws { batches[id] = try WorkflowStateMachine.reduce(batch: batch(batchID: id),event: event) }
    private func edit(_ id: UUID, _ body: (inout WorkflowBatch) throws -> Void) throws {
        var value = try batch(batchID: id); try body(&value); value.revision += 1; try value.validate(); batches[id] = value
    }
    private func mutateTask(_ batchID: UUID, _ id: UUID, _ body: (inout WorkflowSideTask) throws -> Void) throws {
        try edit(batchID) { value in
            guard let index = value.specimens.firstIndex(where: { $0.front.id == id || $0.back.id == id }) else { throw WorkflowStateError.unknownTask }
            if value.specimens[index].front.id == id { try body(&value.specimens[index].front) }
            else { try body(&value.specimens[index].back) }
        }
    }
    private func persist(_ id: UUID) async throws {
        let value = try batch(batchID: id), url = manifests[id]!, previous = saves[id], store = store
        // Enqueue before suspension: an older save can never finish after a newer revision's save.
        let write = Task { if let previous { _ = try? await previous.value }; try await store.save(value,to: url) }
        saves[id] = write
        try await write.value
    }
    private func invalidateOutputs(_ batchID: UUID, _ id: UUID, from stage: WorkflowStage) throws {
        let stages = Array(WorkflowStage.allCases.drop(while: { $0 != stage }))
        try mutateTask(batchID,id) { task in
            for stage in stages {
                task[stage].state = .pending; task[stage].revision += 1; task[stage].inputVersion += 1
                task[stage].outputVersion = nil; task[stage].confirmedVersion = nil; task[stage].error = nil
            }
            for index in task.artifacts.indices where stages.contains(task.artifacts[index].kind.stage) { task.artifacts[index].state = .pending }
            if stages.contains(.png4k) { task.fourKExportRequested = nil }
        }
    }
    private func recordArtifact(_ batchID: UUID, _ id: UUID, _ artifact: WorkflowArtifact) throws {
        try mutateTask(batchID,id) { task in
            if let index = task.artifacts.lastIndex(where: { Self.sameRecipe($0,artifact) }) { task.artifacts[index] = artifact }
            else { task.artifacts.append(artifact) }
        }
    }
    private func presetFingerprint(_ kind: WorkflowAssetKind, batch: WorkflowBatch, task: WorkflowSideTask) throws -> String {
        let preset: WorkflowPreset
        switch kind { case .hd: preset = batch.presets.hd; case .png4k: preset = batch.presets.png4k; case .xianyu: preset = batch.presets.xianyu; case .white1k: preset = batch.presets.white1k; case .footage: preset = batch.presets.footage }
        var parts = [preset.fingerprint,String(preset.version)]
        if kind == .png4k { parts.append(try Self.encoded(task.squareLayout)) }
        if kind == .xianyu {
            if let url = batch.watermarkURL { parts.append((try? AIFileValidation.hash(url.path)) ?? "unreadable-watermark") }
            else { parts.append("missing-watermark") }
        }
        return Self.fingerprint(parts)
    }
    private nonisolated static func sameRecipe(_ a: WorkflowArtifact, _ b: WorkflowArtifact) -> Bool {
        a.ownerTaskID == b.ownerTaskID && a.kind == b.kind && a.url == b.url && a.sourceFingerprint == b.sourceFingerprint && a.presetFingerprint == b.presetFingerprint
    }
    private nonisolated static func fingerprint(_ values: [String]) -> String {
        SHA256.hash(data: Data(values.joined(separator: "\u{0}").utf8)).map { String(format: "%02x",$0) }.joined()
    }
    private nonisolated static func encoded<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value),as: UTF8.self)
    }
}
