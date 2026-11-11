// 集中处理工作流事件、版本校验、检查点和下游失效规则，在批次副本上校验并维护状态一致性。

import Foundation

// MARK: - 事件与状态错误
nonisolated enum WorkflowStateError: Error, Equatable {
    case staleVersion
    case unknownTask
    case invalidTransition
    case invalidManifest(String)
}

nonisolated enum WorkflowPresetScope: Equatable, Sendable {
    case geometry, png4k
}

nonisolated enum WorkflowEvent: Sendable {
    case stageStarted(taskID: UUID, stage: WorkflowStage, expectedVersion: Int)
    case stageCompleted(taskID: UUID, stage: WorkflowStage, expectedVersion: Int, outputVersion: String)
    case stageFailed(taskID: UUID, stage: WorkflowStage, expectedVersion: Int, reason: String)
    case excludeSpecimens(ids: Set<UUID>, reason: String, expectedRevision: Int)
    case sourceChanged(taskID: UUID, sources: WorkflowSources, expectedVersion: Int)
    case presetChanged(scope: WorkflowPresetScope, preset: WorkflowPreset, expectedRevision: Int)
    case pause(expectedRevision: Int)
    case cancelRunning(expectedRevision: Int)
    case resume(expectedRevision: Int)
}

// MARK: - 原子状态转换
// 仅修改批次副本，完整校验通过后才返回新状态；不写入文件或调用处理服务，但清单校验会读取路径信息。
nonisolated enum WorkflowStateMachine {
    static func reduce(batch: WorkflowBatch, event: WorkflowEvent) throws -> WorkflowBatch {
        try batch.validate()
        var next = batch
        switch event {
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
                    task.manualEdit = nil; task.manualEditError = nil
                    task.acceptedFinalPSD = nil; task.finalPreparationError = nil
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
        case let .presetChanged(scope, preset, expected):
            try check(batch.revision, expected)
            guard preset.version > 0, !preset.fingerprint.isEmpty else { throw WorkflowStateError.invalidTransition }
            let stage: WorkflowStage
            switch scope {
            case .geometry:
                guard preset.version > batch.presets.geometry.version else { throw WorkflowStateError.staleVersion }
                next.presets.geometry = preset; stage = .geometry
            case .png4k:
                guard preset.version > batch.presets.png4k.version else { throw WorkflowStateError.staleVersion }
                next.presets.png4k = preset; stage = .png4k
            }
            for id in batch.activeTasks.map(\.id) {
                try updateTask(&next, id: id) { invalidate(&$0, from: stage) }
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
        next.revision += 1
        try next.validate()
        return next
    }

    // MARK: - 阶段屏障与下游失效
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
        if let kind = [WorkflowAssetKind.hd, .png4k].first(where: { $0.stage == stage }), task.requestedExports?[kind] != nil {
            return task[.geometry].state == .completed
        }
        guard ![WorkflowStage.hd, .png4k, .derivatives].contains(stage) else { return false }
        return WorkflowStage.allCases.prefix { $0 != stage }.allSatisfy { task[$0].state == .completed }
    }

    private static func invalidate(_ task: inout WorkflowSideTask, from stage: WorkflowStage) {
        let stages = Array(WorkflowStage.allCases.drop { $0 != stage })
        // 同时清除输出确认并递增修订，让正在执行的旧任务无法回写已失效阶段。
        for invalidStage in stages {
            task[invalidStage].state = .pending
            task[invalidStage].inputVersion += 1
            task[invalidStage].revision += 1
            task[invalidStage].outputVersion = nil
            task[invalidStage].confirmedVersion = nil
            task[invalidStage].error = nil
        }
        for index in task.artifacts.indices where stages.contains(task.artifacts[index].kind.stage) {
            task.artifacts[index].state = .pending
        }
        if stage == .stack {
            task.stackAttemptURL = nil
            task.snapshot = nil; task.roleImages = nil
        }
        if stages.contains(.geometry) {
            task.geometryApplySourceVersion = nil
            task.acceptedFinalPSD = nil; task.finalPreparationError = nil; task.manualEditError = nil; task.intermediatesCleared = false
        }
        for kind in [WorkflowAssetKind.hd, .png4k] where stages.contains(kind.stage) {
            task.requestedExports?.removeValue(forKey: kind)
            if task.artifacts.contains(where: { $0.kind == kind }) {
                if task.exportNotes == nil { task.exportNotes = [:] }
                task.exportNotes?[kind] = "结果已变化，待重新导出"
            }
        }
        if stages.contains(.geometry) {
            task.geometrySolution = nil
        }
    }
}
