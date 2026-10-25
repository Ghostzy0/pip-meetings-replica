#if PIP_EDITION
@testable import MeetingTranscriber
import Foundation
import XCTest

@MainActor
final class PipMeetingLibraryTests: XCTestCase {
    func testMissingRootWithoutDirectoryHintCanCreateAndReopen() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = URL(fileURLWithPath: parent.appendingPathComponent("NewLibrary").path)
        let library = try PipMeetingLibrary(root: root)
        let id = try library.create(title: "New root")
        XCTAssertEqual(try PipMeetingLibrary(root: root).meetings.first?.id, id)
    }

    func testMissingPrivateTmpRootCanCreateAndReopen() throws {
        let parent = URL(fileURLWithPath: "/private/tmp/pip-meetings-missing-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("pip-library", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        let library = try PipMeetingLibrary(root: root)
        let id: UUID
        do {
            id = try library.create(title: "Private tmp root")
        } catch {
            XCTFail("A newly created private-tmp library should accept its first meeting: \(error)")
            return
        }
        XCTAssertEqual(try PipMeetingLibrary(root: root).meetings.first?.id, id)
    }

    func testSymlinkedLibraryRootIsRejectedWithoutTouchingTarget() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("pip-meetings-root-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = parent.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let targetModeBefore = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue
        ) & 0o777
        let sentinel = target.appendingPathComponent("sentinel")
        try Data("preserve".utf8).write(to: sentinel)
        let link = parent.appendingPathComponent("linked-library", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try PipMeetingLibrary(root: link)) { error in
            XCTAssertEqual(error as? PipMeetingLibraryError, .unsafePath)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), ["sentinel"])
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "preserve")
        let targetModeAfter = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue
        ) & 0o777
        XCTAssertEqual(targetModeAfter, targetModeBefore)
    }

    func testDanglingSymlinkedLibraryRootDoesNotCreateTarget() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("pip-meetings-dangling-root-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let missingTarget = parent.appendingPathComponent("missing-target", isDirectory: true)
        let link = parent.appendingPathComponent("dangling-library", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missingTarget)
        _ = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingTarget.path))

        XCTAssertThrowsError(try PipMeetingLibrary(root: link))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingTarget.path))
    }

    func testCRUDSearchAndFreshInstanceReopen() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let library = try fixture.library()
        let id = try library.create(title: "Friday launch")
        try library.update(id: id, notes: "Morgan checks screenshots", transcript: "Edited words")
        let decision = try library.addDecision(meetingID: id, kind: .action, text: "Review by Thursday")
        try library.updateDecision(meetingID: id, decisionID: decision, complete: true)
        let reopened = try fixture.library()
        XCTAssertEqual(reopened.meetings.first?.notes, "Morgan checks screenshots")
        XCTAssertEqual(reopened.meetings.first?.transcript, "Edited words")
        XCTAssertEqual(reopened.meetings.first?.decisions.first?.complete, true)
        XCTAssertEqual(reopened.filtered("THURSDAY").map(\.id), [id])
        XCTAssertTrue(reopened.filtered("unrelated").isEmpty)
        try reopened.removeDecision(meetingID: id, decisionID: decision)
        XCTAssertTrue(try fixture.library().meetings[0].decisions.isEmpty)
    }

    func testOpenActionsFiltersAndOrdersByMeetingThenInsertionAfterReopen() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let library = try fixture.library()
        let olderMeeting = try library.create(title: "Older meeting")
        let first = try library.addDecision(meetingID: olderMeeting, kind: .action, text: "Review the same item")
        _ = try library.addDecision(meetingID: olderMeeting, kind: .decision, text: "Approved the same item")
        let completed = try library.addDecision(meetingID: olderMeeting, kind: .action, text: "Already done")
        try library.updateDecision(meetingID: olderMeeting, decisionID: completed, complete: true)
        let newerMeeting = try library.create(title: "Newer meeting")
        let duplicateText = try library.addDecision(meetingID: newerMeeting, kind: .action, text: "Review the same item")

        let rows = library.openActions()
        XCTAssertEqual(rows.map(\.decisionID), [duplicateText, first])
        XCTAssertEqual(rows.map(\.meetingID), [newerMeeting, olderMeeting])
        XCTAssertEqual(rows.map(\.text), ["Review the same item", "Review the same item"])

        let reopened = try fixture.library()
        XCTAssertEqual(reopened.openActions().map(\.id), rows.map(\.id))
    }

    func testDecisionAndActionCanBeEditedRelinkedCompletedReopenedAndRemoved() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let library = try fixture.library()
        let job = try fixture.job()
        let meetingID = try library.ingest(job: job)
        let span = try XCTUnwrap(library.meetings.first?.currentEvidenceSpans.first)
        let itemID = try library.addDecision(meetingID: meetingID, kind: .action, text: "Check draft", spanID: span.id)
        try library.updateDecision(meetingID: meetingID, decisionID: itemID,
            text: "Review final draft", complete: true, kind: .decision)
        var saved = try XCTUnwrap(try fixture.library().meetings.first?.decisions.first)
        XCTAssertEqual(saved.text, "Review final draft")
        XCTAssertEqual(saved.kind, .decision)
        XCTAssertTrue(saved.complete)
        XCTAssertEqual(saved.spanID, span.id)

        try library.updateDecision(meetingID: meetingID, decisionID: itemID,
            text: "Review final draft", complete: false, kind: .action, replaceReference: true)
        saved = try XCTUnwrap(try fixture.library().meetings.first?.decisions.first)
        XCTAssertEqual(saved.kind, .action)
        XCTAssertFalse(saved.complete)
        XCTAssertNil(saved.spanID)
        try library.removeDecision(meetingID: meetingID, decisionID: itemID)
        XCTAssertTrue(try fixture.library().meetings.first?.decisions.isEmpty == true)
    }

    func testRawOutputIngestPreservesOriginalsAndRepeatedEdits() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let library = try fixture.library()
        let job = try fixture.job()
        let originalText = try Data(contentsOf: fixture.transcript)
        let originalSegments = try Data(contentsOf: fixture.sidecar)
        let id = try library.ingest(job: job)
        let span = try XCTUnwrap(library.meetings.first?.evidenceSpans.first)
        try library.update(id: id, title: "My title", notes: "My private notes", transcript: "My corrected transcript")
        _ = try library.addDecision(meetingID: id, kind: .decision, text: "Ship Friday", spanID: span.id)
        XCTAssertEqual(try library.ingest(job: job), id)
        let record = try XCTUnwrap(try fixture.library().meetings.first)
        XCTAssertEqual(record.sourceRevisions.count, 1)
        XCTAssertEqual(record.evidenceSpans.first?.id, span.id)
        XCTAssertEqual(record.title, "My title")
        XCTAssertEqual(record.notes, "My private notes")
        XCTAssertEqual(record.transcript, "My corrected transcript")
        XCTAssertEqual(try Data(contentsOf: fixture.transcript), originalText)
        XCTAssertEqual(try Data(contentsOf: fixture.sidecar), originalSegments)
        XCTAssertEqual(record.sourceRevisions.first?.rawSegmentsJSON, originalSegments)
    }

    func testRecordingOffsetContinuesAfterExistingMeetingEvidenceWithoutAddingWallClockGap() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let library = try fixture.library()
        let existingMeeting = try library.create(title: "Existing synthetic meeting")
        let firstJob = try fixture.job()
        _ = try library.ingest(job: firstJob,
            segments: [TimestampedSegment(start: 0, end: 8, text: "First recording", speaker: "")],
            meetingID: existingMeeting, offset: 0)
        let existing = try XCTUnwrap(library.meetings.first { $0.id == existingMeeting })
        let firstOffset = try PipCaptureSession.initialTimelineOffset(for: existing)
        XCTAssertEqual(firstOffset, 8)

        // Stop has durably closed the first clip, but ASR has not yet committed
        // it to the library. A second recording must still follow its media end.
        var pendingCapture = PipCaptureSession.Snapshot()
        pendingCapture.phase = .idle
        pendingCapture.meetingID = existingMeeting
        pendingCapture.elapsed = 13
        let pending = PipCaptureSession.Chunk(meetingID: existingMeeting, offset: 8, duration: 5)
        pendingCapture.recordings["pending-asr"] = pending
        pendingCapture.chunks[UUID().uuidString] = pending
        let secondOffset = try PipCaptureSession.initialTimelineOffset(for: existing, captureSnapshot: pendingCapture)
        XCTAssertEqual(secondOffset, 13)

        var unrelatedCapture = pendingCapture
        unrelatedCapture.meetingID = UUID()
        unrelatedCapture.elapsed = 90
        XCTAssertEqual(try PipCaptureSession.initialTimelineOffset(for: existing, captureSnapshot: unrelatedCapture), 13)

        let otherMeeting = try library.create(title: "Different recording")
        var otherSession = pendingCapture
        otherSession.meetingID = otherMeeting
        otherSession.elapsed = 2
        let otherRecord = try XCTUnwrap(library.meetings.first { $0.id == otherMeeting })
        XCTAssertEqual(try PipCaptureSession.initialTimelineOffset(for: otherRecord, captureSnapshot: otherSession), 2)

        var unknownDuration = pendingCapture
        unknownDuration.meetingID = UUID() // A remains pending after switching meetings.
        unknownDuration.recordings["unfinished"] = PipCaptureSession.Chunk(meetingID: existingMeeting, offset: 13)
        XCTAssertThrowsError(try PipCaptureSession.initialTimelineOffset(for: existing, captureSnapshot: unknownDuration))

        let secondJob = try fixture.job()
        _ = try library.ingest(job: secondJob,
            segments: [TimestampedSegment(start: 0, end: 5, text: "Pending ASR recording", speaker: "")],
            meetingID: existingMeeting, offset: secondOffset)
        let reopened = try XCTUnwrap(try fixture.library().meetings.first { $0.id == existingMeeting })
        XCTAssertEqual(try PipCaptureSession.initialTimelineOffset(for: reopened), 18)
        XCTAssertEqual(reopened.currentEvidenceSpans.map(\.start), [0, 13])
    }

    func testUpdatedSourceRevisionKeepsOldDecisionEvidence() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let library = try fixture.library()
        let job = try fixture.job()
        let id = try library.ingest(job: job)
        let oldSpan = try XCTUnwrap(library.meetings.first?.evidenceSpans.first)
        _ = try library.addDecision(meetingID: id, kind: .action, text: "Keep the promise", spanID: oldSpan.id)
        try "Corrected source output".write(to: fixture.transcript, atomically: true, encoding: .utf8)
        _ = try library.ingest(job: job)
        let record = try XCTUnwrap(library.meetings.first)
        XCTAssertEqual(record.sourceRevisions.count, 2)
        XCTAssertEqual(record.evidenceSpans.first, oldSpan)
        XCTAssertEqual(record.decisions.first?.spanID, oldSpan.id)
        XCTAssertEqual(record.transcript, "Corrected source output")
        XCTAssertEqual(record.currentEvidenceSpans.count, 1)
        XCTAssertNotEqual(record.currentEvidenceSpans.first?.id, oldSpan.id)
    }

    func testGroupedChunksRetainSourceTimesAndExplicitOffset() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let library = try fixture.library()
        let first = try fixture.job()
        let id = try library.ingest(job: first)
        var second = PipelineJob(meetingTitle: "Second chunk", appName: "Synthetic", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        second.state = .done
        _ = try library.ingest(job: second, segments: [.init(start: 2, end: 4, text: "Next chunk", speaker: "Speaker 2")], meetingID: id, offset: 30)
        let record = try XCTUnwrap(library.meetings.first)
        XCTAssertEqual(library.meetings.count, 1)
        XCTAssertEqual(record.sourceRevisions.count, 2)
        let span = try XCTUnwrap(record.currentEvidenceSpans.last)
        XCTAssertEqual(span.sourceJobID, second.id)
        XCTAssertEqual(span.sourceStart, 2)
        XCTAssertEqual(span.timelineOffset, 30)
        XCTAssertEqual(span.start, 32)
        XCTAssertEqual(span.end, 34)
        XCTAssertTrue(record.transcript.contains("Next chunk"))
    }

    func testUnknownPassageRejectedWithoutChangingSavedMeeting() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let library = try fixture.library()
        let id = try library.create()
        XCTAssertThrowsError(try library.addDecision(meetingID: id, kind: .action, text: "Invalid link", spanID: UUID()))
        XCTAssertTrue(try fixture.library().meetings[0].decisions.isEmpty)
    }

    func testCorruptRecoveryThenEditKeepsExactDamagedOriginal() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let library = try fixture.library()
        let id = try library.create(title: "Last good")
        try library.update(id: id, notes: "Second version")
        let directory = library.root.appendingPathComponent(id.uuidString)
        let primary = directory.appendingPathComponent("meeting.json")
        let corrupt = Data("{broken original bytes".utf8)
        try corrupt.write(to: primary)
        let recovered = try fixture.library()
        XCTAssertEqual(recovered.meetings.first?.notes, "")
        XCTAssertFalse(recovered.issues.isEmpty)
        XCTAssertEqual(try Data(contentsOf: primary), corrupt)
        try recovered.update(id: id, notes: "Recovered edit")
        let quarantine = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("meeting.corrupt-") }
        XCTAssertEqual(quarantine.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(quarantine.first)), corrupt)
        XCTAssertEqual(try fixture.library().meetings.first?.notes, "Recovered edit")
    }

    func testUnknownSchemaIsNeverRolledBackOrOverwrittenByIngest() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let library = try fixture.library()
        let job = try fixture.job()
        let id = try library.ingest(job: job)
        try library.update(id: id, notes: "Create a valid previous copy")
        let primary = library.root.appendingPathComponent(id.uuidString).appendingPathComponent("meeting.json")
        let future = Data(#"{"schemaVersion":99,"futureData":"preserve"}"#.utf8)
        try future.write(to: primary)
        let reopened = try fixture.library()
        XCTAssertTrue(reopened.meetings.isEmpty)
        XCTAssertFalse(reopened.issues.isEmpty)
        XCTAssertThrowsError(try reopened.ingest(job: job)) { error in
            XCTAssertEqual(error as? PipMeetingLibraryError, .unsupportedVersion)
        }
        XCTAssertEqual(try Data(contentsOf: primary), future)
    }

    func testMeetingDirectorySymlinkCannotMutateOutsideLibrary() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let library = try fixture.library()
        let id = try library.create()
        let directory = library.root.appendingPathComponent(id.uuidString)
        let outside = fixture.base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
        XCTAssertThrowsError(try library.update(id: id, notes: "Must not write"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["sentinel"])
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "untouched")
    }

    func testArchiveSymlinkAndOutsidePurgeAreRejected() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let library = try fixture.library()
        let id = try library.create()
        let outside = fixture.base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let archive = library.root.appendingPathComponent("Archived")
        try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: outside)
        XCTAssertThrowsError(try library.remove(id: id))
        XCTAssertThrowsError(try library.purgeArchived(from: outside))
        XCTAssertEqual(library.meetings.count, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testArchiveRestoreAndExplicitPurgeNeverDeletePipelineSources() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let library = try fixture.library()
        let job = try fixture.job()
        let id = try library.ingest(job: job)
        let original = try Data(contentsOf: fixture.transcript)
        let archived = try library.remove(id: id)
        XCTAssertTrue(library.meetings.isEmpty)
        XCTAssertThrowsError(try library.ingest(job: job)) { error in
            XCTAssertEqual(error as? PipMeetingLibraryError, .archivedMeeting)
        }
        XCTAssertEqual(try library.restore(from: archived), id)
        XCTAssertEqual(try library.ingest(job: job), id, "Restoring clears replay suppression")
        let secondArchive = try library.remove(id: id)
        try library.purgeArchived(from: secondArchive)
        XCTAssertTrue(try library.archivedMeetings().isEmpty)
        let reopened = try fixture.library()
        XCTAssertThrowsError(try reopened.ingest(job: job)) { error in
            XCTAssertEqual(error as? PipMeetingLibraryError, .archivedMeeting)
        }
        XCTAssertTrue(reopened.meetings.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.transcript), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sidecar.path))
    }

    func testExportsEscapeSourceAndEditedTextWithoutLoadingRemoteContent() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let library = try fixture.library()
        let job = PipelineJob(meetingTitle: "<script>bad()</script>", appName: "Synthetic", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        let id = try library.ingest(job: job, segments: [.init(start: 60, end: 62, text: "<img src=https://invalid.test/x onerror=bad()>", speaker: "A&B")])
        let spanID = try XCTUnwrap(library.meetings.first?.evidenceSpans.first?.id)
        try library.update(id: id, notes: "![remote](https://invalid.test/pixel)", transcript: "<iframe src=x>")
        _ = try library.addDecision(meetingID: id, kind: .decision, text: "Use <Friday>", spanID: spanID)
        let record = try XCTUnwrap(library.meetings.first)
        let html = PipMeetingLibrary.html(record)
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("<img"))
        XCTAssertFalse(html.contains("<iframe"))
        XCTAssertFalse(html.contains("src=\"https:"))
        XCTAssertTrue(html.contains("A&amp;B"))
        XCTAssertTrue(html.contains("href=\"#passage-\(spanID.uuidString)\""))
        let markdown = PipMeetingLibrary.markdown(record)
        XCTAssertFalse(markdown.contains("![remote]"))
        XCTAssertFalse(markdown.contains("<img"))
        XCTAssertTrue(markdown.contains("00:01:00"))
    }

    func testHugeInvalidTimesDoNotSaveAndFormatterNeverTraps() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let library = try fixture.library()
        let job = PipelineJob(meetingTitle: "Invalid", appName: "Synthetic", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        for value in [Double.nan, .infinity, -1, 1e20] {
            XCTAssertThrowsError(try library.ingest(job: job, segments: [.init(start: value, end: value, text: "Bad")]))
            XCTAssertFalse(PipMeetingLibrary.timestamp(value).isEmpty)
        }
        XCTAssertTrue(library.meetings.isEmpty)
        XCTAssertEqual(PipMeetingLibrary.timestamp(3661), "01:01:01")
    }

    func testSlugTraversalAndSourceSymlinksAreRefused() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let library = try fixture.library()
        var job = try fixture.job()
        job.namingSlug = "../../outside"
        XCTAssertThrowsError(try library.ingest(job: job))
        job.namingSlug = "synthetic"
        let actual = fixture.base.appendingPathComponent("actual.txt")
        try "source".write(to: actual, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: fixture.transcript)
        try FileManager.default.createSymbolicLink(at: fixture.transcript, withDestinationURL: actual)
        XCTAssertThrowsError(try library.ingest(job: job))
        XCTAssertEqual(try String(contentsOf: actual, encoding: .utf8), "source")
    }

    func testCorruptRetentionFailsClosedWithoutReplayingPurgedMeetings() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let library = try fixture.library()
        let job = try fixture.job()
        let id = try library.ingest(job: job)
        let archived = try library.remove(id: id)
        try library.purgeArchived(from: archived)
        let path = library.root.appendingPathComponent("retention.json")
        let damaged = Data("broken retention".utf8)
        try damaged.write(to: path)
        XCTAssertThrowsError(try fixture.library())
        XCTAssertEqual(try Data(contentsOf: path), damaged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.transcript.path))
    }

    func testFutureRetentionSchemaIsPreserved() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let library = try fixture.library()
        let path = library.root.appendingPathComponent("retention.json")
        let future = Data(#"{"schemaVersion":10,"jobs":[],"meetings":[]}"#.utf8)
        try future.write(to: path)
        XCTAssertThrowsError(try fixture.library()) { error in
            XCTAssertEqual(error as? PipMeetingLibraryError, .unsupportedVersion)
        }
        XCTAssertEqual(try Data(contentsOf: path), future)
    }

    func testDisabledAdditionalSpeechRejectsVADAndAllCaptionStrategiesBeforeModelLoad() async throws {
        let defaults = PipSpeechResources.additionalDownloadDefaults
        let key = "pipAdditionalSpeechDownloadsEnabled"
        let previous = defaults.object(forKey: key)
        defaults.set(false, forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        for language in ["en", "de", nil] as [String?] {
            XCTAssertEqual(LiveCaptionsGate.strategy(liveEnabled: true, engineLanguage: language, engineSupportsLive: true), .none)
            XCTAssertFalse(LiveCaptionsGate.overlayVisible(liveEnabled: true, engineLanguage: language,
                engineSupportsLive: true, isRecording: true, overlayEnabled: true))
        }
        do {
            _ = try await FluidVAD().detectSpeech(samples: [0, 0, 0])
            XCTFail("The resource policy must refuse before constructing a model manager")
        } catch {
            guard case PipSpeechResourceError.downloadsNotEnabled = error else {
                return XCTFail("Wrong policy error: \(error)")
            }
        }
    }

    func testRelocatedAudioReferencesPersistAfterQueueJobDisappears() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let library = try fixture.library()
        var job = try fixture.job()
        let firstAudio = fixture.output.appendingPathComponent("before-move.wav")
        let relocated = fixture.output.appendingPathComponent("final-recording.wav")
        try Data("synthetic retained audio bytes".utf8).write(to: firstAudio)
        job.recordRelocatedAudio(RelocatedAudioPaths(mix: firstAudio, app: firstAudio, mic: nil))
        let id = try library.ingest(job: job)
        XCTAssertEqual(library.meetings.first?.audioPaths, [firstAudio.standardizedFileURL])
        try FileManager.default.moveItem(at: firstAudio, to: relocated)
        job.recordRelocatedAudio(RelocatedAudioPaths(mix: relocated, app: nil, mic: nil))
        _ = try library.ingest(job: job)
        let record = try XCTUnwrap(try fixture.library().meetings.first)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.sourceRevisions.count, 2, "Relocation metadata must not be lost to text-only deduplication")
        XCTAssertEqual(record.sourceRevisions.last?.audioPaths, [relocated.standardizedFileURL])
        XCTAssertTrue(record.audioPaths.contains(relocated.standardizedFileURL))
        XCTAssertEqual(try Data(contentsOf: relocated), Data("synthetic retained audio bytes".utf8))
    }

    func testOlderSourceRevisionWithoutAudioPathsStillDecodes() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let library = try fixture.library()
        let job = try fixture.job()
        let id = try library.ingest(job: job)
        let path = library.root.appendingPathComponent(id.uuidString).appendingPathComponent("meeting.json")
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var revisions = try XCTUnwrap(document["sourceRevisions"] as? [[String: Any]])
        for index in revisions.indices { revisions[index].removeValue(forKey: "audioPaths") }
        document["sourceRevisions"] = revisions
        try JSONSerialization.data(withJSONObject: document).write(to: path)
        let reopened = try fixture.library()
        XCTAssertEqual(reopened.meetings.first?.id, id)
        XCTAssertNil(reopened.meetings.first?.sourceRevisions.first?.audioPaths)
        XCTAssertEqual(reopened.meetings.first?.audioPaths, [])
        XCTAssertTrue(reopened.issues.isEmpty)
    }

    private struct Fixture {
        let base: URL
        var root: URL { base.appendingPathComponent("library", isDirectory: true) }
        var output: URL { base.appendingPathComponent("outputs", isDirectory: true) }
        var transcript: URL { output.appendingPathComponent("synthetic.txt") }
        var sidecar: URL { output.appendingPathComponent("recordings/synthetic_segments.json") }
        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("pip-library-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: output.appendingPathComponent("recordings"), withIntermediateDirectories: true)
        }
        @MainActor func library() throws -> PipMeetingLibrary { try PipMeetingLibrary(root: root) }
        func job() throws -> PipelineJob {
            var job = PipelineJob(meetingTitle: "Synthetic Friday planning", appName: "Synthetic", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
            job.state = .done
            job.transcriptPath = transcript
            job.namingSlug = "synthetic"
            job.recordSidecarOutputDir(output)
            try "[00:00] Alex: Ship Friday".write(to: transcript, atomically: true, encoding: .utf8)
            try JSONEncoder().encode([TimestampedSegment(start: 0, end: 3, text: "Ship Friday", speaker: "Alex")]).write(to: sidecar)
            return job
        }
        func remove() { try? FileManager.default.removeItem(at: base) }
    }
}
#endif
