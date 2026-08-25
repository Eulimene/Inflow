import Combine
import Foundation

enum AnonymousUsageFeature: String, Codable, CaseIterable, Sendable {
    case document
    case editor
    case preview
    case search
    case formatting
    case insertion
    case export
    case recovery
    case privacy
}

enum AnonymousUsageCommand: String, Codable, CaseIterable, Sendable {
    case openDocument
    case selectSourceView
    case selectSplitView
    case selectPreviewView
    case formatMarkdown
    case insertMarkdown
    case findInDocument
    case exportHTML
    case exportPDF
    case restoreDocument
    case enableAnonymousUsage
}

enum AnonymousUsageDurationBucket: String, Codable, CaseIterable, Sendable {
    case notMeasured
    case under100Milliseconds
    case from100To499Milliseconds
    case from500MillisecondsTo1Second
    case from1To5Seconds
    case over5Seconds

    static func bucket(milliseconds: Double) -> Self {
        switch milliseconds {
        case ..<0: .notMeasured
        case ..<100: .under100Milliseconds
        case ..<500: .from100To499Milliseconds
        case ..<1_000: .from500MillisecondsTo1Second
        case ..<5_000: .from1To5Seconds
        default: .over5Seconds
        }
    }
}

enum AnonymousUsageErrorCategory: String, Codable, CaseIterable, Sendable {
    case none
    case validation
    case unavailable
    case permission
    case conflict
    case rendering
    case writing
    case unknown
}

struct AnonymousUsageContext: Equatable, Sendable {
    let inflowVersion: String
    let macOSMajorVersion: Int
    let interfaceLanguage: String

    static func current(bundle: Bundle = .main, processInfo: ProcessInfo = .processInfo) -> Self {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let language = bundle.preferredLocalizations.first
            ?? Locale.current.language.languageCode?.identifier
            ?? "und"
        return Self(
            inflowVersion: version.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown",
            macOSMajorVersion: processInfo.operatingSystemVersion.majorVersion,
            interfaceLanguage: language
        )
    }
}

struct AnonymousUsageRecord: Codable, Equatable, Sendable {
    let inflowVersion: String
    let macOSMajorVersion: Int
    let interfaceLanguage: String
    let feature: AnonymousUsageFeature
    let command: AnonymousUsageCommand
    let durationBucket: AnonymousUsageDurationBucket
    let errorCategory: AnonymousUsageErrorCategory
    let count: UInt

    enum CodingKeys: String, CodingKey {
        case inflowVersion = "inflow_version"
        case macOSMajorVersion = "macos_major_version"
        case interfaceLanguage = "interface_language"
        case feature
        case command
        case durationBucket = "duration_bucket"
        case errorCategory = "error_category"
        case count
    }

    init(
        context: AnonymousUsageContext,
        feature: AnonymousUsageFeature,
        command: AnonymousUsageCommand,
        durationBucket: AnonymousUsageDurationBucket,
        errorCategory: AnonymousUsageErrorCategory
    ) {
        inflowVersion = context.inflowVersion
        macOSMajorVersion = context.macOSMajorVersion
        interfaceLanguage = context.interfaceLanguage
        self.feature = feature
        self.command = command
        self.durationBucket = durationBucket
        self.errorCategory = errorCategory
        count = 1
    }
}

private struct AnonymousUsageUpload: Encodable, Sendable {
    let records: [AnonymousUsageRecord]
}

struct AnonymousUsagePendingBatch: Sendable {
    fileprivate let files: [URL]
    let data: Data
    let count: Int
}

