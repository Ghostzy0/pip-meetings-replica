#if PIP_EDITION
@testable import MeetingTranscriber
import Foundation
import XCTest

/// Independent round-one regressions. These express user-visible correctness,
/// rather than the current implementation's behaviour.
@MainActor
final class PipIndependentRegressionTests: XCTestCase {
    func testRevertingSourceToEarlierContentsStillUpdatesCurrentEvidence() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let library = try PipMeetingLibrary(root: base)
        let job = PipelineJob(meetingTitle: "Revision replay", appName: "Synthetic", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        let first = [TimestampedSegment(start: 0, end: 1, text: "Friday")]
        let second = [TimestampedSegment(start: 0, end: 1, text: "Thursday")]
        let id = try library.ingest(job: job, segments: first)
        let originalSpan = try XCTUnwrap(library.meetings.first?.evidenceSpans.first)
        _ = try library.addDecision(meetingID: id, kind: .decision, text: "Preserve original promise", spanID: originalSpan.id)
        _ = try library.ingest(job: job, segments: second)
        _ = try library.ingest(job: job, segments: first)
        let record = try XCTUnwrap(library.meetings.first)
        XCTAssertEqual(record.currentEvidenceSpans.first?.text, "Friday")
        XCTAssertTrue(record.transcript.contains("Friday"))
        XCTAssertFalse(record.transcript.contains("Thursday"))
        XCTAssertEqual(record.sourceRevisions.count, 3)
        XCTAssertEqual(record.decisions.first?.spanID, originalSpan.id)
        // An immediate replay of the current revision remains idempotent.
        _ = try library.ingest(job: job, segments: first)
        XCTAssertEqual(library.meetings.first?.sourceRevisions.count, 3)
    }

    func testGroupedTranscriptUsesTimelineRatherThanCompletionOrder() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let library = try PipMeetingLibrary(root: base)
        let meeting = try library.create(title: "Two chunks")
        let early = PipelineJob(meetingTitle: "First", appName: "Synthetic", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        let late = PipelineJob(meetingTitle: "Second", appName: "Synthetic", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        // Faster second job completes before the first job.
        _ = try library.ingest(job: late, segments: [.init(start: 0, end: 1, text: "Second half")], meetingID: meeting, offset: 30)
        _ = try library.ingest(job: early, segments: [.init(start: 0, end: 1, text: "First half")], meetingID: meeting, offset: 0)
        let record = try XCTUnwrap(library.meetings.first)
        XCTAssertEqual(record.currentEvidenceSpans.map(\.text), ["First half", "Second half"])
        let firstRange = try XCTUnwrap(record.transcript.range(of: "First half"))
        let secondRange = try XCTUnwrap(record.transcript.range(of: "Second half"))
        XCTAssertLessThan(firstRange.lowerBound, secondRange.lowerBound)
        let reopened = try PipMeetingLibrary(root: base)
        XCTAssertEqual(reopened.meetings.first?.currentEvidenceSpans.map(\.text), ["First half", "Second half"])
    }
}
#endif
