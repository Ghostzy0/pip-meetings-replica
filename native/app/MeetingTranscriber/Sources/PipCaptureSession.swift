#if PIP_EDITION
import AppKit
import AVFoundation
import Foundation
import Observation

/// Pause closes the active native recording safely. Resume creates another
/// upstream capture segment in the same meeting, excluding the paused gap.
@Observable @MainActor
final class PipCaptureSession {
    enum Phase: String, Codable { case idle, starting, recording, paused, interrupted, failed }
    struct Chunk: Codable, Equatable {
        let meetingID: UUID
        let offset: TimeInterval
        var duration: TimeInterval? = nil
    }
    private struct Association: Codable { var version = 1; var chunk: Chunk }
    struct Source: Codable, Equatable {
        let pid: Int32?
        let appName: String
        let title: String
        let executable: URL?
        var request: ManualRecordingRequest {
            if let pid { return .app(pid: pid, appName: appName, title: title) }
            return .microphone
        }
        @MainActor var isAvailable: Bool {
            guard let pid else { return true }
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
            return app.executableURL == executable
        }
    }
    struct Snapshot: Codable, Equatable {
        var formatVersion = 1
        var phase: Phase = .idle
        var meetingID: UUID?
        var source: Source?
        var elapsed: TimeInterval = 0
        var activeStartedAt: Date?
        var chunks: [String: Chunk] = [:]
        var recordings: [String: Chunk] = [:]
    }
    static let shared = PipCaptureSession()
    private(set) var snapshot: Snapshot
    private(set) var message: String?
    private let path: URL
    private(set) var storageProblem = false
    private var recordingsRoot: URL { path.deletingLastPathComponent().appendingPathComponent("recordings", isDirectory: true) }
    var phase: Phase { snapshot.phase }
    var meetingID: UUID? { snapshot.meetingID }
    var hasSession: Bool { [.starting, .recording, .paused, .interrupted].contains(phase) }
    var isBusy: Bool { phase == .starting }