actor AnonymousUsageStore {
    static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

    private let directoryURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        fileManager = FileManager()
    }

    static func applicationSupport() -> Self {
        let fileManager = FileManager.default
        let root = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        return Self(
            directoryURL: root
                .appendingPathComponent("Inflow", isDirectory: true)
                .appendingPathComponent("AnonymousUsage", isDirectory: true),
        )
    }

    func append(_ record: AnonymousUsageRecord) throws {
        try Task.checkCancellation()
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        try data.write(
            to: directoryURL.appendingPathComponent("\(UUID().uuidString).json"),
            options: .atomic
        )
    }

    func pendingBatch(now: Date = Date()) throws -> AnonymousUsagePendingBatch? {
        let files = try validPendingFiles(now: now)
        guard !files.isEmpty else { return nil }

        let decoder = JSONDecoder()
        var acceptedFiles: [URL] = []
        var records: [AnonymousUsageRecord] = []
        for file in files {
            do {
                records.append(try decoder.decode(AnonymousUsageRecord.self, from: Data(contentsOf: file)))
                acceptedFiles.append(file)
            } catch {
                try? fileManager.removeItem(at: file)
            }
        }
        guard !records.isEmpty else { return nil }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return AnonymousUsagePendingBatch(
            files: acceptedFiles,
            data: try encoder.encode(AnonymousUsageUpload(records: records)),
            count: records.count
        )
    }

    func remove(_ batch: AnonymousUsagePendingBatch) {
        for file in batch.files {
            try? fileManager.removeItem(at: file)
        }
    }

    func clear() {
        try? fileManager.removeItem(at: directoryURL)
    }

    func pendingCount(now: Date = Date()) -> Int {
        (try? validPendingFiles(now: now).count) ?? 0
    }

    private func validPendingFiles(now: Date) throws -> [URL] {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        var valid: [(URL, Date)] = []
        for url in urls where url.pathExtension == "json" {
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey]
            )
            guard values?.isRegularFile == true else {
                try? fileManager.removeItem(at: url)
                continue
            }
            let createdAt = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(createdAt) <= Self.retentionInterval else {
                try? fileManager.removeItem(at: url)
                continue
            }
            valid.append((url, createdAt))
        }
        return valid.sorted {
            if $0.1 == $1.1 { return $0.0.lastPathComponent < $1.0.lastPathComponent }
            return $0.1 < $1.1
        }.map(\.0)
    }

    private func ensureDirectory() throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw CocoaError(.fileWriteFileExists) }
            return
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
}

protocol AnonymousUsageTransport: Sendable {
    func send(_ data: Data) async throws
}

enum AnonymousUsageTransportError: Error, LocalizedError {
    case invalidEndpoint
    case rejected

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "匿名产品使用数据接收地址不可用，记录保留在本机。"
        case .rejected: "匿名产品使用数据暂时无法发送，记录保留在本机。"
        }
    }
}

