import Foundation
import os

/// Instruments の「Points of Interest」と Xcode コンソールから重い処理を追跡する。
/// Points of Interest は全ビルドで収集可能。コンソール出力はDebugだけに限定する。
public enum PerformanceOperation: String, Sendable {
    case projectHydration = "project.hydration"
    case mosaicPreviewRender = "mosaic.preview.render"
    case photoCacheLoad = "photos.cache.load"
    case photoLibraryScan = "photos.library.scan"
    case candidateIndexBuild = "candidates.index.build"
    case candidateSearch = "candidates.search"
    case initialMatching = "mosaic.initial.matching"
    case initialCandidateGraph = "mosaic.initial.candidateGraph"
    case initialAssignment = "mosaic.initial.assignment"
    case initialSwapOptimization = "mosaic.initial.swapOptimization"
    case timelapseExport = "timelapse.export"
}

public struct PerformanceInterval: @unchecked Sendable {
    fileprivate let operation: PerformanceOperation
    fileprivate let signpostID: OSSignpostID
    fileprivate let startedAtNanoseconds: UInt64
}

public enum PerformanceDiagnostics {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.daredemosaic.app"
    // Instruments の Points of Interest が収集する専用カテゴリを使用する。
    private static let signpostLog = OSLog(subsystem: subsystem, category: .pointsOfInterest)
    private static let logger = Logger(subsystem: subsystem, category: "Performance")
    public static func begin(
        _ operation: PerformanceOperation,
        metadata: String = ""
    ) -> PerformanceInterval? {
        let signpostID = OSSignpostID(log: signpostLog)
        os_signpost(
            .begin,
            log: signpostLog,
            name: "PerformanceInterval",
            signpostID: signpostID,
            "%{public}@ | %{public}@",
            operation.rawValue as NSString,
            metadata as NSString
        )
        return PerformanceInterval(
            operation: operation,
            signpostID: signpostID,
            startedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
    }

    public static func end(
        _ interval: PerformanceInterval?,
        metadata: String = ""
    ) {
        guard let interval else { return }
        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - interval.startedAtNanoseconds
        let elapsedMilliseconds = Double(elapsedNanoseconds) / 1_000_000
        os_signpost(
            .end,
            log: signpostLog,
            name: "PerformanceInterval",
            signpostID: interval.signpostID,
            "%{public}@ | %{public}@ | %.2f ms",
            interval.operation.rawValue as NSString,
            metadata as NSString,
            elapsedMilliseconds
        )
        #if DEBUG
            logger.info(
                "[PERF] \(interval.operation.rawValue, privacy: .public) \(elapsedMilliseconds, format: .fixed(precision: 2)) ms | \(metadata, privacy: .public)"
            )
        #endif
    }
}
