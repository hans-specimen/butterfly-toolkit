import Foundation

nonisolated enum WorkflowStateError: Error, Equatable {
    case staleVersion
    case unknownTask
    case invalidTransition
    case invalidManifest(String)
}

nonisolated enum WorkflowPresetScope: Equatable, Sendable {
    case geometry, png4k, derivative(WorkflowAssetKind)
}

nonisolated enum WorkflowEvent: Sendable {
    case mattePreparationStored(taskID: UUID, expectedVersion: Int)
    case stageStarted(taskID: UUID, stage: WorkflowStage, expectedVersion: Int)
    case stageCompleted(taskID: UUID, stage: WorkflowStage, expectedVersion: Int, outputVersion: String)
    case stageFailed(taskID: UUID, stage: WorkflowStage, expectedVersion: Int, reason: String)
    case continueBatch(stage: WorkflowStage, expectedRevision: Int)
    case confirmSelected(specimenIDs: Set<UUID>, stage: WorkflowStage, outputVersions: [UUID: String], expectedRevision: Int)
    case excludeSpecimens(ids: Set<UUID>, reason: String, expectedRevision: Int)
    case sourceChanged(taskID: UUID, sources: WorkflowSources, expectedVersion: Int)
    case savedPSDChanged(taskID: UUID, snapshot: PSDSnapshot, change: WorkflowPSDChange,
                         expectedSourceVersion: Int, expectedSnapshotVersion: String?)
    case presetChanged(scope: WorkflowPresetScope, preset: WorkflowPreset, expectedRevision: Int)
    case pause(expectedRevision: Int)
    case cancelRunning(expectedRevision: Int)
    case resume(expectedRevision: Int)
}