    init(path: URL = AppPaths.dataDir.appendingPathComponent("capture-session.json"), initial: Snapshot? = nil) {
        self.path = path
        if let initial { snapshot = initial; return }
        guard FileManager.default.fileExists(atPath: path.path) else { snapshot = Snapshot(); return }
        do {
            let values = try path.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true, (values.fileSize ?? .max) < 8 * 1024 * 1024 else { throw PipMeetingLibraryError.invalidDocument }
            let stored = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: path))
            guard stored.formatVersion == 1, stored.elapsed.isFinite, stored.elapsed >= 0 else { throw PipMeetingLibraryError.unsupportedVersion }
            snapshot = Self.recover(stored)
            if snapshot.phase == .interrupted { message = "The previous recording was interrupted. Saved audio is kept. Review it before resuming." }
        } catch {
            snapshot = Snapshot()
            snapshot.phase = .failed
            storageProblem = true
            message = "The recording state could not be read safely. Its original file is kept. Open the app folder before starting another recording."
        }
    }

    nonisolated static func recover(_ stored: Snapshot) -> Snapshot {
        var next = stored
        if stored.phase == .recording || stored.phase == .starting {
            next.phase = .interrupted
            next.activeStartedAt = nil
        }
        return next
    }

    func chunk(for jobID: UUID) -> Chunk? { snapshot.chunks[jobID.uuidString] }

    /// This link is written before capture opens. A failed write refuses capture,
    /// so interrupted recordings never depend on a later Stop button to be grouped.
    func prepareRecording(stem: String, in directory: URL) throws {
        guard !storageProblem, [.starting, .recording].contains(phase), let id = snapshot.meetingID,
              directory.standardizedFileURL == recordingsRoot.standardizedFileURL,
              !stem.contains("/"), !stem.contains("..") else { throw PipMeetingLibraryError.invalidDocument }
        let chunk = Chunk(meetingID: id, offset: snapshot.elapsed)
        try writeAssociation(chunk, stem: stem)
        snapshot.recordings[stem] = chunk
        try persist()
    }

    /// All admissions, including orphan recovery, copy the durable link into the
    /// persisted job before audio may move out of staging. Unsafe links refuse
    /// admission and leave the source recording in place.
    func attach(to job: inout PipelineJob) -> Bool {
        if job.pipMeetingID != nil { return true }
        for audio in [job.mixPath, job.appPath, job.micPath].compactMap({ $0 }) {
            guard audio.deletingLastPathComponent().standardizedFileURL == recordingsRoot.standardizedFileURL,
                  let stem = RecordingFileSuffix.stripSuffix(from: audio.lastPathComponent)?.stem else { continue }
            let file = associationURL(stem)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do {
                var chunk = try readAssociation(stem)
                if chunk.duration == nil, let duration = Self.audioDuration(audio) {
                    chunk.duration = duration
                    try writeAssociation(chunk, stem: stem)
                }
                job.pipMeetingID = chunk.meetingID
                job.pipTimelineOffset = chunk.offset
                snapshot.chunks[job.id.uuidString] = chunk
                snapshot.recordings[stem] = chunk
                if chunk.meetingID == snapshot.meetingID, let duration = chunk.duration {
                    snapshot.elapsed = max(snapshot.elapsed, chunk.offset + duration)
                }
                // The job fields + per-recording sidecar are the durable source
                // even if this convenience session-index write later fails.
                persistOrReport()
                return true
            } catch {
                message = "A saved recording could not be queued because its meeting link is unreadable. Its audio is kept. Open the app folder to review it."
                return false
            }
        }
        return true // Explicit imported files need no recording-session link.
    }

    func recordingDidStop(_ recording: RecordingResult) {
        guard let stem = RecordingFileSuffix.stripSuffix(from: recording.mixPath.lastPathComponent)?.stem,
              let duration = Self.audioDuration(recording.mixPath) else {
            recordingDidFail()
            return
        }
        do {
            var chunk = try readAssociation(stem)
            chunk.duration = duration
            try writeAssociation(chunk, stem: stem)
            completeSegment(chunk)
        } catch {
            snapshot.phase = .interrupted
            snapshot.activeStartedAt = nil
            storageProblem = true
            message = "The completed audio is kept, but its meeting link could not be updated. Review the app folder before resuming."
        }
    }

    func completeSegment(_ chunk: Chunk) {
        guard chunk.meetingID == snapshot.meetingID, let duration = chunk.duration,
              duration.isFinite, duration >= 0 else { return }
        snapshot.elapsed = max(snapshot.elapsed, chunk.offset + duration)
        snapshot.activeStartedAt = nil
        snapshot.phase = .paused
        message = "Audio capture has stopped. The completed segment is being saved."
        persistOrReport()
    }

    func recordingDidFail() {
        snapshot.phase = .interrupted
        snapshot.activeStartedAt = nil
        message = "Audio capture has stopped with a problem. Existing audio is kept for recovery. Review it before resuming."
        persistOrReport()
    }

    private func associationURL(_ stem: String) -> URL { recordingsRoot.appendingPathComponent(stem + "_pip-session.json") }

    private func readAssociation(_ stem: String) throws -> Chunk {
        try requireSafeRecordingsDirectory()
        let file = associationURL(stem)
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? .max) < 4096 else { throw PipMeetingLibraryError.invalidDocument }
        let stored = try JSONDecoder().decode(Association.self, from: Data(contentsOf: file))
        guard stored.version == 1, stored.chunk.offset.isFinite, stored.chunk.offset >= 0,
              stored.chunk.duration.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw PipMeetingLibraryError.invalidDocument }
        return stored.chunk
    }

    private func requireSafeRecordingsDirectory() throws {
        if FileManager.default.fileExists(atPath: recordingsRoot.path),
           try recordingsRoot.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw PipMeetingLibraryError.unsafePath
        }
    }

    private func writeAssociation(_ chunk: Chunk, stem: String) throws {
        try requireSafeRecordingsDirectory()
        let file = associationURL(stem)
        if FileManager.default.fileExists(atPath: file.path),
           try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw PipMeetingLibraryError.unsafePath }
        try FileManager.default.createDirectory(at: recordingsRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Association(chunk: chunk)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    nonisolated static func audioDuration(_ url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        return duration.isFinite && duration >= 0 ? duration : nil
    }

    func start(appState: AppState, request: ManualRecordingRequest, meetingID: UUID? = nil) async {
        guard !storageProblem, !hasSession, !appState.watching.isManualRecording else { return }
        if case .microphone = request, appState.settings.noMic {
            message = "Microphone recording is turned off in Audio settings. Choose app audio or change that setting."
            return
        }
        do {
            guard let library = PipLibraryBridge.shared.library else { throw PipMeetingLibraryError.invalidDocument }
            let source: Source
            switch request {
            case let .app(pid, appName, title):
                source = Source(pid: pid, appName: appName, title: title, executable: NSRunningApplication(processIdentifier: pid)?.executableURL)
            case .microphone:
                source = Source(pid: nil, appName: "Microphone", title: "Meeting " + Date.now.formatted(date: .abbreviated, time: .shortened), executable: nil)
            }
            if let meetingID {
                guard let existing = library.meetings.first(where: { $0.id == meetingID }) else {
                    throw PipMeetingLibraryError.missingMeeting
                }
                let offset = try Self.initialTimelineOffset(for: existing, captureSnapshot: snapshot)
                snapshot.meetingID = existing.id
                snapshot.elapsed = offset
            } else {
                snapshot.meetingID = try Self.targetMeetingID(existing: nil, title: source.title, library: library)
                snapshot.elapsed = 0
            }
            snapshot.source = source
            snapshot.phase = .starting
            message = nil
            try persist()
            await begin(appState: appState)
        } catch let error as PipMeetingLibraryError {
            snapshot.phase = .failed
            message = error == .invalidDocument
                ? "The previous audio length could not be verified. No new recording was started; saved audio is kept."
                : error.localizedDescription
            persistOrReport()
        } catch {
            snapshot.phase = .failed
            message = "The recording could not start. Your existing meetings are kept. Check permissions and try again."
            persistOrReport()
        }
    }

    static func targetMeetingID(existing id: UUID?, title: String, library: PipMeetingLibrary) throws -> UUID {
        if let id {
            guard library.meetings.contains(where: { $0.id == id }) else { throw PipMeetingLibraryError.missingMeeting }
            return id
        }
        return try library.create(title: title)
    }

    static func initialTimelineOffset(for record: PipMeetingRecord?, captureSnapshot: Snapshot? = nil) throws -> TimeInterval {
        guard let record else { return 0 }
        var end = record.timelineEnd(audioDuration: Self.audioDuration)
        guard let captureSnapshot else { return end }
        if captureSnapshot.meetingID == record.id {
            end = max(end, captureSnapshot.elapsed)
        }
        let chunks = Array(captureSnapshot.chunks.values) + Array(captureSnapshot.recordings.values)
        for chunk in chunks where chunk.meetingID == record.id {
            guard let duration = chunk.duration, duration.isFinite, duration >= 0,
                  chunk.offset.isFinite, chunk.offset >= 0 else {
                // ASR may still be pending after Stop. Only a known media end
                // can safely seed another recording on this timeline.
                throw PipMeetingLibraryError.invalidDocument
            }
            end = max(end, chunk.offset + duration)
        }
        guard end.isFinite, end >= 0 else { throw PipMeetingLibraryError.invalidDocument }
        return end
    }

    func resume(appState: AppState) async {
        guard !storageProblem, phase == .paused || phase == .interrupted else { return }
        do {
            try reconcileInterruptedSegments()
            snapshot.phase = .starting
            message = nil
            try persist()
            await begin(appState: appState)
        } catch {
            snapshot.phase = .interrupted
            snapshot.activeStartedAt = nil
            message = "Saved audio is still awaiting recovery or its meeting state could not be saved. Review the recording queue before resuming."
        }
    }

    /// A crash may leave the last segment awaiting the upstream recovery pass.
    /// Refuse resume until its actual audio duration is known, so another chunk
    /// cannot silently overlap that segment on the meeting timeline.
    func reconcileInterruptedSegments() throws {
        for (stem, stored) in snapshot.recordings where stored.meetingID == snapshot.meetingID {
            var chunk = try readAssociation(stem)
            if chunk.duration == nil {
                let mix = recordingsRoot.appendingPathComponent(stem + "_mix.wav")
                if let duration = Self.audioDuration(mix) {
                    chunk.duration = duration
                } else {
                    let files = try FileManager.default.contentsOfDirectory(at: recordingsRoot, includingPropertiesForKeys: nil)
                    let hasPendingAudio = files.contains {
                        $0.lastPathComponent.hasPrefix(stem + "_") && $0.pathExtension != "json"
                    }
                    guard !hasPendingAudio else { throw PipMeetingLibraryError.invalidDocument }
                    chunk.duration = 0 // Capture was refused before creating audio.
                }
                try writeAssociation(chunk, stem: stem)
            }
            snapshot.recordings[stem] = chunk
            snapshot.elapsed = max(snapshot.elapsed, chunk.offset + (chunk.duration ?? 0))
        }
        try persist()
    }

    private func begin(appState: AppState) async {
        guard let source = snapshot.source, source.isAvailable else {
            snapshot.phase = .paused
            message = "The selected app is no longer available. Stop this meeting and choose the app again."
            persistOrReport()
            return
        }
        guard let start = appState.watching.beginManualRecording(source.request) else {
            snapshot.phase = .failed
            message = "Another recording is already active. Stop it before starting this meeting."
            persistOrReport()
            return
        }
        switch await start.value {
        case .started:
            if appState.watching.watchLoop?.state == .recording {
                snapshot.phase = .recording
                snapshot.activeStartedAt = Date()
                message = nil
            } else {
                snapshot.phase = .paused
                message = "The selected recording ended before it could continue. Saved audio is kept."
            }
        case .permissionRefused:
            snapshot.phase = .paused
            message = "Recording access is required. Open Settings to grant the selected source, then resume."
        case .failed, .blockedByActiveRecording:
            snapshot.phase = .paused
            message = "Recording did not start. Check the selected source and try again."
        }
        persistOrReport()
    }

    func pause(appState: AppState) {
        guard phase == .recording else { return }
        // The native stop callback records the actual audio duration before
        // synchronous queue admission attaches the durable meeting link.
        let chunksBeforeStop = snapshot.chunks.count
        appState.watching.stopManualRecording()
        snapshot.activeStartedAt = nil
        if snapshot.phase == .recording { snapshot.phase = .interrupted }
        message = snapshot.chunks.count > chunksBeforeStop
            ? "Paused. The completed segment is queued and no new audio is being captured."
            : "Paused. No completed segment was queued. Check recording access and the saved audio."
        persistOrReport()
    }

    func stop(appState: AppState) {
        guard !storageProblem, !isBusy else { return }
        if phase == .recording { pause(appState: appState) }
        snapshot.phase = .idle
        snapshot.activeStartedAt = nil
        message = "Recording stopped. Review the saved segments and any recording errors below."
        persistOrReport()
    }

    private func persistOrReport() {
        do { try persist() }
        catch { message = "The recording state could not be saved. Keep this window open. Existing audio and meetings are kept." }
    }

    private func persist() throws {
        guard !storageProblem else { throw PipMeetingLibraryError.invalidDocument }
        if FileManager.default.fileExists(atPath: path.path),
           try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw PipMeetingLibraryError.unsafePath }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(snapshot).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}
#endif
