import Foundation

enum MemoScanStatus: String, Codable, Hashable, Sendable {
    case captured
    case training
    case trained
    case failed
}

struct MemoScanRecord: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var keyframeCount: Int
    var pointCount: Int
    var status: MemoScanStatus
    var trainingIterations: Int?
    var errorMessage: String?
}

extension MemoScanRecord {
    var packageURL: URL {
        MemoScanStore.scansDirectory.appendingPathComponent("\(id.uuidString).memo", isDirectory: true)
    }

    var pointCloudURL: URL {
        packageURL.appendingPathComponent("depth/fused_points.ply")
    }

    var thumbnailURL: URL {
        packageURL.appendingPathComponent("thumbnail.jpg")
    }

    var splatURL: URL {
        packageURL.appendingPathComponent("trained_2000.splat")
    }

    var metadataURL: URL {
        packageURL.appendingPathComponent("scan.json")
    }

    var canRenderSplat: Bool {
        status == .trained && FileManager.default.fileExists(atPath: splatURL.path)
    }

    var canTrain: Bool {
        FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("capture.json").path) &&
            FileManager.default.fileExists(atPath: pointCloudURL.path)
    }

    var subtitle: String {
        switch status {
        case .captured:
            return "\(keyframeCount) frames"
        case .training:
            return "training"
        case .trained:
            return "3D Gaussian"
        case .failed:
            return "training failed"
        }
    }
}

@MainActor
final class MemoScanStore: ObservableObject {
    @Published private(set) var scans: [MemoScanRecord] = []

    nonisolated static var scansDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("MemoScans", isDirectory: true)
    }

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        load()
    }

    func load() {
        do {
            try fileManager.createDirectory(at: Self.scansDirectory, withIntermediateDirectories: true)
            let packageURLs = try fileManager.contentsOfDirectory(
                at: Self.scansDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            scans = packageURLs
                .filter { $0.pathExtension == "memo" }
                .compactMap(loadRecord)
                .map(normalizedRecord)
                .sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            scans = []
        }
    }

    func ingest(package: CaptureSessionPackage) throws -> MemoScanRecord {
        try fileManager.createDirectory(at: Self.scansDirectory, withIntermediateDirectories: true)

        let now = Date()
        let id = UUID()
        let packageURL = Self.scansDirectory.appendingPathComponent("\(id.uuidString).memo", isDirectory: true)
        if fileManager.fileExists(atPath: packageURL.path) {
            try fileManager.removeItem(at: packageURL)
        }
        try fileManager.moveItem(at: package.rootURL, to: packageURL)

        var record = MemoScanRecord(
            id: id,
            title: Self.titleFormatter.string(from: now),
            createdAt: now,
            updatedAt: now,
            keyframeCount: package.keyframeCount,
            pointCount: package.pointCount,
            status: .captured,
            trainingIterations: nil,
            errorMessage: nil
        )
        try save(record)
        scans.insert(record, at: 0)
        return record
    }

    func markTrainingStarted(_ record: MemoScanRecord) {
        update(id: record.id) { scan in
            scan.status = .training
            scan.errorMessage = nil
        }
    }

    func markTrainingFailed(_ record: MemoScanRecord, message: String) {
        update(id: record.id) { scan in
            scan.status = .failed
            scan.errorMessage = message
        }
    }

    func markTrainingCancelled(_ record: MemoScanRecord) {
        update(id: record.id) { scan in
            scan.status = .captured
            scan.errorMessage = nil
        }
    }

    @discardableResult
    func markTrained(_ record: MemoScanRecord, iterations: Int) throws -> MemoScanRecord {
        guard let index = scans.firstIndex(where: { $0.id == record.id }) else {
            throw MemoScanStoreError.missingRecord
        }

        var scan = scans[index]
        scan.status = .trained
        scan.trainingIterations = iterations
        scan.errorMessage = nil
        scan.updatedAt = Date()

        try removeRawTrainingData(for: scan)
        try save(scan)
        scans[index] = scan
        sort()
        return scan
    }

    func delete(_ record: MemoScanRecord) {
        do {
            if fileManager.fileExists(atPath: record.packageURL.path) {
                try fileManager.removeItem(at: record.packageURL)
            }
            scans.removeAll { $0.id == record.id }
        } catch {
            return
        }
    }

    func record(id: UUID) -> MemoScanRecord? {
        scans.first { $0.id == id }
    }

    private func update(id: UUID, mutate: (inout MemoScanRecord) -> Void) {
        guard let index = scans.firstIndex(where: { $0.id == id }) else { return }
        var scan = scans[index]
        mutate(&scan)
        scan.updatedAt = Date()
        do {
            try save(scan)
            scans[index] = scan
            sort()
        } catch {
            scans[index] = scan
        }
    }

    private func save(_ record: MemoScanRecord) throws {
        try fileManager.createDirectory(at: record.packageURL, withIntermediateDirectories: true)
        let data = try encoder.encode(record)
        try data.write(to: record.metadataURL, options: .atomic)
    }

    private func loadRecord(packageURL: URL) -> MemoScanRecord? {
        let url = packageURL.appendingPathComponent("scan.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(MemoScanRecord.self, from: data)
    }

    private func normalizedRecord(_ record: MemoScanRecord) -> MemoScanRecord {
        guard record.status == .training else { return record }
        var scan = record
        scan.status = .captured
        scan.errorMessage = nil
        try? save(scan)
        return scan
    }

    private func removeRawTrainingData(for record: MemoScanRecord) throws {
        let rawNames = ["images", "arkit", "sparse", "depth", "capture.json"]
        for name in rawNames {
            let url = record.packageURL.appendingPathComponent(name)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func sort() {
        scans.sort { $0.updatedAt > $1.updatedAt }
    }

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

enum MemoScanStoreError: LocalizedError {
    case missingRecord

    var errorDescription: String? {
        switch self {
        case .missingRecord:
            return "Scan no longer exists."
        }
    }
}
