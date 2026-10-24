#if PIP_EDITION
import Foundation
import Observation

struct PipMeetingDraft: Codable, Equatable {
    var title: String
    var notes: String
    var transcript: String
    init(_ record: PipMeetingRecord) { title = record.title; notes = record.notes; transcript = record.transcript }
}

/// Edits remain available across detail selection and failed library saves.
/// A separate recovery draft is removed only after the library commit succeeds.
@Observable @MainActor
final class PipMeetingDrafts {
    static let shared = PipMeetingDrafts()
    struct PendingItem: Codable, Equatable {
        var text = ""
        var kind: PipMeetingDecision.Kind = .action
        var spanID: UUID?
    }
    private struct Envelope: Codable {
        var version = 1
        var drafts: [String: PipMeetingDraft]
        var decisions: [String: String]? = nil
        var pendingItems: [String: PendingItem]? = nil
    }
    private var drafts: [String: PipMeetingDraft] = [:]
    private var decisions: [String: String] = [:]
    private var pendingItems: [String: PendingItem] = [:]
    private(set) var problem: String?
    private let path: URL
    private var canWrite = true

    init(path: URL = AppPaths.dataDir.appendingPathComponent("editing-drafts.json")) {
        self.path = path
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        do {
            let attrs = try path.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            guard attrs.isSymbolicLink != true, (attrs.fileSize ?? .max) <= 64 * 1024 * 1024 else { throw PipMeetingLibraryError.invalidDocument }
            let stored = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: path))
            guard stored.version == 1 else { throw PipMeetingLibraryError.unsupportedVersion }
            drafts = stored.drafts
            decisions = stored.decisions ?? [:]
            pendingItems = stored.pendingItems ?? [:]
        } catch {
            canWrite = false
            problem = "Earlier editing drafts could not be read. Their file is kept. New edits stay in this window until saved."
        }
    }

    func draft(for record: PipMeetingRecord) -> PipMeetingDraft { drafts[record.id.uuidString] ?? PipMeetingDraft(record) }

    func keep(_ draft: PipMeetingDraft, for id: UUID) {
        drafts[id.uuidString] = draft
        write()
    }

    func saved(_ id: UUID) {
        drafts.removeValue(forKey: id.uuidString)
        write()
    }

    func decisionText(meetingID: UUID, decision: PipMeetingDecision) -> String {
        decisions[meetingID.uuidString + "." + decision.id.uuidString] ?? decision.text
    }

    func keepDecision(_ text: String, meetingID: UUID, decisionID: UUID) {
        decisions[meetingID.uuidString + "." + decisionID.uuidString] = text
        write()
    }

    func decisionSaved(meetingID: UUID, decisionID: UUID) {
        decisions.removeValue(forKey: meetingID.uuidString + "." + decisionID.uuidString)
        write()
    }

    func pendingItem(for id: UUID) -> PendingItem { pendingItems[id.uuidString] ?? PendingItem() }

    func keepPendingItem(_ item: PendingItem, meetingID: UUID) {
        if item.text.isEmpty { pendingItems.removeValue(forKey: meetingID.uuidString) }
        else { pendingItems[meetingID.uuidString] = item }
        write()
    }

    private func write() {
        guard canWrite else { return }
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(Envelope(drafts: drafts, decisions: decisions, pendingItems: pendingItems)).write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            problem = nil
        } catch { problem = "An editing draft could not be saved to disk. It remains in this app session. Save the meeting before quitting." }
    }
}
#endif
