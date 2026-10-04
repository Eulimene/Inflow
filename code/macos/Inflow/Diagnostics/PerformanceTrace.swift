import Foundation
import os

/// Opt-in, payload-free timings. No file I/O or source traversal when disabled.
/// Enable with INFLOW_PERFORMANCE_TRACE=1 or -InflowPerformanceTracing YES.
enum PerformanceTrace {
    static let enabled = ProcessInfo.processInfo.environment["INFLOW_PERFORMANCE_TRACE"] == "1"
        || UserDefaults.standard.bool(forKey: "InflowPerformanceTracing")
    private static let logger = Logger(subsystem: "com.inflow.desktop", category: "Performance")
    private static let log = OSLog(subsystem: "com.inflow.desktop", category: "Performance")
    @TaskLocal static var parentID: String?

    struct Span {
        let id = UUID().uuidString
        let parent: String
        let stage: String
        let bytes: Int
        let start = DispatchTime.now().uptimeNanoseconds
        let mainThread = Thread.isMainThread
        let signpost = OSSignpostID(log: PerformanceTrace.log)

        func end(_ outcome: String = "completed") {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            os_signpost(.end, log: PerformanceTrace.log, name: "DocumentPipeline", signpostID: signpost,
                        "%{public}s", stage)
            PerformanceTrace.logger.info("perf stage=\(stage, privacy: .public) span=\(id, privacy: .public) parent=\(parent, privacy: .public) duration_ms=\(ms, privacy: .public) bytes=\(bytes, privacy: .public) start_main=\(mainThread, privacy: .public) outcome=\(outcome, privacy: .public)")
        }
    }

    static func begin(_ stage: String, bytes: @autoclosure () -> Int = 0) -> Span? {
        guard enabled else { return nil }
        let span = Span(parent: parentID ?? "root", stage: stage, bytes: bytes())
        os_signpost(.begin, log: log, name: "DocumentPipeline", signpostID: span.signpost,
                    "%{public}s", stage)
        logger.debug("perf begin stage=\(stage, privacy: .public) span=\(span.id, privacy: .public) parent=\(span.parent, privacy: .public)")
        return span
    }

    static func measure<T>(_ stage: String, bytes: @autoclosure () -> Int = 0,
                           _ operation: () throws -> T) rethrows -> T {
        guard let span = begin(stage, bytes: bytes()) else { return try operation() }
        return try $parentID.withValue(span.id) {
            do {
                let value = try operation()
                span.end()
                return value
            } catch { span.end("failed"); throw error }
        }
    }
    static func measureAsync<T>(_ stage: String, bytes: @autoclosure () -> Int = 0,
                                isolation: isolated (any Actor)? = #isolation,
                                _ operation: () async throws -> T) async rethrows -> T {
        guard let span = begin(stage, bytes: bytes()) else { return try await operation() }
        return try await $parentID.withValue(span.id) {
            do {
                let value = try await operation()
                span.end(Task.isCancelled ? "cancelled" : "completed")
                return value
            } catch { span.end(error is CancellationError ? "cancelled" : "failed"); throw error }
        }
    }

}