nonisolated enum WorkflowStateMachine {
    static func reduce(batch: WorkflowBatch, event: WorkflowEvent) throws -> WorkflowBatch {
        try batch.validate()
        var next = batch
        switch event {
        case let .mattePreparationStored(id, expected):
            guard !batch.isPaused else { throw WorkflowStateError.invalidTransition }
            try updateTask(&next, id: id) { task in
                try check(task[.matte].revision, expected)
                guard task[.matte].state == .running, let snapshot = task.snapshot,
                      snapshot.taskID == id, !snapshot.contentVersion.isEmpty,
                      snapshot.pixelSize.width > 0, snapshot.pixelSize.height > 0 else { throw WorkflowStateError.invalidTransition }
                // Installed PSD recovery does not require already-cleaned input files.
                if snapshot.roles?.isValid != true {
                    guard let input = task.stackPNG, input.snapshotVersion == snapshot.contentVersion,
                          input.pixelSize == snapshot.pixelSize, input.orientation == 1,
                          !input.fingerprint.isEmpty, !input.colorProfile.isEmpty else { throw WorkflowStateError.invalidTransition }
                }
                task[.matte].state = .pending; task[.matte].revision += 1
                task[.matte].error = nil; task[.matte].outputVersion = nil; task[.matte].confirmedVersion = nil
            }
        case let .stageStarted(id, stage, expected):
            guard !batch.isPaused else { throw WorkflowStateError.invalidTransition }
            try updateTask(&next, id: id) { task in
                try check(task[stage].revision, expected)
                guard task[stage].state == .pending || task[stage].state == .failed,
                      canStart(stage, task: task, batch: batch) else { throw WorkflowStateError.invalidTransition }
                task[stage].state = .running
                task[stage].revision += 1
                task[stage].error = nil
            }
        case let .stageCompleted(id, stage, expected, output):
            guard !output.isEmpty else { throw WorkflowStateError.invalidTransition }
            try updateTask(&next, id: id) { task in
                try check(task[stage].revision, expected)
                guard task[stage].state == .running else { throw WorkflowStateError.invalidTransition }
                task[stage].state = (stage == .geometry || stage == .png4k) ? .waitingReview : .completed
                task[stage].outputVersion = output
                task[stage].confirmedVersion = nil
                task[stage].revision += 1
                task[stage].error = nil
                if stage == .geometry { task.geometryRevalidationRequired = false }
            }
        case let .stageFailed(id, stage, expected, reason):
            guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WorkflowStateError.invalidTransition }
            try updateTask(&next, id: id) { task in
                try check(task[stage].revision, expected)
                guard task[stage].state == .running else { throw WorkflowStateError.invalidTransition }
                task[stage].state = .failed
                task[stage].revision += 1
                task[stage].error = reason
            }
        case let .continueBatch(stage, expected):
            try check(batch.revision, expected)
            guard stage == .stack || stage == .matte, !batch.activeTasks.isEmpty,
                  batch.activeTasks.allSatisfy({ $0[stage].state == .waitingReview }) else { throw WorkflowStateError.invalidTransition }
            for id in batch.activeTasks.map(\.id) {
                try updateTask(&next, id: id) { task in
                    task[stage].state = .completed
                    task[stage].confirmedVersion = task[stage].outputVersion
                    task[stage].revision += 1
                }
            }
        case let .confirmSelected(ids, stage, versions, expected):
            try check(batch.revision, expected)
            guard stage == .geometry || stage == .png4k, !ids.isEmpty,
                  ids.isSubset(of: Set(batch.specimens.filter { !$0.isExcluded }.map(\.id))) else { throw WorkflowStateError.invalidTransition }
            let tasks = batch.specimens.filter { ids.contains($0.id) }.flatMap { [$0.front, $0.back] }
            guard Set(versions.keys) == Set(tasks.map(\.id)) else { throw WorkflowStateError.invalidTransition }
            for task in tasks {
                let ready = task[stage].state == .waitingReview ||
                    (task[stage].state == .completed && task[stage].confirmedVersion == task[stage].outputVersion)
                guard ready, versions[task.id] == task[stage].outputVersion else {
                    throw WorkflowStateError.staleVersion
                }
            }
            for id in tasks.map(\.id) {
                try updateTask(&next, id: id) { task in
                    task[stage].state = .completed
                    task[stage].confirmedVersion = task[stage].outputVersion
                    task[stage].revision += 1
                }
            }
        case let .excludeSpecimens(ids, reason, expected):
            try check(batch.revision, expected)
            guard !ids.isEmpty, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ids.isSubset(of: Set(batch.specimens.map(\.id))) else { throw WorkflowStateError.invalidTransition }
            for index in next.specimens.indices where ids.contains(next.specimens[index].id) {
                next.specimens[index].exclusionReason = reason
                for side in WorkflowSide.allCases {
                    var task = side == .front ? next.specimens[index].front : next.specimens[index].back
                    for stage in WorkflowStage.allCases {
                        task[stage].state = .excluded
                        task[stage].exclusionReason = reason
                        task[stage].revision += 1
                    }
                    for artifact in task.artifacts.indices { task.artifacts[artifact].state = .excluded }
                    if side == .front { next.specimens[index].front = task } else { next.specimens[index].back = task }
                }
            }
        case let .sourceChanged(id, sources, expected):
            try updateTask(&next, id: id) { task in
                try check(task.sourceRevision, expected)
                task.sources = sources
                task.sourceRevision += 1
                invalidate(&task, from: .stack)
            }
        case let .savedPSDChanged(id, snapshot, change, expectedSource, expectedSnapshot):
            try updateTask(&next, id: id) { task in
                try check(task.sourceRevision, expectedSource)
                guard task.snapshot?.contentVersion == expectedSnapshot else { throw WorkflowStateError.staleVersion }
                guard snapshot.taskID == id, !snapshot.contentVersion.isEmpty,
                      snapshot.contentVersion != expectedSnapshot,
                      snapshot.workingURL.isFileURL, snapshot.snapshotURL.isFileURL,
                      snapshot.workingURL != snapshot.snapshotURL,
                      snapshot.pixelSize.width > 0, snapshot.pixelSize.height > 0,
                      task[.stack].state == .completed || task[.stack].state == .waitingReview else {
                    throw WorkflowStateError.invalidTransition
                }
                let savedGeometry = task.geometrySolution
                task.snapshot = snapshot
                task.roleImages = nil
                task.lastPSDChange = change
                switch change {
                case .stackContent:
                    invalidate(&task, from: .matte)
                    task.stackPNG = nil
                    task.matteArtifact = nil
                    task[.stack].outputVersion = snapshot.contentVersion
                    task[.stack].confirmedVersion = nil
                    task[.stack].revision += 1
                case .maskOnly:
                    invalidate(&task, from: .geometry)
                    task.geometrySolution = savedGeometry
                    task.geometryRevalidationRequired = true
                case .geometry:
                    invalidate(&task, from: .geometry)
                }
            }
        case let .presetChanged(scope, preset, expected):
            try check(batch.revision, expected)
            guard preset.version > 0, !preset.fingerprint.isEmpty else { throw WorkflowStateError.invalidTransition }
            let stage: WorkflowStage
            var onlyAsset: WorkflowAssetKind?
            switch scope {
            case .geometry:
                guard preset.version > batch.presets.geometry.version else { throw WorkflowStateError.staleVersion }
                next.presets.geometry = preset; stage = .geometry
            case .png4k:
                guard preset.version > batch.presets.png4k.version else { throw WorkflowStateError.staleVersion }
                next.presets.png4k = preset; stage = .png4k
            case let .derivative(kind):
                switch kind {
                case .xianyu:
                    guard preset.version > batch.presets.xianyu.version else { throw WorkflowStateError.staleVersion }
                    next.presets.xianyu = preset
                case .white1k:
                    guard preset.version > batch.presets.white1k.version else { throw WorkflowStateError.staleVersion }
                    next.presets.white1k = preset
                case .footage:
                    guard preset.version > batch.presets.footage.version else { throw WorkflowStateError.staleVersion }
                    next.presets.footage = preset
                default: throw WorkflowStateError.invalidTransition
                }
                stage = .derivatives; onlyAsset = kind
            }
            for id in batch.activeTasks.map(\.id) {
                try updateTask(&next, id: id) { invalidate(&$0, from: stage, onlyAsset: onlyAsset) }
            }
        case let .pause(expected):
            try check(batch.revision, expected)
            next.isPaused = true
        case let .cancelRunning(expected):
            try check(batch.revision, expected)
            next.isPaused = true
            for id in batch.activeTasks.map(\.id) {
                try updateTask(&next, id: id) { task in
                    for stage in WorkflowStage.allCases where task[stage].state == .running {
                        task[stage].state = .pending
                        task[stage].revision += 1
                    }
                }
            }
        case let .resume(expected):
            try check(batch.revision, expected)
            next.isPaused = false
        }
        establishBatchReviews(&next)
        next.revision += 1
        try next.validate()
        return next
    }

    private static func check(_ actual: Int, _ expected: Int) throws {
        guard actual == expected else { throw WorkflowStateError.staleVersion }
    }

    private static func updateTask(_ batch: inout WorkflowBatch, id: UUID, _ update: (inout WorkflowSideTask) throws -> Void) throws {
        guard let index = batch.specimens.firstIndex(where: { $0.front.id == id || $0.back.id == id }),
              !batch.specimens[index].isExcluded else { throw WorkflowStateError.unknownTask }
        if batch.specimens[index].front.id == id { try update(&batch.specimens[index].front) }
        else { try update(&batch.specimens[index].back) }
    }

    private static func canStart(_ stage: WorkflowStage, task: WorkflowSideTask, batch: WorkflowBatch) -> Bool {
        let earlier = WorkflowStage.allCases.prefix { $0 != stage }
        guard earlier.allSatisfy({ task[$0].state == .completed }) else { return false }
        // Neither side can enter matte/geometry before the whole batch has crossed both early barriers.
        if stage != .stack && !batch.activeTasks.allSatisfy({ $0[.stack].state == .completed }) { return false }
        if stage != .stack && stage != .matte && !batch.activeTasks.allSatisfy({ $0[.matte].state == .completed }) { return false }
        return true
    }

    private static func establishBatchReviews(_ batch: inout WorkflowBatch) {
        for stage in [WorkflowStage.stack, .matte] {
            let enabled = stage == .stack ? batch.checkAfterStack : batch.checkAfterMatte
            guard enabled, !batch.activeTasks.isEmpty,
                  batch.activeTasks.allSatisfy({ $0[stage].state == .completed || $0[stage].state == .waitingReview }),
                  batch.activeTasks.contains(where: { $0[stage].state == .completed }),
                  batch.activeTasks.contains(where: { $0[stage].state == .waitingReview || $0[stage].confirmedVersion == nil }) else { continue }
            for index in batch.specimens.indices where !batch.specimens[index].isExcluded {
                batch.specimens[index].front[stage].state = .waitingReview
                batch.specimens[index].front[stage].revision += 1
                batch.specimens[index].back[stage].state = .waitingReview
                batch.specimens[index].back[stage].revision += 1
            }
        }
    }

    private static func invalidate(_ task: inout WorkflowSideTask, from stage: WorkflowStage, onlyAsset: WorkflowAssetKind? = nil) {
        let stages = Array(WorkflowStage.allCases.drop { $0 != stage })
        for invalidStage in stages {
            task[invalidStage].state = .pending
            task[invalidStage].inputVersion += 1
            task[invalidStage].revision += 1
            task[invalidStage].outputVersion = nil
            task[invalidStage].confirmedVersion = nil
            task[invalidStage].error = nil
        }
        for index in task.artifacts.indices where stages.contains(task.artifacts[index].kind.stage) &&
            (onlyAsset == nil || task.artifacts[index].kind == onlyAsset) {
            task.artifacts[index].state = .pending
        }
        if stage == .stack {
            task.stackAttemptURL = nil
            task.snapshot = nil; task.stackPNG = nil; task.matteArtifact = nil; task.roleImages = nil
        }
        if stages.contains(.geometry) { task.exportHD = nil; task.geometryApplySourceVersion = nil }
        if stages.contains(.png4k) { task.fourKExportRequested = nil }
        if stages.contains(.geometry) {
            task.geometrySolution = nil
            task.geometryRevalidationRequired = false
        }
    }
}
