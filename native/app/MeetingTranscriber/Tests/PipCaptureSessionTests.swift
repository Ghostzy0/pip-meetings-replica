#if PIP_EDITION
@testable import MeetingTranscriber
import Foundation
import XCTest

@MainActor
final class PipCaptureSessionTests: XCTestCase {
    private func root() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func active(_ id: UUID, offset: TimeInterval = 0) -> PipCaptureSession.Snapshot {
        var snapshot = PipCaptureSession.Snapshot()
        snapshot.phase = .starting; snapshot.meetingID = id; snapshot.elapsed = offset
        return snapshot
    }

    func testCrashBecomesInterruptedWithoutAutomaticallyStartingCapture() {
        var original = active(UUID(), offset: 17)
        original.phase = .recording
        original.activeStartedAt = Date(timeIntervalSince1970: 1)
        let recovered = PipCaptureSession.recover(original)
        XCTAssertEqual(recovered.phase, .interrupted)
        XCTAssertNil(recovered.activeStartedAt)
        XCTAssertEqual(recovered.elapsed, 17)
    }

    func testRecordingCanAppendToTheSelectedMeetingWithoutCreatingAnother() throws {
        let directory = try root()
        let library = try PipMeetingLibrary(root: directory.appendingPathComponent("library", isDirectory: true))
        let existing = try library.create(title: "Edited notes")
        let selected = try PipCaptureSession.targetMeetingID(existing: existing, title: "Microphone meeting", library: library)
        XCTAssertEqual(selected, existing)
        XCTAssertEqual(library.meetings.map(\.id), [existing])

        let newID = try PipCaptureSession.targetMeetingID(existing: nil, title: "Microphone meeting", library: library)
        XCTAssertNotEqual(newID, existing)
        XCTAssertEqual(library.meetings.count, 2)
        XCTAssertThrowsError(try PipCaptureSession.targetMeetingID(existing: UUID(), title: "Unused", library: library))
        XCTAssertEqual(library.meetings.count, 2)
    }

    func testPreCaptureLinkSurvivesRestartAndRecoveredJobKeepsMeetingAndOffset() throws {
        let root = try root()
        let id = UUID()
        let path = root.appendingPathComponent("capture-session.json")
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        let session = PipCaptureSession(path: path, initial: active(id, offset: 23))
        try session.prepareRecording(stem: "20260101_120000_abcd", in: recordings)
        // Simulate a process crash after capture began but before any stop/enqueue.
        let reopened = PipCaptureSession(path: path)
        var recoveredJob = PipelineJob(meetingTitle: "Recovered", appName: "Synthetic",
            mixPath: recordings.appendingPathComponent("20260101_120000_abcd_mix.wav"), appPath: nil, micPath: nil, micDelay: 0)
        XCTAssertTrue(reopened.attach(to: &recoveredJob))
        XCTAssertEqual(recoveredJob.pipMeetingID, id)
        XCTAssertEqual(recoveredJob.pipTimelineOffset, 23)
        let restoredJob = try JSONDecoder().decode(PipelineJob.self, from: JSONEncoder().encode(recoveredJob))
        XCTAssertEqual(restoredJob.pipMeetingID, id)
        XCTAssertEqual(restoredJob.pipTimelineOffset, 23)
    }

    func testActualClipDurationStopsPhaseAndDoesNotCountPostStopWallTimeTwice() throws {
        let root = try root()
        let id = UUID()
        var state = active(id, offset: 30)
        state.phase = .recording
        state.activeStartedAt = Date(timeIntervalSince1970: 1)
        let session = PipCaptureSession(path: root.appendingPathComponent("capture-session.json"), initial: state)
        let completed = PipCaptureSession.Chunk(meetingID: id, offset: 30, duration: 8)
        session.completeSegment(completed)
        session.completeSegment(completed)
        XCTAssertEqual(session.phase, .paused)
        XCTAssertEqual(session.snapshot.elapsed, 38)
        XCTAssertNil(session.snapshot.activeStartedAt)
    }

