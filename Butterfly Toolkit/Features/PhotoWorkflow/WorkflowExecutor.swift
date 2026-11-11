// 调度照片批次各处理阶段，协调检查点与人工编辑，并通过版本校验和持久化顺序保护异步结果。

import Foundation
import CoreGraphics
import CryptoKit

/// 持有运行中的批次状态；耗时服务在 MainActor 外执行，产物发布则在此 actor 内同步完成，
/// 保证最后一次版本校验与替换输出之间不会发生修订变化。
actor WorkflowExecutor {
    // MARK: - 可注入服务与执行资源
    nonisolated struct Services: Sendable {
        var stack: @Sendable (FocusStackJob, UUID) async throws -> PSDSnapshot
        var refresh: @Sendable (URL, UUID, [WorkflowSourceFile]?) async throws -> PSDSnapshot
        var extract: @Sendable (PSDSnapshot) async throws -> RoleImages
        var analyze: @Sendable (RoleImages, GeometryRequest) async throws -> GeometrySolution
        var validateGeometry: @Sendable (RoleImages, GeometrySolution) async throws -> GeometrySolution
        var apply: @Sendable (PSDSnapshot, GeometrySolution) async throws -> PSDSnapshot
        var render: @Sendable (WorkflowAssetKind, RoleImages?, SquareLayout, URL?, URL?, URL) async throws -> Void
        var publish: @Sendable (URL, WorkflowArtifact) throws -> WorkflowArtifact
        var recover: @Sendable (WorkflowArtifact) throws -> WorkflowArtifact?
        var contentFingerprint: @Sendable (RoleImages) async throws -> String

        var publishSkippingExisting: (@Sendable (URL, WorkflowArtifact) throws -> WorkflowArtifact)? = nil
        var adoptManualMask: (@Sendable (URL, UUID) async throws -> PSDSnapshot)? = nil
        var restoreCheckpoint: (@Sendable (PSDSnapshot, URL) async throws -> PSDSnapshot)? = nil
        var acknowledgeManualResult: (@Sendable (PSDSnapshot) async throws -> Void)? = nil
        var taskDocument: (@Sendable (UUID, URL, @escaping @Sendable () async throws -> Void) async throws -> Void)? = nil
        var selectSubject: (@Sendable (PSDSnapshot) async throws -> PSDSnapshot)? = nil
        var finalize: (@Sendable (URL, UUID) async throws -> PSDSnapshot)? = nil
        var applyForFinalization: (@Sendable (PSDSnapshot, GeometrySolution) async throws -> PSDSnapshot)? = nil
        var openDocuments: (@Sendable () async throws -> [WorkflowOpenPhotoshopDocument])? = nil
        var verifyManualSaveOwnership: (@Sendable (URL, UUID) throws -> Void)? = nil
        var prepareAcceptedFinalPSD: (@Sendable (WorkflowAcceptedFinalPSD) async throws -> (PSDSnapshot, RoleImages))? = nil
        var adoptStack: (@Sendable (WorkflowSourceFile, UUID) async throws -> PSDSnapshot)? = nil

        static func live(bridge: PhotoshopWorkflowBridge, geometry: WorkflowGeometryCache = WorkflowGeometryCache()) -> Self {
            let renderer = WorkflowAssetRenderer(), artifacts = WorkflowArtifactStore()
            var services = Self(stack: { try await bridge.stack(job: $0,owner: $1) },
                refresh: { try await bridge.refreshSavedPSD(document: $0,owner: $1,expectedSources: $2) },
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
                adoptStack: { try await bridge.adoptStack(source: $0,owner: $1) })
            services.publishSkippingExisting = { try artifacts.publish(temp: $0,artifact: $1,overwriteExisting: false) }
            services.selectSubject = { try await bridge.selectSubject(snapshot: $0) }
            services.taskDocument = { owner, document, operation in
                try await bridge.withTaskDocument(owner: owner, document: document, operation: operation)
            }
            services.adoptManualMask = { try await bridge.adoptManualMask(document: $0,owner: $1) }
            services.restoreCheckpoint = { try await bridge.restoreCheckpoint(snapshot: $0,destination: $1) }
            services.acknowledgeManualResult = { try await bridge.acknowledgeManualResult(snapshot: $0) }
            services.finalize = { try await bridge.captureFinalPSD(document: $0,owner: $1) }
            services.applyForFinalization = { try await bridge.applyGeometry(snapshot: $0,solution: $1,createFinishedLayer: true) }
            services.openDocuments = { try await bridge.openDocuments() }
            services.verifyManualSaveOwnership = { try bridge.verifyManualSaveOwnership(document: $0, owner: $1) }
            services.prepareAcceptedFinalPSD = { try await bridge.prepareAcceptedFinalPSD($0) }
            return services
        }

    }

    private let store: WorkflowBatchStore
    private let services: Services
    private let coordinator: PhotoshopExecutionCoordinator
    private var batches: [UUID: WorkflowBatch] = [:]
    private var manifests: [UUID: URL] = [:]
    private var saves: [UUID: Task<Void, Error>] = [:]
    private var running: Set<UUID> = []
    private var pauseRequests: Set<UUID> = []
    private var manual: [UUID: UUID] = [:]
    private var batchReviewLeases: [UUID: UUID] = [:]
    private var reviewNeedsSave: Set<UUID> = []
    private var preparingFinal: Set<UUID> = []
    private var confirming: Set<UUID> = []
    private var acceptingSavedReview: Set<UUID> = []
    private var reprocessing: Set<UUID> = []
    private var acquiringManual: Set<UUID> = []
    private var stageRuns: [UUID: [UUID: Task<Void,Error>]] = [:]
    private let exportLimit: Int

    init(store: WorkflowBatchStore = WorkflowBatchStore(), services: Services,
         coordinator: PhotoshopExecutionCoordinator = .shared, exportLimit: Int = 2) {
        self.store = store; self.services = services; self.coordinator = coordinator
        self.exportLimit = max(1,min(2,exportLimit))
    }

    // MARK: - 批次登记与输出配置
    func register(batch: WorkflowBatch, manifestURL: URL) async throws {
        guard batches[batch.id] == nil else { throw WorkflowStateError.invalidTransition }
        var value = batch
        value.selectedDerivativeKinds = []
        value.watermarkURL = nil
        if value.manualFinalization == true {
            value.checkAfterStack = false; value.checkAfterMatte = false; value.checkGeometry = true; value.check4K = true
        }
        try value.validate(); try value.validateStart(); try value.validateOutputURL(manifestURL)
        for task in value.sideTasks {
            if let saved = task.snapshot { try value.validateOutputURL(saved.workingURL) }
        }
        batches[value.id] = value; manifests[value.id] = manifestURL
        acquiringManual.insert(value.id)
        defer { acquiringManual.remove(value.id) }
        do {
            if let session = value.manualReviewSessionID {
                try await coordinator.beginManualEditing(owner: session)
                batchReviewLeases[value.id] = session
            }
            try await persist(value.id)
        } catch {
            if let session = batchReviewLeases.removeValue(forKey: value.id) {
                await coordinator.endManualEditing(owner: session)
            }
            batches.removeValue(forKey: value.id); manifests.removeValue(forKey: value.id); saves.removeValue(forKey: value.id)
            throw error
        }
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

    /// 事件更新使用预期版本进行乐观校验，集中处理来源、预设和明确排除等状态变更。
    func update(batchID: UUID, event: WorkflowEvent) async throws {
        if case .excludeSpecimens = event, acquiringManual.contains(batchID) || reprocessing.contains(batchID) { throw WorkflowStateError.invalidTransition }
        if case let .excludeSpecimens(ids,_,_) = event, let owner = manual[batchID],
           try batch(batchID: batchID).specimens.contains(where: { ids.contains($0.id) && ($0.front.id == owner || $0.back.id == owner) }) {
            throw WorkflowStateError.invalidTransition
        }
        let protectingReview = batchReviewLeases[batchID] != nil || acquiringManual.contains(batchID) ||
            acceptingSavedReview.contains(batchID) || preparingFinal.contains(batchID)
        switch event {
        case .sourceChanged, .savedPSDChanged, .presetChanged:
            // 旧版几何或 4K 确认可以被这些事件失效，写回前仍需重新核对版本。
            guard !protectingReview else { throw WorkflowBridgeError.manualReviewActive }
        case .excludeSpecimens, .resume, .continueBatch, .confirmSelected:
            guard !protectingReview, !confirming.contains(batchID) else { throw WorkflowBridgeError.manualReviewActive }
        default: break
        }
        try reduce(batchID,event); try await persist(batchID)
    }
    func setExportDirectory(batchID: UUID, kind: WorkflowAssetKind, directory: URL) async throws {
        guard kind == .hd || kind == .png4k, directory.isFileURL,
              !running.contains(batchID), !confirming.contains(batchID), manual[batchID] == nil, batchReviewLeases[batchID] == nil,
              !acquiringManual.contains(batchID), !preparingFinal.contains(batchID) else {
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
                    // 已发布文件及其独立归属凭据保留在旧目录中。
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
                        task.requestedExports?.removeValue(forKey: kind)
                        if kind == .hd && task[.geometry].state == .completed { task.exportHD = true }
                        if kind == .png4k { task.fourKExportRequested = nil }
                    }
                    if side == .front { batch.specimens[index].front = task } else { batch.specimens[index].back = task }
                }
            }
        }
        try await persist(batchID)
    }

    // MARK: - 人工定稿与旧批次迁移
    func migrateToFinalization(batchID: UUID) async throws {
        guard !running.contains(batchID), !confirming.contains(batchID), !acquiringManual.contains(batchID),
              batchReviewLeases[batchID] == nil, !preparingFinal.contains(batchID) else { throw WorkflowStateError.invalidTransition }
        let value = try batch(batchID: batchID)
        guard value.manualFinalization != true else { return }
        guard !value.activeTasks.isEmpty,value.activeTasks.allSatisfy({ $0[.matte].state == .completed }) else {
            throw WorkflowBridgeError.invalidImage("请先在原流程完成本批次 AI 抠图及检查，再切换到人工定稿")
        }
        guard let manifest = manifests[batchID] else { throw WorkflowStateError.invalidTransition }
        let backup = manifest.deletingLastPathComponent().appendingPathComponent("batch-before-finalization-\(UUID()).json")
        try FileManager.default.copyItem(at: manifest,to: backup)
        try edit(batchID) { batch in
            batch.manualFinalization = true; batch.checkAfterStack = false; batch.checkAfterMatte = false
            batch.checkGeometry = true; batch.check4K = true
            for index in batch.specimens.indices where !batch.specimens[index].isExcluded {
                for side in WorkflowSide.allCases {
                    var task = side == .front ? batch.specimens[index].front : batch.specimens[index].back
                    task.historicalArtifacts = (task.historicalArtifacts ?? []) + task.artifacts; task.artifacts = []
                    task.exportHD = nil; task.fourKExportRequested = nil
                    for stage in [WorkflowStage.hd,.png4k] {
                        task[stage].state = .pending; task[stage].outputVersion = nil; task[stage].confirmedVersion = nil
                        task[stage].error = nil; task[stage].revision += 1
                    }
                    // 已完成 AI 的旧 PSD 可能被人工修改；迁移不能自动再次旋转或裁切。
                    if task[.matte].state == .completed,let snapshot = task.snapshot {
                        task[.geometry].state = .waitingReview; task[.geometry].outputVersion = snapshot.contentVersion
                        task[.geometry].confirmedVersion = nil; task[.geometry].revision += 1
                    }
                    if side == .front { batch.specimens[index].front = task } else { batch.specimens[index].back = task }
                }
            }
        }
        try await persist(batchID)
    }

    func refreshFinalPSD(batchID: UUID,taskID: UUID, adoptingCurrent: Bool = false) async throws {
        guard try batch(batchID: batchID).manualFinalization == true,
              batchReviewLeases[batchID] == nil, !preparingFinal.contains(batchID),
              manual[batchID] == nil || manual[batchID] == taskID,
              let finalize = services.finalize else { throw WorkflowStateError.invalidTransition }
        let before = try task(batchID,taskID)
        guard before.acceptedFinalPSD == nil, before[.stack].state == .completed,let snapshot = before.snapshot else { throw WorkflowStateError.invalidTransition }
        if !adoptingCurrent, before.geometryApplySourceVersion != nil || before.manualAdoptionRequired == true {
            throw WorkflowBridgeError.interruptedWrite("请重试原步骤核对保存凭据，或在人工编辑中明确采用当前姿态与裁切")
        }
        if !adoptingCurrent, ![.waitingReview,.completed].contains(before[.geometry].state) { throw WorkflowStateError.invalidTransition }
        if adoptingCurrent, manual[batchID] != taskID { throw WorkflowStateError.invalidTransition }
        let saved = try await finalize(snapshot.workingURL,taskID)
        try check(batchID,before,stage: .geometry,allowPaused: true)
        guard saved.taskID == taskID,saved.workingURL == snapshot.workingURL,saved.finalRoles?.isValid == true else { throw WorkflowBridgeError.invalidStructure }
        let roles = try await services.extract(saved)
        try check(batchID,before,stage: .geometry,allowPaused: true)
        guard roles.isFinalized == true,roles.snapshotVersion == saved.contentVersion else { throw WorkflowStateError.staleVersion }
        if adoptingCurrent {
            guard let acknowledge = services.acknowledgeManualResult else { throw WorkflowStateError.invalidTransition }
            try await acknowledge(saved)
            try check(batchID,before,stage: .geometry,allowPaused: true)
        }
        try mutateTask(batchID,taskID) { task in
            let changed = adoptingCurrent || task.snapshot != saved || task.roleImages?.isFinalized != true
            task.snapshot = saved; task.roleImages = roles; task.geometryApplySourceVersion = nil; task.manualAdoptionRequired = false
            if task[.matte].state != .completed {
                task[.matte].state = .completed; task[.matte].outputVersion = saved.contentVersion
                task[.matte].error = nil; task[.matte].revision += 1
            }
            task.geometryRevalidationRequired = false; task.lastPSDChange = nil; task.geometrySolution = nil
            if changed {
                task[.geometry].state = .waitingReview; task[.geometry].outputVersion = saved.contentVersion
                task[.geometry].confirmedVersion = nil; task[.geometry].error = nil; task[.geometry].revision += 1
                for stage in [WorkflowStage.hd,.png4k] {
                    task[stage].state = .pending; task[stage].outputVersion = nil; task[stage].confirmedVersion = nil
                    task[stage].error = nil; task[stage].revision += 1
                }
                for i in task.artifacts.indices { task.artifacts[i].state = .pending }
                task.fourKExportRequested = nil; task.exportHD = nil; task.requestedExports = nil
                task.exportNotes = Dictionary(task.artifacts.map { ($0.kind, "PSD 已更新，待重新导出") }, uniquingKeysWith: { _, latest in latest })
            }
        }
        try await persist(batchID)
    }

    /// 早期检查点允许仅查看后退出，修补蒙版后继续矫正；不会隐式接受未完成的几何步骤。
    func refreshManualPSD(batchID: UUID, taskID: UUID) async throws {
        let before = try task(batchID,taskID)
        if [.waitingReview,.completed].contains(before[.geometry].state) {
            try await refreshFinalPSD(batchID: batchID,taskID: taskID); return
        }
        guard manual[batchID] == taskID, let snapshot = before.snapshot else { throw WorkflowStateError.invalidTransition }
        guard before.geometryApplySourceVersion == nil, before.manualAdoptionRequired != true else {
            throw WorkflowBridgeError.interruptedWrite("请明确采用当前姿态与裁切，或结束前恢复可验证的保存结果")
        }
        let saved: PSDSnapshot
        do { saved = try await services.refresh(snapshot.workingURL,taskID,nil) }
        catch WorkflowBridgeError.invalidStructure {
            guard let adopt = services.adoptManualMask else { throw WorkflowBridgeError.invalidStructure }
            saved = try await adopt(snapshot.workingURL,taskID)
        }
        try check(batchID,before,stage: .geometry,allowPaused: true)
        let roles = saved.roles == nil ? nil : try await services.extract(saved)
        try check(batchID,before,stage: .geometry,allowPaused: true)
        guard saved.taskID == taskID, saved.workingURL == snapshot.workingURL,
              roles == nil || roles?.snapshotVersion == saved.contentVersion else { throw WorkflowBridgeError.staleSource }
        try mutateTask(batchID,taskID) { task in
            task.snapshot = saved; task.roleImages = roles
            if roles != nil, saved.contentVersion != snapshot.contentVersion || task[.matte].state != .completed {
                task[.matte].state = .completed; task[.matte].error = nil
                task[.matte].outputVersion = saved.contentVersion; task[.matte].revision += 1
                task[.geometry].state = .pending; task[.geometry].error = nil; task[.geometry].revision += 1
                task.geometrySolution = nil
                if task.checkpoints == nil { task.checkpoints = [:] }; task.checkpoints?[.matte] = saved
            }
        }
        try await persist(batchID)
    }

    /// 明确采用用户已保存的姿态与裁切，关闭未完成写入意图；仍需人工检查确认。
    func adoptCurrentPSD(batchID: UUID, taskID: UUID) async throws {
        try await refreshFinalPSD(batchID: batchID,taskID: taskID,adoptingCurrent: true)
    }

    /// 确认读取最终保存版本；此处只进入导出预览，不发布文件。
    func confirmFinalPSD(batchID: UUID,specimenIDs: Set<UUID>) async throws {
        guard !running.contains(batchID),!confirming.contains(batchID) else { throw WorkflowStateError.invalidTransition }
        let value = try batch(batchID: batchID)
        let selected = value.specimens.filter { specimenIDs.contains($0.id) && !$0.isExcluded }
        guard value.manualFinalization == true,!selected.isEmpty,selected.count == specimenIDs.count,
              selected.flatMap({ [$0.front,$0.back] }).allSatisfy({ $0.acceptedFinalPSD == nil && $0[.matte].state == .completed && [.waitingReview,.completed,.failed].contains($0[.geometry].state) }) else { throw WorkflowStateError.invalidTransition }
        confirming.insert(batchID); defer { confirming.remove(batchID) }
        if let owner = manual[batchID] {
            try await refreshManualPSD(batchID: batchID,taskID: owner)
            manual.removeValue(forKey: batchID); await coordinator.endManualEditing(owner: owner)
        }
        let ids = selected.flatMap { [$0.front.id,$0.back.id] }
        for id in ids { try await refreshFinalPSD(batchID: batchID,taskID: id) }
        let expected = try Dictionary(uniqueKeysWithValues: ids.map { ($0,try task(batchID,$0)) })
        let presets = try batch(batchID: batchID).presets
        for id in ids {
            guard let snapshot = expected[id]?.snapshot else { throw WorkflowStateError.invalidTransition }
            _ = try await services.extract(snapshot)
            try checkSelection(batchID,expected,stage: .geometry,presets: presets,allowPaused: true)
        }
        try edit(batchID) { batch in
            batch.isPaused = false
            for index in batch.specimens.indices where specimenIDs.contains(batch.specimens[index].id) {
                for side in WorkflowSide.allCases {
                    var task = side == .front ? batch.specimens[index].front : batch.specimens[index].back
                    task[.geometry].state = .completed; task[.geometry].outputVersion = task.snapshot!.contentVersion
                    task[.geometry].confirmedVersion = task[.geometry].outputVersion; task[.geometry].revision += 1
                    task[.png4k].state = .waitingReview; task[.png4k].outputVersion = task.snapshot!.contentVersion
                    task[.png4k].confirmedVersion = nil; task[.png4k].revision += 1; task.fourKExportRequested = nil
                    task.exportHD = true
                    if side == .front { batch.specimens[index].front = task } else { batch.specimens[index].back = task }
                }
            }
        }
        try await persist(batchID)
    }

    /// 确认单面预览对应的确切保存版本；不隐式启动导出或恢复暂停队列。
    func confirmFinalTasks(batchID: UUID, versions: [UUID: String]) async throws {
        guard !versions.isEmpty, !confirming.contains(batchID), !reprocessing.contains(batchID), manual[batchID] == nil,
              batchReviewLeases[batchID] == nil, !acquiringManual.contains(batchID), !preparingFinal.contains(batchID) else { throw WorkflowStateError.invalidTransition }
        let value = try batch(batchID: batchID)
        guard value.manualFinalization == true, Set(versions.keys).isSubset(of: Set(value.activeTasks.map(\.id))) else { throw WorkflowStateError.invalidTransition }
        for (id, version) in versions {
            let before = try task(batchID, id)
            guard before[.geometry].state == .waitingReview || before[.geometry].state == .completed,
                  before.manualAdoptionRequired != true, before.geometryApplySourceVersion == nil,
                  before.acceptedFinalPSD == nil, before.snapshot?.contentVersion == version else { throw WorkflowStateError.staleVersion }
        }
        confirming.insert(batchID); defer { confirming.remove(batchID) }
        for (id, version) in versions {
            try await refreshFinalPSD(batchID: batchID, taskID: id)
            guard try task(batchID, id).snapshot?.contentVersion == version else { throw WorkflowStateError.staleVersion }
        }
        for (id, version) in versions {
            try mutateTask(batchID, id) { task in
                task[.geometry].state = .completed
                task[.geometry].outputVersion = version; task[.geometry].confirmedVersion = version
                task[.geometry].revision += 1
            }
        }
        try await persist(batchID)
    }

    func requestExports(batchID: UUID, taskIDs: Set<UUID>, kinds: Set<WorkflowAssetKind>, policy: WorkflowExportPolicy, layouts: [UUID: SquareLayout]) async throws {
        let value = try batch(batchID: batchID)
        guard !taskIDs.isEmpty, !kinds.isEmpty, kinds.isSubset(of: [.hd, .png4k]),
              taskIDs.isSubset(of: Set(value.activeTasks.map(\.id))), !confirming.contains(batchID), !reprocessing.contains(batchID),
              !preparingFinal.contains(batchID), !acquiringManual.contains(batchID) else { throw WorkflowStateError.invalidTransition }
        for id in taskIDs {
            let task = try self.task(batchID, id)
            guard task.manualEdit == nil, task[.geometry].state == .completed, task[.geometry].confirmedVersion == task.finalPSDVersion,
                  kinds.allSatisfy({ task[$0.stage].state != .running }) else { throw WorkflowStateError.invalidTransition }
            if let layout = layouts[id], kinds.contains(.png4k) {
                guard layout.canvasSide == 4096, layout.safeMargin >= 0, layout.safeMargin < 2048,
                      layout.center.x.isFinite, layout.center.y.isFinite else { throw WorkflowStateError.invalidTransition }
            }
            for kind in kinds { guard value.exportDirectory(for: kind) != nil else { throw WorkflowStateError.invalidTransition } }
        }
        for id in taskIDs {
            try mutateTask(batchID, id) { task in
                if kinds.contains(.png4k), let layout = layouts[id] { task.squareLayout = layout }
                for kind in kinds {
                    let request = WorkflowExportRequest(snapshotVersion: task.finalPSDVersion!, directory: value.exportDirectory(for: kind)!, policy: policy)
                    if task.requestedExports == nil { task.requestedExports = [:] }
                    if task.exportNotes == nil { task.exportNotes = [:] }
                    task.requestedExports?[kind] = request; task.exportNotes?[kind] = "等待导出"
                    task[kind.stage].state = .pending; task[kind.stage].error = nil
                    task[kind.stage].confirmedVersion = nil; task[kind.stage].outputVersion = nil; task[kind.stage].revision += 1
                }
            }
        }
        try await persist(batchID)
        if manual[batchID] == nil, batchReviewLeases[batchID] == nil { try await runPending(batchID: batchID) }
    }

    func retryTasks(batchID: UUID, taskIDs: Set<UUID>, stage: WorkflowStage? = nil) async throws {
        guard batchReviewLeases[batchID] == nil, !acquiringManual.contains(batchID), !confirming.contains(batchID),
              !preparingFinal.contains(batchID) else { throw WorkflowBridgeError.manualReviewActive }
        let value = try batch(batchID: batchID)
        guard taskIDs.isSubset(of: Set(value.activeTasks.map(\.id))) else { throw WorkflowStateError.invalidTransition }
        for id in taskIDs {
            let before = try task(batchID, id)
            let stages = stage.map { [$0] } ?? [.stack, .matte, .geometry]
            for step in stages where before[step].state == .failed {
                try mutateTask(batchID, id) { $0[step].state = .pending; $0[step].error = nil; $0[step].revision += 1 }
            }
        }
        try await persist(batchID)
        if manual[batchID] == nil, batchReviewLeases[batchID] == nil { try await runPending(batchID: batchID) }
    }

    /// 重新处理在新工作文件上开始，旧 PSD、阶段快照和已导出文件全部保留。
    func reprocessTask(batchID: UUID, taskID: UUID, from stage: WorkflowStage, expectedVersion: String?) async throws {
        guard !running.contains(batchID), !reprocessing.contains(batchID), !confirming.contains(batchID), !acquiringManual.contains(batchID), manual[batchID] == nil,
              batchReviewLeases[batchID] == nil, !preparingFinal.contains(batchID),
              [WorkflowStage.stack,.matte,.geometry].contains(stage) else { throw WorkflowStateError.invalidTransition }
        reprocessing.insert(batchID); defer { reprocessing.remove(batchID) }
        let value = try batch(batchID: batchID), before = try task(batchID,taskID)
        guard value.activeTasks.contains(where: { $0.id == taskID }), before.finalPSDVersion == expectedVersion else { throw WorkflowStateError.staleVersion }
        let specimen = value.specimens.first { $0.front.id == taskID || $0.back.id == taskID }!
        let destination = value.generatedPSDDirectory.appendingPathComponent("重新处理-\(UUID())").appendingPathComponent("\(specimen.baseName)_\(before.side.fileSuffix).psd")
        try value.validateOutputURL(destination)
        let restored: PSDSnapshot?
        if stage == .stack { restored = nil }
        else {
            let previous: WorkflowStage = stage == .matte ? .stack : .matte
            guard let checkpoint = before.checkpoints?[previous], let restore = services.restoreCheckpoint else { throw WorkflowStateError.invalidTransition }
            restored = try await restore(checkpoint,destination)
            try check(batchID,before,stage: stage,allowPaused: true)
        }
        try mutateTask(batchID,taskID) { task in
            // 已确认保存凭据与阶段状态必须一起更新，清单才始终有效。
            invalidateOutputs(&task, from: stage)
            task.snapshot = restored; task.stackAttemptURL = destination; task.roleImages = nil
            task.geometrySolution = nil; task.geometryApplySourceVersion = nil; task.manualAdoptionRequired = false
            task.acceptedFinalPSD = nil; task.finalPreparationError = nil; task.manualEditError = nil
            task.geometryRevalidationRequired = false; task.lastPSDChange = nil
            task.requestedExports = nil; task.exportNotes = [.hd:"已重新处理，待重新确认",.png4k:"已重新处理，待重新确认"]
            for step in [WorkflowStage.stack,.matte,.geometry].drop(while: { $0 != stage }) { task.checkpoints?.removeValue(forKey: step) }
        }
        try await persist(batchID)
        try await runPending(batchID: batchID)
    }

    func endManualEditing(batchID: UUID) async throws {
        guard batchReviewLeases[batchID] == nil else { throw WorkflowBridgeError.manualReviewActive }
        guard let owner = manual[batchID] else { return }
        try await refreshManualPSD(batchID: batchID, taskID: owner)
        manual.removeValue(forKey: batchID)
        await coordinator.endManualEditing(owner: owner)
        // 结束人工编辑并不等于批准恢复自动队列。
        try await persist(batchID)
    }

    // MARK: - 暂停与人工编辑协调
    func pause(batchID: UUID) async {
        guard let value = batches[batchID] else { return }
        if value.manualFinalization == true {
            if running.contains(batchID) { pauseRequests.insert(batchID) }
            else { try? reduce(batchID,.pause(expectedRevision: value.revision)); try? await persist(batchID) }
            return
        }
        try? reduce(batchID,.cancelRunning(expectedRevision: value.revision))
        for run in stageRuns[batchID]?.values ?? [:].values { run.cancel() }
        try? await persist(batchID)
    }
    func continueAutomatic(batchID: UUID) async throws {
        guard !running.contains(batchID), !reprocessing.contains(batchID), !acquiringManual.contains(batchID),
              batchReviewLeases[batchID] == nil, !preparingFinal.contains(batchID), !confirming.contains(batchID) else { throw WorkflowStateError.invalidTransition }
        if let owner = manual[batchID],try batch(batchID: batchID).manualFinalization == true {
            try await refreshManualPSD(batchID: batchID,taskID: owner)
            manual.removeValue(forKey: batchID); await coordinator.endManualEditing(owner: owner)
        }
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
        guard !confirming.contains(batchID), !reprocessing.contains(batchID), !acquiringManual.contains(batchID),
              batchReviewLeases[batchID] == nil, !preparingFinal.contains(batchID) else { throw WorkflowStateError.invalidTransition }
        acquiringManual.insert(batchID); defer { acquiringManual.remove(batchID) }
        if try batch(batchID: batchID).manualFinalization == true,let owner = manual[batchID],owner != taskID {
            try await refreshManualPSD(batchID: batchID,taskID: owner)
            manual.removeValue(forKey: batchID); await coordinator.endManualEditing(owner: owner)
        }
        guard let task = try batch(batchID: batchID).task(id: taskID), task.snapshot != nil,
              manual[batchID] == nil || manual[batchID] == taskID else { throw WorkflowStateError.invalidTransition }
        await pause(batchID: batchID)
        // 等已派发步骤完成并持久化，不能在暂停请求之后抢走仍在使用的文档。
        while running.contains(batchID) { try await Task.sleep(for: .milliseconds(25)) }
        try await coordinator.beginManualEditing(owner: taskID)
        manual[batchID] = taskID
        guard let latest = try self.task(batchID,taskID).snapshot else { throw WorkflowStateError.invalidTransition }
        return latest.workingURL
    }
    /// 调用方提供编辑类型，桥接层在人工编辑租约内校验已保存且稳定的角色结构。
    func refreshSavedPSD(batchID: UUID, taskID: UUID, change: WorkflowPSDChange) async throws {
        guard batchReviewLeases[batchID] == nil, !acquiringManual.contains(batchID), !preparingFinal.contains(batchID) else {
            throw WorkflowBridgeError.manualReviewActive
        }
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

    // MARK: - 阶段队列与抠图子阶段
    func runPending(batchID: UUID) async throws {
        guard !confirming.contains(batchID) else { return }
        try await runStages(batchID: batchID)
    }
    private func runStages(batchID: UUID) async throws {
        guard !running.contains(batchID), manual[batchID] == nil, batchReviewLeases[batchID] == nil,
              !acquiringManual.contains(batchID), !preparingFinal.contains(batchID) else { return }
        _ = try batch(batchID: batchID); running.insert(batchID); defer { running.remove(batchID); pauseRequests.remove(batchID) }
        do {
            while !(try batch(batchID: batchID)).isPaused {
                try Task.checkCancellation()
                var advanced = false
                if try batch(batchID: batchID).manualFinalization == true {
                    // 每面走完自动阶段后才开始下一面，失败只阻止该面的后续步骤。
                    let ids = try batch(batchID: batchID).activeTasks.map(\.id)
                    for id in ids {
                        let value = try batch(batchID: batchID)
                        guard let task = value.task(id: id), [WorkflowStage.stack,.matte,.geometry].contains(where: { task[$0].state == .pending && eligible(task,stage: $0,batch: value) }) else { continue }
                        let specimen = value.specimens.first { $0.front.id == id || $0.back.id == id }!
                        let document = task.snapshot?.workingURL ?? task.stackAttemptURL ?? value.generatedPSDDirectory.appendingPathComponent("\(specimen.baseName)_\(task.side.fileSuffix).psd")
                        if let scope = services.taskDocument {
                            try await scope(id, document) { try await self.runAutomaticTask(batchID: batchID, taskID: id) }
                        } else { try await runAutomaticTask(batchID: batchID, taskID: id) }
                        advanced = true
                        if try batch(batchID: batchID).isPaused { break }
                    }
                }
                for stage in WorkflowStage.processingStages {
                    if try batch(batchID: batchID).manualFinalization == true,
                       [WorkflowStage.stack, .matte, .geometry].contains(stage) { continue }
                    let value = try batch(batchID: batchID)
                    let ids = value.activeTasks.filter { $0[stage].state == .pending && eligible($0,stage: stage,batch: value) }.map(\.id)
                    if !ids.isEmpty {
                        let limit = stage == .hd || stage == .png4k ? exportLimit : 1
                        try await runStageTasks(batchID: batchID,stage: stage,taskIDs: ids,limit: limit)
                        advanced = true
                    }
                    try await finishRequestedPause(batchID)
                    if try batch(batchID: batchID).isPaused { break }
                }
                try await finish4KIntents(batchID)
                if try await advanceUncheckedReviews(batchID) { advanced = true }
                if !advanced { break }
            }
        } catch is CancellationError {
                let value = try batch(batchID: batchID)
            try reduce(batchID,.cancelRunning(expectedRevision: value.revision)); try await persist(batchID)
            throw CancellationError()
        } catch {
            let value = try batch(batchID: batchID)
            if value.manualFinalization == true { try reduce(batchID,.pause(expectedRevision: value.revision)); try await persist(batchID) }
            throw error
        }
    }

    private func runAutomaticTask(batchID: UUID, taskID: UUID) async throws {
        for stage in [WorkflowStage.stack,.matte,.geometry] {
            let value = try batch(batchID: batchID)
            guard let task = value.task(id: taskID), task[stage].state == .pending,
                  eligible(task,stage: stage,batch: value) else { continue }
            try await runStageTasks(batchID: batchID,stage: stage,taskIDs: [taskID],limit: 1)
            try await finishRequestedPause(batchID)
            if try batch(batchID: batchID).isPaused { break }
        }
    }

    private func finishRequestedPause(_ batchID: UUID) async throws {
        guard pauseRequests.contains(batchID) else { return }
        let value = try batch(batchID: batchID)
        try reduce(batchID,.pause(expectedRevision: value.revision)); try await persist(batchID)
    }

    private func runStageTasks(batchID: UUID,stage: WorkflowStage,taskIDs: [UUID],limit: Int) async throws {
        defer { stageRuns[batchID] = nil }
        do {
            try await withThrowingTaskGroup(of: UUID.self) { group in
                var pending = taskIDs.makeIterator(), exhausted = false, active = 0
                while !exhausted || active > 0 {
                    while active < limit && !exhausted {
                        try Task.checkCancellation()
                        if pauseRequests.contains(batchID) { exhausted = true; break }
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
            // 显式暂停已持久化待处理状态；来自父任务的取消仍需继续传播。
            let paused = try batch(batchID: batchID).isPaused
            if Task.isCancelled || !paused { throw CancellationError() }
        }
    }

    private func advanceUncheckedReviews(_ batchID: UUID) async throws -> Bool {
        let value = try batch(batchID: batchID)
        guard !value.isPaused,value.manualFinalization != true else { return false }
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
        guard batchReviewLeases[batchID] == nil, !acquiringManual.contains(batchID), !preparingFinal.contains(batchID) else {
            throw WorkflowBridgeError.manualReviewActive
        }
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
        guard try batch(batchID: batchID).manualFinalization != true else { throw WorkflowStateError.invalidTransition }
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
                let saved = try await services.apply(snapshot,solution).carryingCleanup(from: snapshot,geometry: solution)
                try checkSelection(batchID,expected,stage: .geometry,presets: presets)
                // 几何写入中断后禁止盲目重试，避免再次叠加旋转或裁切。
                let roles = try await services.extract(saved)
                try checkSelection(batchID,expected,stage: .geometry,presets: presets)
                // 写回后坐标原点已随裁切移动；将增量角度归零，防止下一次确认重复旋转。
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
        guard batchReviewLeases[batchID] == nil, !acquiringManual.contains(batchID), !preparingFinal.contains(batchID) else {
            throw WorkflowBridgeError.manualReviewActive
        }
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
            if try batch(batchID: batchID).manualFinalization == true {
                try mutateTask(batchID,id) { task in
                    if task[.hd].state == .failed { task[.hd].state = .pending; task[.hd].error = nil; task[.hd].revision += 1 }
                }
            }
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
        guard batchReviewLeases[batchID] == nil, !acquiringManual.contains(batchID), !preparingFinal.contains(batchID) else {
            throw WorkflowBridgeError.manualReviewActive
        }
        let value = try batch(batchID: batchID)
        guard WorkflowStage.processingStages.contains(stage), !specimenIDs.isEmpty, Set(specimenIDs).isSubset(of: Set(value.specimens.filter { !$0.isExcluded }.map(\.id))) else { throw WorkflowStateError.invalidTransition }
        let stages: [WorkflowStage] = value.manualFinalization == true && stage == .png4k ? [.hd,.png4k] : [stage]
        for specimen in value.specimens where specimenIDs.contains(specimen.id) {
            for side in [specimen.front,specimen.back] {
                for retryStage in stages where side[retryStage].state == .failed {
                    guard side.geometryApplySourceVersion == nil else { throw WorkflowStateError.invalidTransition }
                    try mutateTask(batchID,side.id) { $0[retryStage].state = .pending; $0[retryStage].error = nil; $0[retryStage].revision += 1 }
                }
            }
        }
        try await persist(batchID); try await runPending(batchID: batchID)
    }

    // MARK: - 单面阶段执行与失败记录
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
            if let kind = [WorkflowAssetKind.hd, .png4k].first(where: { $0.stage == stage }),
               let request = before.requestedExports?[kind] {
                // 在 asset 捕获状态前完成已确认版本的验证，阶段自己的快照更新不会被视为过时。
                try await prepareAcceptedPSD(batchID, before, expectedVersion: request.snapshotVersion)
                try checkExportPreparation(batchID, before, stage: stage)
                before = try task(batchID, id)
            }
            var output = ""
            switch stage {
            case .stack:
                let value = try batch(batchID: batchID)
                let specimen = value.specimens.first { $0.front.id == id || $0.back.id == id }!
                if before.stackAttemptURL == nil {
                    let attempt = before.sources.isPSD && value.manualFinalization != true ? before.sources.first.url : value.generatedPSDDirectory.appendingPathComponent("\(specimen.baseName)_\(before.side.fileSuffix).psd")
                    try value.validateOutputURL(attempt)
                    try mutateTask(batchID,id) { $0.stackAttemptURL = attempt }; try await persist(batchID)
                    before = try task(batchID,id)
                }
                let url = before.stackAttemptURL!
                try value.validateOutputURL(url)
                let saved: PSDSnapshot
                if before.sources.isPSD {
                    guard let adopt = services.adoptStack else { throw WorkflowStateError.invalidTransition }
                    let source = before.sources.first
                    guard try AIFileValidation.hash(source.url.path) == source.fingerprint else { throw WorkflowBridgeError.staleSource }
                    if url != source.url {
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),withIntermediateDirectories: true)
                        if FileManager.default.fileExists(atPath: url.path) {
                            // 重试只能恢复已有归属凭据的工作文件，内容相同不构成认领授权。
                            saved = try await services.refresh(url,id,nil)
                            guard saved.contentVersion == source.fingerprint else { throw WorkflowBridgeError.staleSource }
                        } else {
                            try FileManager.default.copyItem(at: source.url,to: url)
                            guard try AIFileValidation.hash(url.path) == source.fingerprint else { throw WorkflowBridgeError.staleSource }
                            saved = try await adopt(WorkflowSourceFile(url: url,fingerprint: source.fingerprint),id)
                        }
                    } else {
                        saved = try await adopt(source,id)
                    }
                } else if FileManager.default.fileExists(atPath: url.path) {
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
                try mutateTask(batchID,id) { $0.snapshot = saved; $0.stackPNG = nil; if $0.checkpoints == nil { $0.checkpoints = [:] }; $0.checkpoints?[.stack] = saved }; output = saved.contentVersion
            case .matte:
                guard let snapshot = before.snapshot else { throw WorkflowStateError.invalidTransition }
                let saved: PSDSnapshot
                if snapshot.roles != nil {
                    _ = try await services.extract(snapshot); saved = snapshot
                } else {
                    guard let selectSubject = services.selectSubject else { throw WorkflowStateError.invalidTransition }
                    saved = try await selectSubject(snapshot)
                }
                try check(batchID,before,stage: stage)
                guard saved.roles?.isValid == true else { throw WorkflowBridgeError.invalidStructure }
                try mutateTask(batchID,id) { $0.snapshot = saved; $0.stackPNG = nil; $0.matteArtifact = nil; $0.manualAdoptionRequired = false; if $0.checkpoints == nil { $0.checkpoints = [:] }; $0.checkpoints?[.matte] = saved }
                output = saved.contentVersion
            case .geometry:
                guard let saved = before.snapshot else { throw WorkflowStateError.invalidTransition }
                let solution: GeometrySolution
                if let interruptedVersion = before.geometryApplySourceVersion {
                    guard interruptedVersion == saved.contentVersion, let pending = before.geometrySolution,
                          pending.sourceVersion == saved.contentVersion, pending.isApplicable else { throw WorkflowBridgeError.interruptedWrite("缺少可验证的原始矫正方案") }
                    solution = pending
                } else {
                let roles = try await services.extract(saved)
                try check(batchID,before,stage: stage)
                guard roles.snapshotVersion == saved.contentVersion else { throw WorkflowStateError.staleVersion }
                if before.geometryRevalidationRequired, var candidate = before.geometrySolution {
                    // 已保存 PSD 已包含此前的几何变换，此处只重新校验当前构图适配性。
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
                }
                try check(batchID,before,stage: stage)
                if try batch(batchID: batchID).manualFinalization == true,solution.isApplicable {
                    try mutateTask(batchID,id) { $0.geometryApplySourceVersion = saved.contentVersion; $0.geometrySolution = solution }
                    try await persist(batchID)
                    let apply = services.apply
                    let applied = try await apply(saved,solution).carryingCleanup(from: saved,geometry: solution)
                    try check(batchID,before,stage: stage)
                    let extracted = try await services.extract(applied)
                    try check(batchID,before,stage: stage)
                    guard applied.pixelSize == solution.outputSize,extracted.snapshotVersion == applied.contentVersion else { throw WorkflowBridgeError.invalidStructure }
                    var fit = solution
                    let toSavedCanvas: (CGPoint) -> CGPoint = { point in
                        let rotated = WorkflowPreviewCoordinates.rotate(point,degrees: solution.angleDegrees,pivot: solution.rotationPivot)
                        return CGPoint(x: rotated.x-solution.sourceCropRect.minX,y: rotated.y-solution.sourceCropRect.minY)
                    }
                    fit.leftWingTip = solution.leftWingTip.map(toSavedCanvas)
                    fit.rightWingTip = solution.rightWingTip.map(toSavedCanvas)
                    fit.sourceVersion = applied.contentVersion; fit.angleDegrees = 0
                    fit.rotationPivot = CGPoint(x: extracted.cropViewport.midX,y: extracted.cropViewport.midY)
                    fit.subjectBounds = solution.subjectBounds.offsetBy(dx: -solution.sourceCropRect.minX,dy: -solution.sourceCropRect.minY)
                    fit.sourceCropRect = extracted.cropViewport; fit.outputSize = extracted.cropViewport.size
                    try mutateTask(batchID,id) {
                        $0.snapshot = applied; $0.roleImages = extracted; $0.geometrySolution = fit; $0.geometryApplySourceVersion = nil; $0.manualAdoptionRequired = false
                    }
                    output = applied.contentVersion
                } else {
                    let roles = try await services.extract(saved)
                    try check(batchID,before,stage: stage)
                    try mutateTask(batchID,id) { $0.roleImages = roles; $0.geometrySolution = solution }
                    if try batch(batchID: batchID).manualFinalization == true, !solution.isApplicable {
                        throw WorkflowBridgeError.invalidImage(solution.reason ?? "无法可靠应用矫正，请在 PS 检查后采用当前姿态")
                    }
                    output = saved.contentVersion
                }
            case .hd:
                if before.requestedExports?[.hd] != nil { output = try await asset(batchID,id,kind: .hd).fileFingerprint }
                else if before.exportHD == false { output = "not-selected" }
                else {
                    guard before.exportHD == true else { throw WorkflowStateError.invalidTransition }
                    output = try await asset(batchID,id,kind: .hd).fileFingerprint
                }
            case .png4k:
                if before.requestedExports?[.png4k] != nil || before.fourKExportRequested == true { output = try await asset(batchID,id,kind: .png4k).fileFingerprint }
                else { output = try Self.fingerprint([before.snapshot?.contentVersion ?? "",Self.encoded(before.squareLayout)]) }
            case .derivatives:
                throw WorkflowStateError.invalidTransition
            }
            let final = try task(batchID,id)
            guard final[stage].revision == before[stage].revision, final.sourceRevision == before.sourceRevision,
                  !(try batch(batchID: batchID)).isPaused else { throw WorkflowStateError.staleVersion }
            try reduce(batchID,.stageCompleted(taskID: id,stage: stage,expectedVersion: before[stage].revision,outputVersion: output))
            if let kind = [WorkflowAssetKind.hd, .png4k].first(where: { $0.stage == stage }), before.requestedExports?[kind] != nil {
                try mutateTask(batchID,id) {
                    $0[stage].state = .completed; $0[stage].confirmedVersion = output
                    $0.requestedExports?.removeValue(forKey: kind)
                    if $0.exportNotes?[kind] == "等待导出" { $0.exportNotes?[kind] = "导出成功" }
                }
            }
            try await persist(batchID)
        } catch ExportOutcome.skippedOutdated(let kind) {
            try mutateTask(batchID,id) {
                $0[stage].state = .pending; $0[stage].outputVersion = nil; $0[stage].confirmedVersion = nil
                $0[stage].revision += 1; $0.requestedExports?.removeValue(forKey: kind)
                $0.exportNotes?[kind] = "待更新，已跳过"
            }
            try await persist(batchID)
        } catch is CancellationError { throw CancellationError() }
        catch {
            let current = try task(batchID,id)
            if current[stage].revision == before[stage].revision, current[stage].state == .running {
                if try batch(batchID: batchID).isPaused {
                    try mutateTask(batchID,id) { $0[stage].state = .pending; $0[stage].revision += 1 }
                } else {
                    try reduce(batchID,.stageFailed(taskID: id,stage: stage,expectedVersion: current[stage].revision,reason: error.localizedDescription))
                }
                if case WorkflowBridgeError.interruptedWrite = error {
                    try mutateTask(batchID,id) { $0.manualAdoptionRequired = true }
                }
                if Self.requiresPause(error) {
                    let value = try batch(batchID: batchID)
                    try reduce(batchID,.pause(expectedRevision: value.revision))
                }
                try await persist(batchID)
            }
        }
    }

    private static func requiresPause(_ error: Error) -> Bool {
        if let error = error as? FocusStackError {
            switch error {
            case .photoshopNotFound, .invalidOutputFolder: return true
            case .scriptFailed(let message): return ["-600","-1712","-1743","not running","timed out"].contains { message.contains($0) }
            default: break
            }
        }
        if let error = error as? WorkflowBridgeError {
            switch error {
            case .unsavedDocument, .interruptedWrite: return true
            case .photoshop(let message): return ["-600","-1712","-1743","not running","timed out"].contains { message.contains($0) }
            default: break
            }
        }
        let code = error as NSError
        return code.domain == NSCocoaErrorDomain && [CocoaError.fileWriteOutOfSpace.rawValue,CocoaError.fileWriteNoPermission.rawValue,CocoaError.fileWriteVolumeReadOnly.rawValue].contains(code.code)
    }

    // MARK: - 导出发布
    private enum ExportOutcome: Error { case skippedOutdated(WorkflowAssetKind) }

    private func asset(_ batchID: UUID, _ id: UUID, kind: WorkflowAssetKind) async throws -> WorkflowArtifact {
        let before = try task(batchID,id), value = try batch(batchID: batchID)
        let stage = kind.stage
        guard kind == .hd || kind == .png4k,
              let directory = value.exportDirectory(for: kind) else {
            throw WorkflowBridgeError.invalidImage("请先选择\(kind == .hd ? "堆栈原图" : "PNG4K")输出文件夹")
        }
        let request = before.requestedExports?[kind]
        if let request {
            guard request.snapshotVersion == before.snapshot?.contentVersion, request.directory == directory,
                  before[.geometry].confirmedVersion == request.snapshotVersion else { throw WorkflowStateError.staleVersion }
        }
        let roles: RoleImages
        if value.manualFinalization == true { roles = try await readCurrentRoles(batchID,before,stage: stage) }
        else {
            guard let cached = before.roleImages, cached.snapshotVersion == before.snapshot?.contentVersion else { throw WorkflowStateError.staleVersion }
            roles = cached
        }
        let source: String
        if kind == .hd { source = try Self.fingerprint([roles.snapshotVersion,try await services.contentFingerprint(roles)]) }
        else if value.manualFinalization == true {
            // 同一 PSD 升级选层规则后也必须更新成品，不能恢复旧 Keying_Level 的发布凭据。
            source = try Self.fingerprint([roles.snapshotVersion,"final-top-layer-v1",Self.encoded(before.snapshot?.finalRoles),Self.encoded(before.geometrySolution)])
        }
        else { source = try Self.fingerprint([roles.snapshotVersion,Self.encoded(before.geometrySolution)]) }
        let preset = try presetFingerprint(kind,batch: value,task: before)
        let specimen = value.specimens.first { $0.front.id == id || $0.back.id == id }!
        let url = directory.appendingPathComponent("\(specimen.baseName)_\(before.side.fileSuffix).\(kind == .hd ? "jpg" : "png")")
        try value.validateArtifactURL(url, kind: kind)
        let recipe = WorkflowArtifact(ownerTaskID: id,kind: kind,url: url,sourceFingerprint: source,presetFingerprint: preset,fileFingerprint: "",state: .pending)
        try check(batchID,before,stage: stage)
        if request?.policy != .overwrite, let existing = before.artifacts.last(where: { Self.sameRecipe($0,recipe) && $0.state == .completed }),
           let recovered = try services.recover(existing) {
            if value.manualFinalization == true { _ = try await readCurrentRoles(batchID,before,stage: stage) }
            try check(batchID,before,stage: stage)
            if request != nil { try mutateTask(batchID,id) { $0.exportNotes?[kind] = "当前版本已导出，已跳过" } }
            return recovered
        }
        // 先记录导出配方与发布意图，再写文件，以便 batch.json 未记录完成时恢复。
        if !before.artifacts.contains(where: { Self.sameRecipe($0,recipe) }) {
            try mutateTask(batchID,id) { $0.artifacts.append(recipe) }; try await persist(batchID)
        }
        let recovered = try services.recover(recipe)
        if request?.policy == .skipExisting, recovered == nil, FileManager.default.fileExists(atPath: url.path) {
            throw ExportOutcome.skippedOutdated(kind)
        }
        if let recovered, request?.policy != .overwrite {
            if request != nil { try mutateTask(batchID,id) { $0.exportNotes?[kind] = "当前版本已导出，已跳过" } }
            if value.manualFinalization == true { _ = try await readCurrentRoles(batchID,before,stage: stage) }
            try check(batchID,before,stage: stage)
            try recordArtifact(batchID,id,recovered); try await persist(batchID); return recovered
        }
        let temp = value.outputDirectory.appendingPathComponent(".work/\(id)/\(UUID())/output.\(kind == .hd ? "jpg" : "png")")
        try value.validateOutputURL(temp)
        try FileManager.default.createDirectory(at: temp.deletingLastPathComponent(),withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp.deletingLastPathComponent()) }
        do {
            try await services.render(kind,roles,before.squareLayout,nil,nil,temp)
            try Task.checkCancellation()
            try check(batchID,before,stage: stage)
            let current = try task(batchID,id), latest = try batch(batchID: batchID)
            guard try presetFingerprint(kind,batch: latest,task: current) == preset,
                  current.artifacts.contains(where: { Self.sameRecipe($0,recipe) }) else { throw WorkflowStateError.staleVersion }
            try latest.validateArtifactURL(url, kind: kind); try latest.validateOutputURL(temp)
            if value.manualFinalization == true {
                let verified = try await readCurrentRoles(batchID,before,stage: stage)
                guard verified == roles else { throw WorkflowStateError.staleVersion }
                try check(batchID,before,stage: stage)
            }
            // 版本校验与发布之间没有 await，避免 actor 重入后发布过时内容。
            let result: WorkflowArtifact
            do {
                if request?.policy == .skipExisting, let publish = services.publishSkippingExisting { result = try publish(temp,recipe) }
                else { result = try services.publish(temp,recipe) }
            } catch WorkflowArtifactError.existingOutputSkipped { throw ExportOutcome.skippedOutdated(kind) }
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

    // MARK: - 版本约束与持久化
    private func readCurrentRoles(_ batchID: UUID, _ before: WorkflowSideTask, stage: WorkflowStage) async throws -> RoleImages {
        guard let snapshot = before.snapshot, before.pendingFinalPSD == nil else { throw WorkflowStateError.invalidTransition }
        if let accepted = before.acceptedFinalPSD { try verifyAcceptedFiles(accepted, batchID: batchID) }
        let roles = try await services.extract(snapshot)
        try check(batchID,before,stage: stage)
        guard roles.snapshotVersion == snapshot.contentVersion else { throw WorkflowStateError.staleVersion }
        if let accepted = before.acceptedFinalPSD { try verifyAcceptedFiles(accepted, batchID: batchID) }
        try mutateTask(batchID,before.id) { $0.roleImages = roles }
        return roles
    }
    private func selectedSpecimens(_ batchID: UUID, sideIDs: Set<UUID>, stage: WorkflowStage) throws -> Set<UUID> {
        let value = try batch(batchID: batchID)
        let selected = value.specimens.filter { sideIDs.contains($0.front.id) || sideIDs.contains($0.back.id) }
        let tasks = selected.flatMap { [$0.front,$0.back] }
        guard !selected.isEmpty, selected.allSatisfy({ !$0.isExcluded }), Set(tasks.map(\.id)) == sideIDs,
              tasks.allSatisfy({ ($0[stage].state == .waitingReview || (value.manualFinalization == true && stage == .png4k && $0[stage].state == .failed) || ($0[stage].state == .completed && $0[stage].confirmedVersion == $0[stage].outputVersion)) && $0.snapshot != nil && $0.roleImages?.snapshotVersion == $0.snapshot?.contentVersion }) else {
            throw WorkflowStateError.invalidTransition
        }
        return Set(selected.map(\.id))
    }
    private func eligible(_ task: WorkflowSideTask, stage: WorkflowStage, batch: WorkflowBatch) -> Bool {
        if let kind = [WorkflowAssetKind.hd, .png4k].first(where: { $0.stage == stage }), task.requestedExports?[kind] != nil {
            return !batch.isPaused && task[.geometry].state == .completed
        }
        if batch.manualFinalization == true, [.hd,.png4k].contains(stage), task.fourKExportRequested != true { return false }
        if stage == .hd && task.exportHD != false && batch.exportDirectory(for: .hd) == nil { return false }
        if batch.manualFinalization == true && stage == .hd && task.fourKExportRequested != true { return false }
        guard !batch.isPaused, WorkflowStage.processingStages.prefix(while: { $0 != stage }).allSatisfy({
            (batch.manualFinalization == true && stage == .png4k && $0 == .hd && task.fourKExportRequested != true) || task[$0].state == .completed
        }) else { return false }
        if batch.manualFinalization != true {
            if stage != .stack, !batch.activeTasks.allSatisfy({ $0[.stack].state == .completed }) { return false }
            if stage != .stack && stage != .matte, !batch.activeTasks.allSatisfy({ $0[.matte].state == .completed }) { return false }
        }
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
    // 每次跨越异步服务后重检来源、阶段修订与快照，拒绝暂停、排除或编辑前启动的旧结果。
    private func check(_ batchID: UUID, _ before: WorkflowSideTask, stage: WorkflowStage, allowPaused: Bool = false) throws {
        let value = try batch(batchID: batchID), now = try task(batchID,before.id)
        guard (allowPaused || !value.isPaused), now.sourceRevision == before.sourceRevision, now.sources == before.sources,
              now[stage].revision == before[stage].revision, now.snapshot?.contentVersion == before.snapshot?.contentVersion,
              now.acceptedFinalPSD == before.acceptedFinalPSD,
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
        // 挂起前先排队，确保旧版保存不会晚于新版保存完成。
        let write = Task { if let previous { _ = try? await previous.value }; try await store.save(value,to: url) }
        saves[id] = write
        try await write.value
    }
    private func invalidateOutputs(_ batchID: UUID, _ id: UUID, from stage: WorkflowStage) throws {
        try mutateTask(batchID,id) { invalidateOutputs(&$0, from: stage) }
    }
    private func invalidateOutputs(_ task: inout WorkflowSideTask, from stage: WorkflowStage) {
        let stages = Array(WorkflowStage.allCases.drop(while: { $0 != stage }))
        for stage in stages {
            task[stage].state = .pending; task[stage].revision += 1; task[stage].inputVersion += 1
            task[stage].outputVersion = nil; task[stage].confirmedVersion = nil; task[stage].error = nil
        }
        for index in task.artifacts.indices where stages.contains(task.artifacts[index].kind.stage) { task.artifacts[index].state = .pending }
        if stages.contains(.png4k) { task.fourKExportRequested = nil }
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

// MARK: - 批量人工精修与按需最终验证
extension WorkflowExecutor {
    /// 先持久化打开基线，界面收到路径后才发起打开请求。
    func beginBatchEditing(batchID: UUID, taskIDs: Set<UUID>) async throws -> [URL] {
        try guardReviewOperation(batchID)
        let value = try batch(batchID: batchID)
        let selected = try reviewTasks(value, ids: taskIDs)
        let existing = batchReviewLeases[batchID]
        let session = existing ?? UUID()
        acquiringManual.insert(batchID); defer { acquiringManual.remove(batchID) }
        if existing == nil {
            try await coordinator.beginManualEditing(owner: session)
            batchReviewLeases[batchID] = session
        }
        do {
            var additions: [UUID: WorkflowManualEdit] = [:]
            for side in selected where side.manualEdit == nil {
                guard let url = side.snapshot?.workingURL else { throw WorkflowStateError.invalidTransition }
                try value.validateOutputURL(url)
                try verifyReviewOwnership(url, side.id)
                let baseline = try await Task.detached { try Self.reviewFileVersion(url) }.value
                try check(batchID, side, stage: .geometry, allowPaused: true)
                additions[side.id] = WorkflowManualEdit(sessionID: session, workingURL: url, baseline: baseline)
            }
            if !additions.isEmpty {
                try edit(batchID) { value in
                    for index in value.specimens.indices {
                        if let edit = additions[value.specimens[index].front.id] {
                            value.specimens[index].front.manualEdit = edit
                            value.specimens[index].front.manualEditError = nil
                        }
                        if let edit = additions[value.specimens[index].back.id] {
                            value.specimens[index].back.manualEdit = edit
                            value.specimens[index].back.manualEditError = nil
                        }
                    }
                }
                reviewNeedsSave.insert(batchID)
            }
            try await persistReview(batchID)
            return selected.compactMap { $0.snapshot?.workingURL }
        } catch {
            if existing == nil, (try? batch(batchID: batchID).manualReviewSessionID) == nil {
                batchReviewLeases.removeValue(forKey: batchID)
                await coordinator.endManualEditing(owner: session)
            }
            throw error
        }
    }

    /// 清单写入成功前，即使已移除最后一面的跟踪记录，租约仍然有效。
    func manualReviewLeaseID(batchID: UUID) -> UUID? { batchReviewLeases[batchID] }

    func pollManualEdits(batchID: UUID) async throws {
        guard !confirming.contains(batchID), !acquiringManual.contains(batchID) else { return }
        guard let session = batchReviewLeases[batchID] else { return }
        confirming.insert(batchID); defer { confirming.remove(batchID) }
        let sides = try batch(batchID: batchID).activeTasks.filter { $0.manualEdit != nil }
        if !sides.isEmpty {
            // 查询失败会完整保留上次记录和租约，不能当作所有文档关闭。
            let opened = try await observeDocuments(owner: session)
            for side in sides {
                try Task.checkCancellation()
                guard let record = side.manualEdit else { continue }
                if let document = opened[Self.reviewPath(record.workingURL)] {
                    if record.observedDocumentID != document.documentID || side.manualEditError != nil {
                        try mutateReviewTask(batchID, side.id) {
                            $0.manualEdit?.observedDocumentID = document.documentID
                            $0.manualEditError = nil
                        }
                    }
                } else if record.observedDocumentID != nil {
                    do {
                        try await acceptClosedSave(batchID, side, owner: session, requireChange: true)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        try recordManualSaveError(batchID, side.id, error)
                        // 已关闭的失败面保留诊断供重新确认，避免文件问题永久占住 Photoshop。
                        if !(error is ReviewObservationFailure), (error as? WorkflowBridgeError) != .manualReviewActive,
                           let latest = try? await observeDocuments(owner: session),
                           latest[Self.reviewPath(record.workingURL)] == nil {
                            try mutateReviewTask(batchID, side.id) { $0.manualEdit = nil }
                        }
                    }
                }
            }
        }
        try await persistReview(batchID)
        await releaseFinishedReview(batchID, session: session)
    }

    /// 打开失败或无法接收时，可明确结束已核实关闭的路径跟踪。
    func cancelClosedBatchEdits(batchID: UUID, taskIDs: Set<UUID>) async throws {
        try guardReviewOperation(batchID)
        guard let session = batchReviewLeases[batchID] else { return }
        confirming.insert(batchID); defer { confirming.remove(batchID) }
        let selected = try reviewTasks(batch(batchID: batchID), ids: taskIDs)
        let opened = try await observeDocumentsIfRunning(owner: session)
        for side in selected {
            guard let record = side.manualEdit, opened?[Self.reviewPath(record.workingURL)] == nil else {
                throw WorkflowBridgeError.manualReviewActive
            }
        }
        for side in selected { try mutateReviewTask(batchID, side.id) { $0.manualEdit = nil } }
        try await persistReview(batchID)
        await releaseFinishedReview(batchID, session: session)
    }

    /// 接受磁盘保存版本。不同面各自持久化成功结果和诊断。
    func confirmSavedTasks(batchID: UUID, taskIDs: Set<UUID>) async throws {
        try guardReviewOperation(batchID)
        let selected = try reviewTasks(batch(batchID: batchID), ids: taskIDs)
        confirming.insert(batchID)
        // 显式确认即使没有持久人工会话，也要保护核对到接收完成这段时间。
        acceptingSavedReview.insert(batchID)
        defer {
            acceptingSavedReview.remove(batchID)
            confirming.remove(batchID)
        }
        let existing = batchReviewLeases[batchID]
        let owner = existing ?? UUID()
        if existing == nil { try await coordinator.beginManualEditing(owner: owner) }
        do {
            let opened = try await observeDocumentsIfRunning(owner: owner)
            var firstError: Error?
            for side in selected {
                do {
                    try Task.checkCancellation()
                    guard let url = side.snapshot?.workingURL, opened?[Self.reviewPath(url)] == nil else {
                        throw WorkflowBridgeError.manualReviewActive
                    }
                    try await acceptClosedSave(batchID, side, owner: owner, requireChange: false)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    if firstError == nil { firstError = error }
                    try recordManualSaveError(batchID, side.id, error)
                }
            }
            try await persistReview(batchID)
            if let existing { await releaseFinishedReview(batchID, session: existing) }
            if let firstError { throw firstError }
        } catch {
            if existing == nil { await coordinator.endManualEditing(owner: owner) }
            throw error
        }
        if existing == nil { await coordinator.endManualEditing(owner: owner) }
    }

    func prepareFinalPSD(batchID: UUID, taskID: UUID) async throws {
        try guardReviewOperation(batchID)
        guard batchReviewLeases[batchID] == nil else { throw WorkflowBridgeError.manualReviewActive }
        let before = try task(batchID, taskID)
        guard before[.geometry].state == .completed, let version = before[.geometry].confirmedVersion else {
            throw WorkflowStateError.invalidTransition
        }
        preparingFinal.insert(batchID); defer { preparingFinal.remove(batchID) }
        try await prepareAcceptedPSD(batchID, before, expectedVersion: version)
    }

    /// 在切换或关闭批次前确认没有人工租约，并保存暂停状态。
    func prepareToCloseBatch(batchID: UUID) async throws {
        try guardReviewOperation(batchID)
        guard batchReviewLeases[batchID] == nil else { throw WorkflowBridgeError.manualReviewActive }
        acquiringManual.insert(batchID); defer { acquiringManual.remove(batchID) }
        let value = try batch(batchID: batchID)
        try reduce(batchID, .pause(expectedRevision: value.revision))
        try await persist(batchID)
    }

    private func guardReviewOperation(_ batchID: UUID) throws {
        guard !running.contains(batchID), !reprocessing.contains(batchID), !confirming.contains(batchID),
              !acquiringManual.contains(batchID), !preparingFinal.contains(batchID), manual[batchID] == nil else {
            throw WorkflowStateError.invalidTransition
        }
    }

    private func reviewTasks(_ batch: WorkflowBatch, ids: Set<UUID>) throws -> [WorkflowSideTask] {
        let selected = batch.activeTasks.filter { ids.contains($0.id) }
        guard batch.manualFinalization == true, !ids.isEmpty, selected.count == ids.count,
              selected.allSatisfy({ $0.snapshot?.taskID == $0.id && $0[.stack].state == .completed &&
                  $0[.matte].state == .completed && [.waitingReview, .completed].contains($0[.geometry].state) &&
                  $0.geometryApplySourceVersion == nil && $0.manualAdoptionRequired != true }) else {
            throw WorkflowStateError.invalidTransition
        }
        return selected
    }

    private func releaseFinishedReview(_ batchID: UUID, session: UUID) async {
        guard (try? batch(batchID: batchID).manualReviewSessionID) == nil, batchReviewLeases[batchID] == session else { return }
        // 保留执行器内的租约标记直到协调器释放，避免排队的自动操作先行。
        await coordinator.endManualEditing(owner: session)
        batchReviewLeases.removeValue(forKey: batchID)
    }

    private func observeDocuments(owner: UUID) async throws -> [String: WorkflowOpenPhotoshopDocument] {
        guard let observe = services.openDocuments else { throw WorkflowStateError.invalidTransition }
        let documents = try await coordinator.readSaved(owner: owner, operation: observe)
        var opened: [String: WorkflowOpenPhotoshopDocument] = [:]
        for document in documents {
            let path = Self.reviewPath(document.url)
            guard document.url.isFileURL, document.documentID > 0, opened[path] == nil else {
                throw WorkflowBridgeError.photoshop("打开文档列表不完整")
            }
            opened[path] = document
        }
        return opened
    }

    // 只有显式操作可把已核实的进程不存在作为关闭凭据，自动轮询仍会报错。
    private func observeDocumentsIfRunning(owner: UUID) async throws -> [String: WorkflowOpenPhotoshopDocument]? {
        do { return try await observeDocuments(owner: owner) }
        catch WorkflowBridgeError.photoshopNotRunning { return nil }
    }

    private func mutateReviewTask(_ batchID: UUID, _ id: UUID, _ body: (inout WorkflowSideTask) throws -> Void) throws {
        try mutateTask(batchID, id, body)
        reviewNeedsSave.insert(batchID)
    }

    private func persistReview(_ batchID: UUID) async throws {
        guard reviewNeedsSave.contains(batchID) else { return }
        try await persist(batchID)
        reviewNeedsSave.remove(batchID)
    }

    private func recordManualSaveError(_ batchID: UUID, _ id: UUID, _ error: Error) throws {
        let message = error.localizedDescription
        guard try task(batchID, id).manualEditError != message else { return }
        try mutateReviewTask(batchID, id) { $0.manualEditError = message }
    }

    private func verifyReviewOwnership(_ url: URL, _ id: UUID) throws {
        guard let verify = services.verifyManualSaveOwnership else { throw WorkflowStateError.invalidTransition }
        try verify(url, id)
    }

    private nonisolated static func reviewPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private nonisolated static func reviewFileVersion(_ url: URL) throws -> WorkflowPSDFileVersion {
        func modificationDate() throws -> Date {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular, let date = attributes[.modificationDate] as? Date else {
                throw WorkflowBridgeError.staleSource
            }
            return date
        }
        let modified = try modificationDate()
        let hash = try AIFileValidation.hash(url.path)
        guard try modificationDate() == modified else { throw WorkflowBridgeError.staleSource }
        return WorkflowPSDFileVersion(hash: hash, modificationDate: modified)
    }

    private struct ReviewObservationFailure: LocalizedError {
        let underlying: Error
        var errorDescription: String? { underlying.localizedDescription }
    }

    private func acceptClosedSave(_ batchID: UUID, _ before: WorkflowSideTask, owner: UUID, requireChange: Bool) async throws {
        guard let url = before.snapshot?.workingURL else { throw WorkflowStateError.invalidTransition }
        let value = try batch(batchID: batchID)
        try value.validateOutputURL(url)
        try verifyReviewOwnership(url, before.id)
        let version = try await Task.detached { try Self.reviewFileVersion(url) }.value
        let changed = before.manualEdit?.baseline != version
        let copy = value.acceptedFinalURL(taskID: before.id, contentVersion: version.hash)
        if changed || !requireChange {
            let taskID = before.id
            try await Task.detached {
                try value.validateAcceptedFinalURL(copy, taskID: taskID, contentVersion: version.hash)
                try Self.copyReviewVersion(url, to: copy, version: version)
            }.value
        }
        let opened: [String: WorkflowOpenPhotoshopDocument]?
        if requireChange {
            do { opened = try await observeDocuments(owner: owner) }
            catch is CancellationError { throw CancellationError() }
            catch { throw ReviewObservationFailure(underlying: error) }
        } else {
            opened = try await observeDocumentsIfRunning(owner: owner)
        }
        guard opened?[Self.reviewPath(url)] == nil else { throw WorkflowBridgeError.manualReviewActive }
        try check(batchID, before, stage: .geometry, allowPaused: true)
        let current = try task(batchID, before.id)
        guard current.snapshot?.workingURL == url, current.manualEdit == before.manualEdit,
              current.manualEdit == nil || current.manualEdit?.sessionID == owner else { throw WorkflowStateError.staleVersion }
        try value.validateOutputURL(url)
        try verifyReviewOwnership(url, before.id)
        guard try Self.reviewFileVersion(url) == version else { throw WorkflowBridgeError.staleSource }
        try Task.checkCancellation()
        if requireChange && !changed {
            try mutateReviewTask(batchID, before.id) { $0.manualEdit = nil; $0.manualEditError = nil }
            return
        }
        let receipt = WorkflowAcceptedFinalPSD(taskID: before.id, sourceRevision: before.sourceRevision,
            workingURL: url, snapshotURL: copy, contentVersion: version.hash)
        try value.validateAcceptedFinalURL(copy, taskID: before.id, contentVersion: version.hash)
        guard try Self.reviewFileVersion(copy).hash == version.hash else { throw WorkflowBridgeError.staleSource }
        try mutateReviewTask(batchID, before.id) { side in
            side.manualEdit = nil; side.manualEditError = nil
            if side[.geometry].confirmedVersion == version.hash &&
                (side.acceptedFinalPSD == receipt || side.pendingFinalPSD == nil && side.snapshot?.finalRoles?.isValid == true) {
                return
            }
            let changedVersion = side.finalPSDVersion != version.hash
            side.acceptedFinalPSD = receipt; side.finalPreparationError = nil; side.roleImages = nil
            side[.geometry].state = .completed; side[.geometry].outputVersion = version.hash
            side[.geometry].confirmedVersion = version.hash; side[.geometry].error = nil; side[.geometry].revision += 1
            if changedVersion {
                side.geometrySolution = nil; side.geometryRevalidationRequired = false; side.lastPSDChange = nil
                side.squareLayout = .png4k
                for stage in [WorkflowStage.hd, .png4k] {
                    side[stage].state = .pending; side[stage].outputVersion = nil; side[stage].confirmedVersion = nil
                    side[stage].error = nil; side[stage].revision += 1
                }
                for i in side.artifacts.indices { side.artifacts[i].state = .pending }
                side.fourKExportRequested = nil; side.exportHD = nil; side.requestedExports = nil
                side.exportNotes = Dictionary(side.artifacts.map { ($0.kind, "PSD 已更新，待重新导出") },
                                              uniquingKeysWith: { _, latest in latest })
            }
        }
    }

    private nonisolated static func copyReviewVersion(_ url: URL, to copy: URL, version: WorkflowPSDFileVersion) throws {
        let files = FileManager.default, directory = copy.deletingLastPathComponent()
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        if files.fileExists(atPath: copy.path) {
            guard try reviewFileVersion(copy).hash == version.hash,
                  try reviewFileVersion(url) == version else { throw WorkflowBridgeError.staleSource }
        } else {
            let staging = directory.appendingPathComponent("\(UUID()).psd")
            defer { try? files.removeItem(at: staging) }
            try files.copyItem(at: url, to: staging)
            guard try reviewFileVersion(staging).hash == version.hash,
                  try reviewFileVersion(url) == version else { throw WorkflowBridgeError.staleSource }
            try files.setAttributes([.posixPermissions: 0o444], ofItemAtPath: staging.path)
            try files.moveItem(at: staging, to: copy)
        }
    }

    private func verifyAcceptedFiles(_ accepted: WorkflowAcceptedFinalPSD, batchID: UUID) throws {
        let batch = try batch(batchID: batchID)
        try batch.validateOutputURL(accepted.workingURL)
        try batch.validateAcceptedFinalURL(accepted.snapshotURL, taskID: accepted.taskID, contentVersion: accepted.contentVersion)
        try verifyReviewOwnership(accepted.workingURL, accepted.taskID)
        guard try Self.reviewFileVersion(accepted.snapshotURL).hash == accepted.contentVersion,
              try Self.reviewFileVersion(accepted.workingURL).hash == accepted.contentVersion else {
            throw WorkflowBridgeError.staleSource
        }
    }

    private func prepareAcceptedPSD(_ batchID: UUID, _ before: WorkflowSideTask, expectedVersion: String) async throws {
        guard before[.geometry].confirmedVersion == expectedVersion, before.finalPSDVersion == expectedVersion else {
            throw WorkflowStateError.staleVersion
        }
        guard let accepted = before.acceptedFinalPSD else { return }
        do {
            try verifyAcceptedFiles(accepted, batchID: batchID)
            guard before.pendingFinalPSD != nil else {
                if before.finalPreparationError != nil {
                    try mutateTask(batchID, before.id) { $0.finalPreparationError = nil }
                    try await persist(batchID)
                }
                return
            }
            guard let prepare = services.prepareAcceptedFinalPSD else { throw WorkflowStateError.invalidTransition }
            let (snapshot, roles) = try await prepare(accepted)
            try check(batchID, before, stage: .geometry, allowPaused: true)
            guard snapshot.taskID == accepted.taskID, snapshot.workingURL == accepted.workingURL,
                  snapshot.snapshotURL == accepted.snapshotURL, snapshot.contentVersion == expectedVersion,
                  snapshot.finalRoles?.isValid == true, snapshot.pixelSize.width > 0, snapshot.pixelSize.height > 0,
                  roles.isFinalized == true, roles.snapshotVersion == expectedVersion else {
                throw WorkflowBridgeError.invalidStructure
            }
            try verifyAcceptedFiles(accepted, batchID: batchID)
            try Task.checkCancellation()
            try mutateTask(batchID, before.id) {
                $0.snapshot = snapshot; $0.roleImages = roles; $0.finalPreparationError = nil
            }
            try await persist(batchID)
        } catch is CancellationError { throw CancellationError() }
        catch {
            if (try? task(batchID, before.id).acceptedFinalPSD) == accepted {
                try mutateTask(batchID, before.id) { $0.finalPreparationError = error.localizedDescription }
                try await persist(batchID)
            }
            throw error
        }
    }

    private func checkExportPreparation(_ batchID: UUID, _ before: WorkflowSideTask, stage: WorkflowStage) throws {
        let current = try task(batchID, before.id), value = try batch(batchID: batchID)
        guard !value.isPaused, current[stage] == before[stage], current.sourceRevision == before.sourceRevision,
              current.acceptedFinalPSD == before.acceptedFinalPSD, current.finalPSDVersion == before.finalPSDVersion,
              current.requestedExports == before.requestedExports,
              value.activeTasks.contains(where: { $0.id == before.id }) else { throw WorkflowStateError.staleVersion }
    }
}
