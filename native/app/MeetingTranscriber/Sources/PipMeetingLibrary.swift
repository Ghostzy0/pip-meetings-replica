#if PIP_EDITION
import CryptoKit
import Foundation
import Observation

/// Frozen source evidence. Editable transcript text and speaker notes live separately.
struct PipMeetingEvidenceSpan: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceJobID: UUID
    let revisionID: UUID
    let sourceStart: TimeInterval
    let sourceEnd: TimeInterval
    let timelineOffset: TimeInterval
    let text: String
    let speaker: String
    let suppressed: Bool
    var start: TimeInterval { sourceStart + timelineOffset }
    var end: TimeInterval { sourceEnd + timelineOffset }
}

struct PipMeetingSourceRevision: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceJobID: UUID
    let capturedAt: Date
    let fingerprint: String
    let transcript: String
    let transcriptPath: URL?
    let segmentsPath: URL?
    let rawSegmentsJSON: Data?
    /// Original pipeline file references; no audio is copied or mutated here.
    /// Optional for library documents created before durable audio references.
    let audioPaths: [URL]?
    let timelineOffset: TimeInterval
    let spans: [PipMeetingEvidenceSpan]
}

struct PipMeetingDecision: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case decision, action }
    let id: UUID
    fileprivate(set) var kind: Kind
    fileprivate(set) var text: String
    fileprivate(set) var spanID: UUID?
    fileprivate(set) var complete: Bool
}