    func testAssociationWriteFailureRefusesPreCaptureAdmission() throws {
        let root = try root()
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("kept".utf8).write(to: blocked)
        let session = PipCaptureSession(path: blocked.appendingPathComponent("capture-session.json"), initial: active(UUID()))
        XCTAssertThrowsError(try session.prepareRecording(stem: "first", in: blocked.appendingPathComponent("recordings", isDirectory: true)))
        XCTAssertEqual(try String(contentsOf: blocked, encoding: .utf8), "kept")
    }

    func testCorruptStateIsPreservedAndBlocksNewCapturePreparation() throws {
        let root = try root()
        let path = root.appendingPathComponent("capture-session.json")
        let original = Data("{ damaged, but preserved }".utf8)
        try original.write(to: path)
        let session = PipCaptureSession(path: path)
        XCTAssertTrue(session.storageProblem)
        XCTAssertThrowsError(try session.prepareRecording(stem: "new", in: root.appendingPathComponent("recordings", isDirectory: true)))
        XCTAssertEqual(try Data(contentsOf: path), original)
    }

    func testNativeStopWithUnreadableAssociationNeverLeavesRecordingState() throws {
        let root = try root()
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let mix = recordings.appendingPathComponent("broken_mix.wav")
        try syntheticWav(seconds: 1).write(to: mix)
        let sidecar = recordings.appendingPathComponent("broken_pip-session.json")
        try Data("broken".utf8).write(to: sidecar)
        var state = active(UUID())
        state.phase = .recording; state.activeStartedAt = Date()
        let session = PipCaptureSession(path: root.appendingPathComponent("capture-session.json"), initial: state)
        session.recordingDidStop(.init(mixPath: mix, appPath: nil, micPath: nil, micDelay: 0, recordingStartDate: Date()))
        XCTAssertEqual(session.phase, .interrupted)
        XCTAssertNil(session.snapshot.activeStartedAt)
        XCTAssertTrue(session.storageProblem)
        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), "broken")
    }

    func testResumeReconcilesActualRecoveredDurationAndRejectsPendingRawAudio() throws {
        let root = try root()
        let recordings = root.appendingPathComponent("recordings", isDirectory: true)
        let id = UUID()
        let path = root.appendingPathComponent("capture-session.json")
        let session = PipCaptureSession(path: path, initial: active(id, offset: 9))
        try session.prepareRecording(stem: "interrupted", in: recordings)
        let raw = recordings.appendingPathComponent("interrupted_app.raw")
        try Data([0, 0]).write(to: raw)
        let reopened = PipCaptureSession(path: path)
        XCTAssertThrowsError(try reopened.reconcileInterruptedSegments())
        XCTAssertEqual(reopened.snapshot.elapsed, 9)
        try syntheticWav(seconds: 2).write(to: recordings.appendingPathComponent("interrupted_mix.wav"))
        try reopened.reconcileInterruptedSegments()
        XCTAssertEqual(reopened.snapshot.elapsed, 11)
        try reopened.reconcileInterruptedSegments()
        XCTAssertEqual(reopened.snapshot.elapsed, 11)
    }

    func testCaptureAssociationRefusesSymlinkedRecordingFolder() throws {
        let directory = try root(), outside = try root()
        let recordings = directory.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: recordings, withDestinationURL: outside)
        let session = PipCaptureSession(path: directory.appendingPathComponent("capture-session.json"), initial: active(UUID()))
        XCTAssertThrowsError(try session.prepareRecording(stem: "new", in: recordings))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    private func syntheticWav(seconds: Int) -> Data {
        var data = Data()
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        let bytes = UInt32(seconds * 16_000 * 2)
        data.append(Data("RIFF".utf8)); u32(36 + bytes); data.append(Data("WAVEfmt ".utf8)); u32(16)
        u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(bytes); data.append(Data(repeating: 0, count: Int(bytes)))
        return data
    }
}
#endif
