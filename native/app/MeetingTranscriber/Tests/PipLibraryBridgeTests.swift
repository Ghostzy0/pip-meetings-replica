#if PIP_EDITION
@testable import MeetingTranscriber
import Foundation
import XCTest

@MainActor
final class PipLibraryBridgeTests: XCTestCase {
    func testFailedLibraryWriteIsRetriedOnFreshLaunchAfterQueueJobIsGone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("library", isDirectory: true)
        let pendingRoot = root.appendingPathComponent("pending", isDirectory: true)
        let bridge = PipLibraryBridge(libraryRoot: libraryRoot, pendingRoot: pendingRoot)
        let transcript = root.appendingPathComponent("source.txt")
        try "Retained source words".write(to: transcript, atomically: true, encoding: .utf8)
        var job = PipelineJob(meetingTitle: "Retry meeting", appName: "Synthetic", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        job.state = .done; job.transcriptPath = transcript
        let brokenRetention = libraryRoot.appendingPathComponent("retention.json")
        try Data("broken".utf8).write(to: brokenRetention)
        XCTAssertTrue(bridge.ingest(job), "A durable retry permits queue cleanup")
        XCTAssertEqual(bridge.pendingCount, 1)
        XCTAssertTrue(bridge.library?.meetings.isEmpty == true)
        let journal = pendingRoot.appendingPathComponent(job.id.uuidString + ".json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
        let pendingPermissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: pendingRoot.path)[.posixPermissions] as? NSNumber).intValue
        let journalPermissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: journal.path)[.posixPermissions] as? NSNumber).intValue
        XCTAssertEqual(pendingPermissions & 0o777, 0o700)
        XCTAssertEqual(journalPermissions & 0o777, 0o600)
        try FileManager.default.removeItem(at: brokenRetention)
        let relaunched = PipLibraryBridge(libraryRoot: libraryRoot, pendingRoot: pendingRoot)
        XCTAssertEqual(relaunched.pendingCount, 0)
        XCTAssertEqual(relaunched.library?.meetings.first?.transcript, "Retained source words")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertEqual(try String(contentsOf: transcript, encoding: .utf8), "Retained source words")
        relaunched.reload()
        XCTAssertEqual(relaunched.library?.meetings.count, 1)
    }

    func testFailureOfLibraryAndRetryJournalRefusesSilentQueueCompletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryRoot = root.appendingPathComponent("library", isDirectory: true)
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: blocked)
        let bridge = PipLibraryBridge(libraryRoot: libraryRoot, pendingRoot: blocked)
        try Data("broken".utf8).write(to: libraryRoot.appendingPathComponent("retention.json"))
        let transcript = root.appendingPathComponent("source.txt")
        try "Original".write(to: transcript, atomically: true, encoding: .utf8)
        var job = PipelineJob(meetingTitle: "Failure", appName: "Synthetic", mixPath: nil, appPath: nil, micPath: nil, micDelay: 0)
        job.transcriptPath = transcript
        XCTAssertFalse(bridge.ingest(job))
        XCTAssertNotNil(bridge.problem)
        XCTAssertEqual(try String(contentsOf: blocked, encoding: .utf8), "keep")
    }
}
#endif