struct PipMeetingRecord: Codable, Identifiable, Equatable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let sourceJobID: UUID?
    let createdAt: Date
    fileprivate(set) var updatedAt: Date
    fileprivate(set) var title: String
    fileprivate(set) var notes: String
    fileprivate(set) var transcript: String
    fileprivate(set) var decisions: [PipMeetingDecision]
    fileprivate(set) var sourceRevisions: [PipMeetingSourceRevision]
    fileprivate(set) var transcriptEdited: Bool

    var evidenceSpans: [PipMeetingEvidenceSpan] { sourceRevisions.flatMap(\.spans) }
    /// Latest evidence for each recorded job, in the explicit meeting timeline.
    /// Earlier evidence remains addressable by decisions through evidenceSpans.
    var currentEvidenceSpans: [PipMeetingEvidenceSpan] { currentSourceRevisions.flatMap(\.spans) }

    /// Queue completion order does not define the order of a paused meeting's
    /// chunks. Equal-offset ties remain stable across save/reopen.
    fileprivate var currentSourceRevisions: [PipMeetingSourceRevision] {
        var latest: [UUID: PipMeetingSourceRevision] = [:]
        for revision in sourceRevisions { latest[revision.sourceJobID] = revision }
        return latest.values.sorted { lhs, rhs in
            if lhs.timelineOffset != rhs.timelineOffset { return lhs.timelineOffset < rhs.timelineOffset }
            if lhs.capturedAt != rhs.capturedAt { return lhs.capturedAt < rhs.capturedAt }
            if lhs.sourceJobID != rhs.sourceJobID { return lhs.sourceJobID.uuidString < rhs.sourceJobID.uuidString }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Best-known media timeline end, using immutable evidence and each current
    /// source revision's own retained audio references. No wall-clock gap is
    /// inferred between separate recording sessions.
    func timelineEnd(audioDuration: (URL) -> TimeInterval?) -> TimeInterval {
        currentSourceRevisions.reduce(0) { latest, revision in
            let spanEnd = revision.spans.map(\.end).filter { $0.isFinite && $0 >= 0 }.max() ?? 0
            let mediaEnd = (revision.audioPaths ?? []).compactMap(audioDuration)
                .filter { $0.isFinite && $0 >= 0 }
                .map { revision.timelineOffset + $0 }.max() ?? 0
            return max(latest, max(spanEnd, mediaEnd))
        }
    }

    /// Retain historical file references too: late relocation can change paths,
    /// and a file may survive after its queue job is reaped. Existence is checked
    /// when the UI opens a source; paths are never read during library browsing.
    var audioPaths: [URL] {
        let paths = sourceRevisions.flatMap { $0.audioPaths ?? [] }
            .filter(\.isFileURL).map(\.standardizedFileURL)
        return Set(paths).sorted { $0.path < $1.path }
    }

    fileprivate init(id: UUID, title: String, createdAt: Date, sourceJobID: UUID? = nil) {
        schemaVersion = 1
        self.id = id; self.title = title; self.createdAt = createdAt; self.sourceJobID = sourceJobID
        updatedAt = createdAt; notes = ""; transcript = ""; decisions = []; sourceRevisions = []; transcriptEdited = false
    }
}

/// A stable projection of an incomplete action item for the optional cross-meeting view.
struct PipOpenAction: Identifiable, Equatable, Sendable {
    let meetingID: UUID
    let decisionID: UUID
    let meetingTitle: String
    let meetingDate: Date
    let text: String
    let spanID: UUID?

    var id: String { "\(meetingID.uuidString):\(decisionID.uuidString)" }
}

enum PipMeetingLibraryError: LocalizedError, Equatable {
    case unsafePath, missingMeeting, missingEvidence, invalidDocument, unsupportedVersion, tooLarge, noTranscript, archivedMeeting
    var errorDescription: String? {
        switch self {
        case .unsafePath: "The meeting library contains an unsafe file link. Its files have been kept. Choose a normal local library folder."
        case .missingMeeting: "This meeting is no longer in the library. Reload the library and try again."
        case .missingEvidence: "That source passage is no longer available. Choose a passage from this meeting."
        case .invalidDocument: "The meeting could not be read safely. Existing files have been kept."
        case .unsupportedVersion: "This meeting uses another library format. Open it with the version that created it; existing files have been kept."
        case .tooLarge: "This meeting is too large for this library version. Existing files have been kept."
        case .noTranscript: "No saved transcript or timestamped segments are available for this job yet."
        case .archivedMeeting: "This meeting is in the recovery folder. Restore it before importing more results."
        }
    }
}

/// Local metadata copies only. Ingest reads exactly the pipeline's declared output
/// paths; remove/purge never alter pipeline audio, transcript or sidecar originals.
/// Mutations become visible only after their atomic document write succeeds.
@Observable @MainActor
final class PipMeetingLibrary {
    private(set) var meetings: [PipMeetingRecord] = []
    private(set) var issues: [String] = []
    private var suppressedJobIDs = Set<UUID>()
    private var suppressedMeetingIDs = Set<UUID>()
    let root: URL
    private let fm = FileManager.default
    private static let maximumSourceBytes = 16 * 1024 * 1024
    private static let maximumDocumentBytes = 64 * 1024 * 1024
    private static let maximumTime: TimeInterval = 315_576_000 // ten years, including explicit grouped offsets

    init(root: URL = AppPaths.dataDir.appendingPathComponent("pip-library", isDirectory: true)) throws {
        guard root.isFileURL else { throw PipMeetingLibraryError.unsafePath }
        let fileManager = FileManager.default
        let suppliedRoot = root.standardizedFileURL
        if fileManager.fileExists(atPath: suppliedRoot.path) {
            let values = try suppliedRoot.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else { throw PipMeetingLibraryError.unsafePath }
        }
        // Create through the caller's checked spelling first. Resolving an
        // absent path can preserve a symlink alias (for example /private/tmp);
        // after creation the child URLs resolve through its canonical spelling.
        try fileManager.createDirectory(at: suppliedRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let createdValues = try suppliedRoot.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard createdValues.isSymbolicLink != true, createdValues.isDirectory == true else {
            throw PipMeetingLibraryError.unsafePath
        }
        let canonicalRoot = URL(
            fileURLWithPath: suppliedRoot.resolvingSymlinksInPath().standardizedFileURL.path,
            isDirectory: true
        )
        let canonicalValues = try canonicalRoot.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard canonicalValues.isSymbolicLink != true, canonicalValues.isDirectory == true,
              canonicalRoot.resolvingSymlinksInPath().standardizedFileURL.path == canonicalRoot.standardizedFileURL.path else {
            throw PipMeetingLibraryError.unsafePath
        }
        self.root = canonicalRoot
        try checkRoot()
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
        try reload()
    }

    func filtered(_ query: String) -> [PipMeetingRecord] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return meetings }
        return meetings.filter { record in
            ([record.title, record.notes, record.transcript] + record.decisions.map(\.text))
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    /// Derived only from saved library documents; ties retain meeting identity
    /// and action insertion order instead of depending on filesystem iteration.
    func openActions() -> [PipOpenAction] {
        meetings.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }.flatMap { meeting in
            meeting.decisions.compactMap { decision in
                guard decision.kind == .action, !decision.complete else { return nil }
                return PipOpenAction(
                    meetingID: meeting.id,
                    decisionID: decision.id,
                    meetingTitle: meeting.title,
                    meetingDate: meeting.createdAt,
                    text: decision.text,
                    spanID: decision.spanID
                )
            }
        }
    }

    func reload() throws {
        try checkRoot()
        try loadSuppression()
        var loaded: [PipMeetingRecord] = []
        var warnings: [String] = []
        for directory in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            do {
                try checkDirectory(directory)
                do { loaded.append(try decode(directory.appendingPathComponent("meeting.json"), expected: id)) }
                catch PipMeetingLibraryError.unsupportedVersion {
                    warnings.append("A meeting uses a different document version. Its files were kept unchanged.")
                } catch {
                    do {
                        loaded.append(try decode(directory.appendingPathComponent("meeting.previous.json"), expected: id))
                        warnings.append("Recovered an earlier saved meeting. The damaged original is kept until a new save archives it.")
                    } catch {
                        warnings.append("A meeting could not be read. Its original files were kept unchanged.")
                    }
                }
            } catch { warnings.append("An unsafe or unavailable meeting folder was skipped. Its files were kept unchanged.") }
        }
        meetings = loaded.sorted { $0.updatedAt > $1.updatedAt }
        issues = warnings
    }

    @discardableResult
    func create(title: String = "Untitled meeting") throws -> UUID {
        let record = PipMeetingRecord(id: UUID(), title: title, createdAt: Date())
        try commit(record)
        return record.id
    }

    func update(id: UUID, title: String? = nil, notes: String? = nil, transcript: String? = nil) throws {
        try mutate(id) { record in
            if let title { record.title = title }
            if let notes { record.notes = notes }
            if let transcript { record.transcript = transcript; record.transcriptEdited = true }
        }
    }

    @discardableResult
    func addDecision(meetingID: UUID, kind: PipMeetingDecision.Kind, text: String, spanID: UUID? = nil) throws -> UUID {
        let id = UUID()
        try mutate(meetingID) { record in
            try Self.checkSpan(spanID, in: record)
            record.decisions.append(PipMeetingDecision(id: id, kind: kind, text: text, spanID: spanID, complete: false))
        }
        return id
    }

    /// Set replaceReference=true to deliberately clear a source reference with nil.
    func updateDecision(meetingID: UUID, decisionID: UUID, text: String? = nil, complete: Bool? = nil,
                        kind: PipMeetingDecision.Kind? = nil, spanID: UUID? = nil, replaceReference: Bool = false) throws {
        try mutate(meetingID) { record in
            guard let index = record.decisions.firstIndex(where: { $0.id == decisionID }) else { throw PipMeetingLibraryError.missingEvidence }
            if let text { record.decisions[index].text = text }
            if let complete { record.decisions[index].complete = complete }
            if let kind { record.decisions[index].kind = kind }
            if replaceReference || spanID != nil {
                try Self.checkSpan(spanID, in: record)
                record.decisions[index].spanID = spanID
            }
        }
    }

    func removeDecision(meetingID: UUID, decisionID: UUID) throws {
        try mutate(meetingID) { $0.decisions.removeAll { $0.id == decisionID } }
    }

    @discardableResult
    func ingest(job: PipelineJob, segments: [TimestampedSegment]? = nil,
                meetingID: UUID? = nil, offset: TimeInterval = 0) throws -> UUID {
        guard Self.validTime(offset) else { throw PipMeetingLibraryError.invalidDocument }
        let id = meetingID ?? job.id
        try checkRoot()
        try loadSuppression()
        guard !suppressedJobIDs.contains(job.id), !suppressedMeetingIDs.contains(id) else {
            throw PipMeetingLibraryError.archivedMeeting
        }
        if try archivedRecordExists(id: id) { throw PipMeetingLibraryError.archivedMeeting }
        var record = meetings.first { $0.id == id }
            ?? PipMeetingRecord(id: id, title: job.meetingTitle, createdAt: job.artifactStartTime, sourceJobID: job.id)
        let source = try readSource(job: job, supplied: segments)
        let audioPaths = Set([job.mixPath, job.appPath, job.micPath].compactMap { $0 }
            .filter(\.isFileURL).map(\.standardizedFileURL)).sorted { $0.path < $1.path }
        let encoder = Self.encoder()
        struct FingerprintInput: Encodable {
            let jobID: UUID
            let transcript: String
            let segments: [TimestampedSegment]
            let offset: TimeInterval
            let audioPaths: [URL]
        }
        let input = FingerprintInput(jobID: job.id, transcript: source.transcript, segments: source.segments,
                                     offset: offset, audioPaths: audioPaths)
        let fingerprint = SHA256.hash(data: try encoder.encode(input)).map { String(format: "%02x", $0) }.joined()
        // Only the latest revision can be replayed as a no-op. A→B→A is a
        // genuine return to A and must replace B as current source evidence.
        if record.sourceRevisions.last(where: { $0.sourceJobID == job.id })?.fingerprint == fingerprint { return id }
        let revisionID = UUID()
        let spans = try source.segments.map { segment -> PipMeetingEvidenceSpan in
            guard Self.validTime(segment.start), Self.validTime(segment.end), segment.end >= segment.start,
                  Self.validTime(segment.end + offset) else { throw PipMeetingLibraryError.invalidDocument }
            return PipMeetingEvidenceSpan(id: UUID(), sourceJobID: job.id, revisionID: revisionID,
                sourceStart: segment.start, sourceEnd: segment.end, timelineOffset: offset,
                text: segment.text, speaker: segment.speaker, suppressed: segment.suppressed)
        }
        let revision = PipMeetingSourceRevision(id: revisionID, sourceJobID: job.id, capturedAt: Date(),
            fingerprint: fingerprint, transcript: source.transcript, transcriptPath: job.transcriptPath,
            segmentsPath: source.path, rawSegmentsJSON: source.raw, audioPaths: audioPaths,
            timelineOffset: offset, spans: spans)
        record.sourceRevisions.append(revision)
        if !record.transcriptEdited {
            record.transcript = record.currentSourceRevisions.map(\.transcript).joined(separator: "\n\n")
        }
        record.updatedAt = Date()
        try commit(record)
        return id
    }

    /// Move only this library's document and backups into a recoverable folder.
    @discardableResult
    func remove(id: UUID) throws -> URL {
        guard let record = meetings.first(where: { $0.id == id }) else { throw PipMeetingLibraryError.missingMeeting }
        try loadSuppression()
        let previousJobs = suppressedJobIDs
        let previousMeetings = suppressedMeetingIDs
        let jobs = Set(record.sourceRevisions.map(\.sourceJobID) + [record.sourceJobID].compactMap { $0 })
        let directory = try meetingDirectory(id, create: false)
        let archive = try archiveDirectory(create: true)
        let destination = archive.appendingPathComponent(id.uuidString + "-" + UUID().uuidString, isDirectory: true)
        // Persist suppression before the move: a crash must not replay pipeline
        // results into a fresh copy of a meeting the user deliberately removed.
        try saveSuppression(jobs: previousJobs.union(jobs), meetings: previousMeetings.union([id]))
        do { try fm.moveItem(at: directory, to: destination) }
        catch {
            try? saveSuppression(jobs: previousJobs, meetings: previousMeetings)
            throw error
        }
        meetings.removeAll { $0.id == id }
        return destination
    }

    @discardableResult
    func restore(from archived: URL) throws -> UUID {
        let id = try checkedArchive(archived)
        let record: PipMeetingRecord
        do { record = try decode(archived.appendingPathComponent("meeting.json"), expected: id) }
        catch PipMeetingLibraryError.unsupportedVersion { throw PipMeetingLibraryError.unsupportedVersion }
        catch { record = try decode(archived.appendingPathComponent("meeting.previous.json"), expected: id) }
        let destination = root.appendingPathComponent(id.uuidString, isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else { throw PipMeetingLibraryError.invalidDocument }
        try loadSuppression()
        let jobs = Set(record.sourceRevisions.map(\.sourceJobID) + [record.sourceJobID].compactMap { $0 })
        try fm.moveItem(at: archived, to: destination)
        do {
            try saveSuppression(jobs: suppressedJobIDs.subtracting(jobs), meetings: suppressedMeetingIDs.subtracting([id]))
        } catch {
            try? fm.moveItem(at: destination, to: archived)
            throw error
        }
        meetings.append(record)
        meetings.sort { $0.updatedAt > $1.updatedAt }
        return id
    }

    /// Caller supplies explicit confirmation. This deletes the library copy only.
    /// Original pipeline recordings, output transcripts and sidecars are untouched.
    func purgeArchived(from archived: URL) throws {
        _ = try checkedArchive(archived)
        try fm.removeItem(at: archived)
    }

    func archivedMeetings() throws -> [URL] {
        let directory = try archiveDirectory(create: false)
        guard fm.fileExists(atPath: directory.path) else { return [] }
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { (try? checkedArchive($0)) != nil }
    }

    private struct Suppression: Codable {
        let schemaVersion: Int
        let jobs: [UUID]
        let meetings: [UUID]
    }
    private func loadSuppression() throws {
        try checkRoot()
        let path = root.appendingPathComponent("retention.json")
        guard fm.fileExists(atPath: path.path) else {
            suppressedJobIDs = []; suppressedMeetingIDs = []
            return
        }
        try checkRegularFile(path)
        let data = try Self.readBounded(path, limit: 4 * 1024 * 1024)
        struct Header: Decodable { let schemaVersion: Int }
        guard try JSONDecoder().decode(Header.self, from: data).schemaVersion == 1 else {
            throw PipMeetingLibraryError.unsupportedVersion
        }
        let saved = try JSONDecoder().decode(Suppression.self, from: data)
        suppressedJobIDs = Set(saved.jobs)
        suppressedMeetingIDs = Set(saved.meetings)
    }
    private func saveSuppression(jobs: Set<UUID>, meetings: Set<UUID>) throws {
        try checkRoot()
        let path = root.appendingPathComponent("retention.json")
        if fm.fileExists(atPath: path.path) { try checkRegularFile(path) }
        let saved = Suppression(schemaVersion: 1, jobs: jobs.sorted { $0.uuidString < $1.uuidString },
                                meetings: meetings.sorted { $0.uuidString < $1.uuidString })
        let data = try Self.encoder().encode(saved)
        guard data.count <= 4 * 1024 * 1024 else { throw PipMeetingLibraryError.tooLarge }
        try privateWrite(data, to: path)
        suppressedJobIDs = jobs
        suppressedMeetingIDs = Set(saved.meetings)
    }

    private func mutate(_ id: UUID, change: (inout PipMeetingRecord) throws -> Void) throws {
        guard var record = meetings.first(where: { $0.id == id }) else { throw PipMeetingLibraryError.missingMeeting }
        try change(&record)
        record.updatedAt = Date()
        try commit(record)
    }

    private func commit(_ record: PipMeetingRecord) throws {
        try Self.validate(record)
        let directory = try meetingDirectory(record.id, create: true)
        let target = directory.appendingPathComponent("meeting.json")
        let data = try Self.encoder().encode(record)
        guard data.count <= Self.maximumDocumentBytes else { throw PipMeetingLibraryError.tooLarge }
        if fm.fileExists(atPath: target.path) {
            try checkRegularFile(target)
            var validPrimary = false
            do {
                _ = try decode(target, expected: record.id)
                validPrimary = true
            } catch PipMeetingLibraryError.unsupportedVersion { throw PipMeetingLibraryError.unsupportedVersion }
            catch {
                // Preserve exact corrupt bytes before replacing the recovered primary.
                try quarantine(target, in: directory, stem: "meeting")
            }
            if validPrimary {
                let backup = directory.appendingPathComponent("meeting.previous.json")
                if fm.fileExists(atPath: backup.path) {
                    try checkRegularFile(backup)
                    do { _ = try decode(backup, expected: record.id) }
                    catch PipMeetingLibraryError.unsupportedVersion { throw PipMeetingLibraryError.unsupportedVersion }
                    catch { try quarantine(backup, in: directory, stem: "meeting.previous") }
                }
                try privateWrite(try Self.readBounded(target, limit: Self.maximumDocumentBytes), to: backup)
            }
        }
        try privateWrite(data, to: target)
        if let index = meetings.firstIndex(where: { $0.id == record.id }) { meetings[index] = record }
        else { meetings.append(record) }
        meetings.sort { $0.updatedAt > $1.updatedAt }
    }

    private func quarantine(_ path: URL, in directory: URL, stem: String) throws {
        let copy = directory.appendingPathComponent("\(stem).corrupt-\(UUID().uuidString).json")
        try fm.copyItem(at: path, to: copy)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
    }

    private func decode(_ path: URL, expected id: UUID) throws -> PipMeetingRecord {
        try checkRegularFile(path)
        let data = try Self.readBounded(path, limit: Self.maximumDocumentBytes)
        struct Header: Decodable { let schemaVersion: Int }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.schemaVersion == 1 else { throw PipMeetingLibraryError.unsupportedVersion }
        let record = try JSONDecoder().decode(PipMeetingRecord.self, from: data)
        guard record.id == id else { throw PipMeetingLibraryError.invalidDocument }
        try Self.validate(record)
        return record
    }

    private static func validate(_ record: PipMeetingRecord) throws {
        guard record.schemaVersion == 1 else { throw PipMeetingLibraryError.unsupportedVersion }
        guard record.createdAt.timeIntervalSince1970.isFinite, record.updatedAt.timeIntervalSince1970.isFinite,
              Set(record.decisions.map(\.id)).count == record.decisions.count,
              Set(record.sourceRevisions.map(\.id)).count == record.sourceRevisions.count,
              Set(record.evidenceSpans.map(\.id)).count == record.evidenceSpans.count else {
            throw PipMeetingLibraryError.invalidDocument
        }
        for revision in record.sourceRevisions {
            guard revision.capturedAt.timeIntervalSince1970.isFinite, validTime(revision.timelineOffset),
                  (revision.rawSegmentsJSON?.count ?? 0) <= maximumSourceBytes else { throw PipMeetingLibraryError.invalidDocument }
            for span in revision.spans {
                guard span.revisionID == revision.id, span.sourceJobID == revision.sourceJobID,
                      span.timelineOffset == revision.timelineOffset, validTime(span.sourceStart), validTime(span.sourceEnd),
                      span.sourceEnd >= span.sourceStart, validTime(span.end) else { throw PipMeetingLibraryError.invalidDocument }
            }
        }
        for decision in record.decisions { try checkSpan(decision.spanID, in: record) }
    }

    private static func checkSpan(_ id: UUID?, in record: PipMeetingRecord) throws {
        if let id, !record.evidenceSpans.contains(where: { $0.id == id }) { throw PipMeetingLibraryError.missingEvidence }
    }
    private static func validTime(_ value: TimeInterval) -> Bool { value.isFinite && value >= 0 && value <= maximumTime }

    private struct SourceInput { let transcript: String; let segments: [TimestampedSegment]; let raw: Data?; let path: URL? }
    private func readSource(job: PipelineJob, supplied: [TimestampedSegment]?) throws -> SourceInput {
        var raw: Data?
        var path: URL?
        var segments = supplied
        if let output = job.sidecarOutputDir, let slug = job.namingSlug {
            guard Self.safeFilename(slug) else { throw PipMeetingLibraryError.unsafePath }
            let folder = output.appendingPathComponent("recordings", isDirectory: true)
            let candidate = folder.appendingPathComponent(slug + "_segments.json")
            if fm.fileExists(atPath: candidate.path) {
                try Self.checkSourceFile(candidate)
                // The only derived read is this job's exact sidecar, never a directory scan.
                let data = try Self.readBounded(candidate, limit: Self.maximumSourceBytes)
                raw = data; path = candidate
                let decoded = try JSONDecoder().decode([TimestampedSegment].self, from: data)
                if segments == nil { segments = decoded }
            }
        }
        var text: String?
        if let transcript = job.transcriptPath, fm.fileExists(atPath: transcript.path) {
            try Self.checkSourceFile(transcript)
            let data = try Self.readBounded(transcript, limit: Self.maximumSourceBytes)
            guard let decoded = String(data: data, encoding: .utf8) else { throw PipMeetingLibraryError.invalidDocument }
            text = decoded
        }
        guard segments != nil || text != nil else { throw PipMeetingLibraryError.noTranscript }
        let original = segments ?? []
        // Render our own bounded timestamps; upstream's formatter assumes native values.
        let rendered = original.filter { !$0.suppressed }.map { segment in
            "[\(Self.timestamp(segment.start))] " + (segment.speaker.isEmpty ? "" : segment.speaker + ": ") + segment.text
        }.joined(separator: "\n")
        return SourceInput(transcript: text ?? rendered, segments: original, raw: raw, path: path)
    }

    private static func safeFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }
    private static func checkSourceFile(_ path: URL) throws {
        guard path.isFileURL else { throw PipMeetingLibraryError.unsafePath }
        let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw PipMeetingLibraryError.unsafePath }
    }
    private static func readBounded(_ path: URL, limit: Int) throws -> Data {
        guard let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit else { throw PipMeetingLibraryError.tooLarge }
        let data = try Data(contentsOf: path)
        guard data.count <= limit else { throw PipMeetingLibraryError.tooLarge }
        return data
    }
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    private func checkRoot() throws {
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              root.resolvingSymlinksInPath().standardizedFileURL.path == root.standardizedFileURL.path else { throw PipMeetingLibraryError.unsafePath }
    }
    private func checkDirectory(_ directory: URL) throws {
        try checkRoot()
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              directory.deletingLastPathComponent().standardizedFileURL.path == root.path,
              directory.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path == root.path else { throw PipMeetingLibraryError.unsafePath }
    }
    private func checkRegularFile(_ path: URL) throws { try Self.checkSourceFile(path) }
    private func meetingDirectory(_ id: UUID, create: Bool) throws -> URL {
        try checkRoot()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        if create, !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try checkDirectory(directory)
        return directory
    }
    private func archiveDirectory(create: Bool) throws -> URL {
        try checkRoot()
        let directory = root.appendingPathComponent("Archived", isDirectory: true)
        if !fm.fileExists(atPath: directory.path) {
            if !create { return directory }
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try checkDirectory(directory)
        return directory
    }
    private func checkedArchive(_ path: URL) throws -> UUID {
        let archive = try archiveDirectory(create: false)
        guard path.isFileURL, path.deletingLastPathComponent().standardizedFileURL.path == archive.path else { throw PipMeetingLibraryError.unsafePath }
        let name = path.lastPathComponent
        guard name.count == 73, let id = UUID(uuidString: String(name.prefix(36))),
              name[name.index(name.startIndex, offsetBy: 36)] == "-",
              UUID(uuidString: String(name.suffix(36))) != nil else { throw PipMeetingLibraryError.unsafePath }
        let values = try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              path.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path == archive.path else { throw PipMeetingLibraryError.unsafePath }
        return id
    }
    private func archivedRecordExists(id: UUID) throws -> Bool {
        try archivedMeetings().contains { $0.lastPathComponent.hasPrefix(id.uuidString + "-") }
    }
    private func privateWrite(_ data: Data, to path: URL) throws {
        try data.write(to: path, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let bounded = seconds.isFinite ? min(max(0, seconds), maximumTime) : 0
        let total = Int(bounded)
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
    static func htmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
    static func markdownEscape(_ text: String) -> String {
        var escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        for character in ["\\", "`", "*", "_", "{", "}", "[", "]", "(", ")", "#", "!", "|", "~", "+", "-", "."] {
            escaped = escaped.replacingOccurrences(of: character, with: "\\" + character)
        }
        return escaped.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "\n\n")
    }
    static func markdown(_ record: PipMeetingRecord) -> String {
        var output = "# \(markdownEscape(record.title))\n\n## Notes\n\n\(markdownEscape(record.notes))\n\n## Decisions and actions\n\n"
        for decision in record.decisions {
            let source = decision.spanID.flatMap { id in record.evidenceSpans.first { $0.id == id } }
            let reference = source.map { " (source \(timestamp($0.start)), passage \($0.id.uuidString))" } ?? " (no source passage)"
            output += "- [\(decision.complete ? "x" : " ")] \(decision.kind.rawValue.capitalized): \(markdownEscape(decision.text))\(reference)\n"
        }
        output += "\n## Edited transcript\n\n\(markdownEscape(record.transcript))\n\n## Original source passages\n\n"
        for span in record.evidenceSpans {
            output += "### \(timestamp(span.start)) · passage \(span.id.uuidString)\n\n"
            if span.suppressed { output += "Suppressed echo passage retained as original evidence.\n\n" }
            output += "\(markdownEscape(span.speaker)): \(markdownEscape(span.text))\n\n"
        }
        return output
    }
    static func html(_ record: PipMeetingRecord) -> String {
        var output = "<!doctype html><html lang=\"en-GB\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>\(htmlEscape(record.title))</title><style>body{font:17px/1.6 system-ui;max-width:850px;margin:40px auto;padding:0 24px;color:#121211;background:#fff}p{white-space:pre-wrap;overflow-wrap:anywhere}article{border-top:1px solid #ddd;padding:16px 0}a{color:inherit}</style><main><h1>\(htmlEscape(record.title))</h1><h2>Notes</h2><p>\(htmlEscape(record.notes))</p><h2>Decisions and actions</h2><ul>"
        for decision in record.decisions {
            let source = decision.spanID.flatMap { id in record.evidenceSpans.first { $0.id == id } }
            let reference = source.map { " <a href=\"#passage-\($0.id.uuidString)\">Source \(timestamp($0.start))</a>" } ?? " (no source passage)"
            output += "<li>\(decision.complete ? "✓ " : "")<strong>\(decision.kind.rawValue.capitalized):</strong> \(htmlEscape(decision.text))\(reference)</li>"
        }
        output += "</ul><h2>Edited transcript</h2><p>\(htmlEscape(record.transcript))</p><h2>Original source passages</h2>"
        for span in record.evidenceSpans {
            output += "<article id=\"passage-\(span.id.uuidString)\"><h3>\(timestamp(span.start)) · \(htmlEscape(span.speaker))</h3>"
            if span.suppressed { output += "<p>Suppressed echo passage retained as original evidence.</p>" }
            output += "<p>\(htmlEscape(span.text))</p></article>"
        }
        return output + "</main></html>"
    }
}
#endif