private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct HTTPSAnonymousUsageTransport: AnonymousUsageTransport {
    let endpoint: URL

    func send(_ data: Data) async throws {
        guard endpoint.scheme?.lowercased() == "https",
              endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil,
              endpoint.host?.isEmpty == false
        else {
            throw AnonymousUsageTransportError.invalidEndpoint
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(
            configuration: configuration,
            delegate: NoRedirectSessionDelegate(),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            throw AnonymousUsageTransportError.rejected
        }
    }
}

enum AnonymousUsageConfiguration {
    static func endpoint(bundle: Bundle = .main) -> URL? {
        guard let value = bundle.object(forInfoDictionaryKey: "InflowAnonymousUsageEndpoint")
            as? String,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil
        else {
            return nil
        }
        return url
    }
}

@MainActor
final class AnonymousUsageDataController: ObservableObject {
    private enum Key {
        static let isEnabled = "privacy.anonymousUsage.enabled"
        static let hasViewedDisclosure = "privacy.anonymousUsage.hasViewedDisclosure"
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var hasViewedDisclosure: Bool
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastErrorMessage: String?

    let isDisclosureAvailable: Bool

    private let defaults: UserDefaults
    private let store: AnonymousUsageStore
    private let transport: (any AnonymousUsageTransport)?
    private let context: AnonymousUsageContext
    private var uploadTask: Task<Void, Never>?
    private var maintenanceTasks: [UUID: Task<Void, Never>] = [:]
    private var maintenanceGeneration = 0
    private var recordTasks: [UUID: Task<Void, Never>] = [:]
    private var consentGeneration = 0

    init(
        defaults: UserDefaults = .standard,
        store: AnonymousUsageStore = .applicationSupport(),
        transport: (any AnonymousUsageTransport)? = AnonymousUsageConfiguration.endpoint()
            .map { HTTPSAnonymousUsageTransport(endpoint: $0) },
        context: AnonymousUsageContext = .current()
    ) {
        self.defaults = defaults
        self.store = store
        self.transport = transport
        self.context = context
        isDisclosureAvailable = transport != nil
        hasViewedDisclosure = defaults.bool(forKey: Key.hasViewedDisclosure)
        isEnabled = defaults.bool(forKey: Key.isEnabled) && transport != nil
        if transport == nil {
            defaults.set(false, forKey: Key.isEnabled)
        }

        let maintenanceID = UUID()
        let task = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            defer { maintenanceTasks[maintenanceID] = nil }
            let count = await store.pendingCount()
            guard !Task.isCancelled, maintenanceGeneration == 0 else { return }
            pendingCount = count
            if isEnabled {
                beginUploadIfNeeded()
            }
        }
        maintenanceTasks[maintenanceID] = task
    }

    func markDisclosureViewed() {
        hasViewedDisclosure = true
        defaults.set(true, forKey: Key.hasViewedDisclosure)
    }

    @discardableResult
    func enable() -> Bool {
        guard hasViewedDisclosure, isDisclosureAvailable else {
            isEnabled = false
            defaults.set(false, forKey: Key.isEnabled)
            lastErrorMessage = "请先查看完整字段、用途、保留和退出规则。"
            return false
        }
        consentGeneration &+= 1
        isEnabled = true
        defaults.set(true, forKey: Key.isEnabled)
        lastErrorMessage = nil
        record(feature: .privacy, command: .enableAnonymousUsage)
        beginUploadIfNeeded()
        return true
    }

    func disable(clearPending: Bool) {
        consentGeneration &+= 1
        isEnabled = false
        defaults.set(false, forKey: Key.isEnabled)
        uploadTask?.cancel()
        uploadTask = nil
        for task in recordTasks.values {
            task.cancel()
        }
        recordTasks.removeAll()
        lastErrorMessage = nil
        if clearPending {
            startClearPendingTask()
        }
    }

    func clearPending() {
        uploadTask?.cancel()
        uploadTask = nil
        startClearPendingTask()
    }

    func record(
        feature: AnonymousUsageFeature,
        command: AnonymousUsageCommand,
        durationBucket: AnonymousUsageDurationBucket = .notMeasured,
        errorCategory: AnonymousUsageErrorCategory = .none
    ) {
        guard isEnabled else { return }
        let generation = consentGeneration
        let id = UUID()
        let record = AnonymousUsageRecord(
            context: context,
            feature: feature,
            command: command,
            durationBucket: durationBucket,
            errorCategory: errorCategory
        )
        let task = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  isEnabled,
                  generation == consentGeneration
            else { return }
            defer { recordTasks[id] = nil }
            do {
                try await store.append(record)
                guard !Task.isCancelled,
                      isEnabled,
                      generation == consentGeneration
                else { return }
                pendingCount = await store.pendingCount()
                beginUploadIfNeeded()
            } catch is CancellationError {
                return
            } catch {
                lastErrorMessage = "匿名产品使用数据暂时无法保存在本机；写作与文件功能不受影响。"
            }
        }
        recordTasks[id] = task
    }

    func waitForIdleForTesting() async {
        for _ in 0..<2_000 {
            if recordTasks.isEmpty, uploadTask == nil, maintenanceTasks.isEmpty { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func beginUploadIfNeeded() {
        guard isEnabled, transport != nil, uploadTask == nil else { return }
        let generation = consentGeneration
        uploadTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            defer { uploadTask = nil }
            while !Task.isCancelled,
                  isEnabled,
                  generation == consentGeneration,
                  let transport
            {
                do {
                    guard let batch = try await store.pendingBatch() else {
                        pendingCount = 0
                        return
                    }
                    try await transport.send(batch.data)
                    guard !Task.isCancelled,
                          isEnabled,
                          generation == consentGeneration
                    else { return }
                    await store.remove(batch)
                    pendingCount = await store.pendingCount()
                    lastErrorMessage = nil
                } catch is CancellationError {
                    return
                } catch {
                    pendingCount = await store.pendingCount()
                    lastErrorMessage = (error as? LocalizedError)?.errorDescription
                        ?? AnonymousUsageTransportError.rejected.localizedDescription
                    return
                }
            }
        }
    }

    private func startClearPendingTask() {
        maintenanceGeneration &+= 1
        let generation = maintenanceGeneration
        for task in maintenanceTasks.values {
            task.cancel()
        }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            defer { maintenanceTasks[id] = nil }
            await store.clear()
            guard !Task.isCancelled, generation == maintenanceGeneration else { return }
            pendingCount = 0
        }
        maintenanceTasks[id] = task
    }
}
