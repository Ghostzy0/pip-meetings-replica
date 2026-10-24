#if PIP_EDITION
import Foundation
import Observation

/// Journal completed outputs before the upstream queue may reap them. Reload
/// and a fresh launch both retry durable pending imports without replaying all
/// historical pipeline jobs or resurrecting deliberately archived meetings.
@Observable @MainActor
final class PipLibraryBridge {
    static let shared = PipLibraryBridge()
    private struct Pending: Codable { var version = 1; let job: PipelineJob }
    private(set) var library: PipMeetingLibrary?
    private(set) var problem: String?
    private(set) var pendingCount = 0
    private let libraryRoot: URL
    private let pendingRoot: URL
    private var pending: [UUID: PipelineJob] = [:]
    private var unreadablePending = false

    init(libraryRoot: URL = AppPaths.dataDir.appendingPathComponent("pip-library", isDirectory: true),
         pendingRoot: URL = AppPaths.dataDir.appendingPathComponent("pending-library-ingest", isDirectory: true)) {
        self.libraryRoot = libraryRoot
        self.pendingRoot = pendingRoot
        reload()
    }

    func reload() {
        do {
            if let library { try library.reload() }
            else { library = try PipMeetingLibrary(root: libraryRoot) }
            try loadPending()
            for job in Array(pending.values) { _ = attempt(job) }
            updateProblem()
        } catch { problem = "The meeting library could not open. Your files and pending imports are kept. Open the app folder or try again." }
    }

    /// False means neither a library copy nor a durable retry journal exists.
    /// The caller must retain an error job instead of silently completing it.
    @discardableResult func ingest(_ source: PipelineJob) -> Bool {
        guard source.transcriptPath != nil else { return true }
        var job = source
        if job.pipMeetingID == nil, let chunk = PipCaptureSession.shared.chunk(for: job.id) {
            job.pipMeetingID = chunk.meetingID
            job.pipTimelineOffset = chunk.offset
        }
        pending[job.id] = job
        let durable: Bool
        do { try persist(job); durable = true }
        catch { durable = false }
        let saved = attempt(job)
        updateProblem()
        return saved || durable
    }

    private func attempt(_ job: PipelineJob) -> Bool {
        do {
            guard let library else { throw PipMeetingLibraryError.invalidDocument }
            _ = try library.ingest(job: job, meetingID: job.pipMeetingID, offset: job.pipTimelineOffset ?? 0)
        } catch PipMeetingLibraryError.archivedMeeting {
            // Suppression is a successful deliberate refusal, never a retry.
        } catch { return false }
        pending.removeValue(forKey: job.id)
        let file = pendingRoot.appendingPathComponent(job.id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { try FileManager.default.removeItem(at: file) }
            catch { unreadablePending = true } // Idempotent replay is safe.
        }
        return true
    }

    private func updateProblem() {
        pendingCount = pending.count
        if pendingCount > 0 {
            problem = "A saved transcript is waiting for its library copy. Original files are kept. Reload the library to retry."
        } else if unreadablePending {
            problem = "A pending-import file could not be read or cleared. Its original bytes are kept. Open the app folder to review it."
        } else { problem = nil }
    }

    private func requireSafePendingRoot() throws {
        if FileManager.default.fileExists(atPath: pendingRoot.path) {
            let attrs = try pendingRoot.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard attrs.isDirectory == true, attrs.isSymbolicLink != true else { throw PipMeetingLibraryError.unsafePath }
            // Pending records contain transcript text. Tighten a pre-existing
            // directory as well as newly-created roots so its contents stay
            // private to this user account.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pendingRoot.path)
        }
    }

    private func persist(_ job: PipelineJob) throws {
        try requireSafePendingRoot()
        try FileManager.default.createDirectory(at: pendingRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pendingRoot.path)
        let file = pendingRoot.appendingPathComponent(job.id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: file.path),
           try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw PipMeetingLibraryError.unsafePath }
        try JSONEncoder().encode(Pending(job: job)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func loadPending() throws {
        try requireSafePendingRoot()
        unreadablePending = false
        guard FileManager.default.fileExists(atPath: pendingRoot.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: pendingRoot, includingPropertiesForKeys: nil) {
            guard file.pathExtension == "json" else { continue }
            do {
                let attrs = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
                guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, (attrs.fileSize ?? .max) < 16 * 1024 * 1024 else { throw PipMeetingLibraryError.invalidDocument }
                let stored = try JSONDecoder().decode(Pending.self, from: Data(contentsOf: file))
                guard stored.version == 1, file.deletingPathExtension().lastPathComponent == stored.job.id.uuidString else { throw PipMeetingLibraryError.invalidDocument }
                if pending[stored.job.id] == nil { pending[stored.job.id] = stored.job }
            } catch { unreadablePending = true }
        }
    }
}
#endif
