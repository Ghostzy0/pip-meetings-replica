#if PIP_EDITION
@testable import MeetingTranscriber
import Foundation
import XCTest

@MainActor
final class PipMeetingDraftsTests: XCTestCase {
    func testUnsavedDecisionAndPendingItemSurviveReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("drafts.json")
        let meetingID = UUID(), decisionID = UUID(), spanID = UUID()
        let drafts = PipMeetingDrafts(path: path)
        drafts.keepDecision("Still editing", meetingID: meetingID, decisionID: decisionID)
        drafts.keepPendingItem(.init(text: "Unsubmitted decision", kind: .decision, spanID: spanID), meetingID: meetingID)
        let reopened = PipMeetingDrafts(path: path)
        let decision = try JSONDecoder().decode(PipMeetingDecision.self, from: JSONSerialization.data(withJSONObject: [
            "id": decisionID.uuidString, "kind": "action", "text": "Earlier saved text", "complete": false
        ]))
        XCTAssertEqual(reopened.decisionText(meetingID: meetingID, decision: decision), "Still editing")
        let pending = reopened.pendingItem(for: meetingID)
        XCTAssertEqual(pending.text, "Unsubmitted decision")
        XCTAssertEqual(pending.kind, .decision)
        XCTAssertEqual(pending.spanID, spanID)
        // Successful addition clears the input recovery draft, not other edits.
        reopened.keepPendingItem(.init(), meetingID: meetingID)
        XCTAssertEqual(PipMeetingDrafts(path: path).pendingItem(for: meetingID).text, "")
    }

    func testUnreadableDraftFileIsPreservedWhileNewDraftStaysInMemory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("drafts.json")
        let original = Data("{ damaged, kept }".utf8)
        try original.write(to: path)
        let id = UUID()
        let drafts = PipMeetingDrafts(path: path)
        drafts.keepPendingItem(.init(text: "Retained in memory"), meetingID: id)
        XCTAssertNotNil(drafts.problem)
        XCTAssertEqual(drafts.pendingItem(for: id).text, "Retained in memory")
        XCTAssertEqual(try Data(contentsOf: path), original)
    }
}
#endif
