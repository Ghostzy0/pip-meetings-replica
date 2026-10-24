#if PIP_EDITION
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PipMeetingDetail: View {
    let record: PipMeetingRecord
    let library: PipMeetingLibrary
    let canArchive: Bool
    let onArchived: () -> Void
    @State private var draft: PipMeetingDraft
    @State private var sourceID: UUID?
    @State private var showSources = true
    @State private var newItem = ""
    @State private var kind: PipMeetingDecision.Kind = .action
    @State private var feedback: String?
    @State private var archiveConfirmation = false
    @Environment(\.colorScheme) private var scheme
    private var palette: PipMeetingsPalette { PipMeetingsPalette(scheme) }
    private var changed: Bool { draft != PipMeetingDraft(record) }

    init(record: PipMeetingRecord, library: PipMeetingLibrary, canArchive: Bool, onArchived: @escaping () -> Void) {
        self.record = record; self.library = library; self.canArchive = canArchive; self.onArchived = onArchived
        _draft = State(initialValue: PipMeetingDrafts.shared.draft(for: record))
        let pending = PipMeetingDrafts.shared.pendingItem(for: record.id)
        _newItem = State(initialValue: pending.text)
        _kind = State(initialValue: pending.kind)
        _sourceID = State(initialValue: pending.spanID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PipMeetingsMetrics.section) {
                header
                if let feedback { Text(feedback).font(.system(size: 13)).foregroundStyle(palette.secondary) }
                notes
                decisions
                transcript
                sources
            }
            .frame(maxWidth: PipMeetingsMetrics.detailWidth, alignment: .leading)
            .padding(PipMeetingsMetrics.section)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onChange(of: draft) { _, next in
            if next != PipMeetingDraft(record) { PipMeetingDrafts.shared.keep(next, for: record.id) }
        }
        .onChange(of: newItem) { _, _ in keepPendingItem() }
        .onChange(of: kind) { _, _ in keepPendingItem() }
        .onChange(of: sourceID) { _, _ in keepPendingItem() }
        .onChange(of: record) { old, next in
            // A completed source import never overwrites an in-progress edit.
            if draft.title == old.title { draft.title = next.title }
            if draft.notes == old.notes { draft.notes = next.notes }
            if draft.transcript == old.transcript { draft.transcript = next.transcript }
        }
        .onDisappear { if changed { _ = save() } }
        .confirmationDialog("Archive this meeting?", isPresented: $archiveConfirmation, titleVisibility: .visible) {
            Button("Archive meeting") { archive() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The library entry remains recoverable. Original recordings and transcripts are kept separately.") }
        .accessibilityIdentifier("pip-meeting-detail")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PipMeetingsMetrics.row) {
            TextField("Meeting title", text: $draft.title)
                .font(.system(size: 24, weight: .semibold))
                .textFieldStyle(.plain)
                .accessibilityLabel("Meeting title")
            HStack(spacing: PipMeetingsMetrics.row) {
                Text(record.createdAt, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                    .font(.system(size: 13)).foregroundStyle(palette.secondary)
                Spacer()
                Button(changed ? "Save changes" : "Saved") { _ = save() }
                    .disabled(!changed)
                    .keyboardShortcut("s")
                Menu("Export") {
                    Button("Markdown") { export(html: false) }
                    Button("HTML") { export(html: true) }
                }
                Button("Archive") { archiveConfirmation = true }.disabled(!canArchive)
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: PipMeetingsMetrics.row) {
            PipSectionHeading(title: "Your notes", detail: "Write what matters. Decisions and actions stay editable below.")
            TextEditor(text: $draft.notes)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 100)
                .padding(PipMeetingsMetrics.row)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: PipMeetingsMetrics.smallRadius))
                .overlay { RoundedRectangle(cornerRadius: PipMeetingsMetrics.smallRadius).strokeBorder(palette.line) }
                .accessibilityLabel("Meeting notes")
                .accessibilityIdentifier("pip-meeting-notes")
        }
    }

    private var decisions: some View {
        VStack(alignment: .leading, spacing: PipMeetingsMetrics.row) {
            PipSectionHeading(title: "Decisions and next steps", detail: "Choose a source passage to keep an item linked to what was said.")
            if record.decisions.isEmpty { Text("No decisions or actions written yet.").foregroundStyle(palette.secondary).font(.system(size: 14)) }
            ForEach(record.decisions) { decision in
                PipDecisionEditor(decision: decision, record: record, library: library) { id in
                    sourceID = id; showSources = true
                }
            }
            HStack(alignment: .top, spacing: PipMeetingsMetrics.gap) {
                Picker("Item type", selection: $kind) {
                    Text("Action").tag(PipMeetingDecision.Kind.action)
                    Text("Decision").tag(PipMeetingDecision.Kind.decision)
                }
                .labelsHidden().frame(width: 120)
                TextField("Write an action or decision", text: $newItem, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("New action or decision")
                Button("Add", action: addItem).disabled(newItem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let source = record.evidenceSpans.first(where: { $0.id == sourceID }) {
                HStack {
                    Label("Linked to " + Self.time(source.start), systemImage: "link")
                    Text(source.text).lineLimit(2)
                    Button("Clear source") { sourceID = nil }
                }
                .font(.system(size: 12)).foregroundStyle(palette.secondary)
            } else { Text("No source passage selected. An item can also be your own note.").font(.system(size: 12)).foregroundStyle(palette.secondary) }
        }
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: PipMeetingsMetrics.row) {
            PipSectionHeading(title: "Transcript", detail: "Correct the working transcript here. Original timestamped passages remain unchanged below.")
            if draft.transcript.isEmpty {
                Text("A transcript will appear after audio is imported or a recorded segment finishes. You can also write one yourself.")
                    .font(.system(size: 13)).foregroundStyle(palette.secondary)
            }
            TextEditor(text: $draft.transcript)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 180)
                .padding(PipMeetingsMetrics.row)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: PipMeetingsMetrics.smallRadius))
                .overlay { RoundedRectangle(cornerRadius: PipMeetingsMetrics.smallRadius).strokeBorder(palette.line) }
                .accessibilityLabel("Editable meeting transcript")
                .accessibilityIdentifier("pip-meeting-transcript")
        }
    }

    private var sources: some View {
        DisclosureGroup(isExpanded: $showSources) {
            VStack(alignment: .leading, spacing: PipMeetingsMetrics.gap) {
                if record.currentEvidenceSpans.isEmpty {
                    Text("No timestamped source passages are available for this meeting yet.").foregroundStyle(palette.secondary)
                }
                if let historical = record.evidenceSpans.first(where: { $0.id == sourceID }),
                   !record.currentEvidenceSpans.contains(where: { $0.id == historical.id }) {
                    Text("Linked passage from an earlier source revision").font(.system(size: 12, weight: .medium))
                    sourceRow(historical)
                }
                ForEach(record.currentEvidenceSpans) { span in sourceRow(span) }
                ForEach(record.audioPaths.filter { FileManager.default.fileExists(atPath: $0.path) }, id: \.self) { audio in
                    Button("Show recording: " + audio.lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([audio]) }
                        .font(.system(size: 12))
                }
                ForEach(record.sourceRevisions, id: \.id) { revision in
                    if let path = revision.transcriptPath {
                        Button("Show original transcript") { NSWorkspace.shared.activateFileViewerSelecting([path]) }
                            .font(.system(size: 12))
                    }
                }
            }
            .padding(.top, PipMeetingsMetrics.row)
        } label: {
            PipSectionHeading(title: "Source passages", detail: "Timestamped recognition output. Speaker labels are estimates; check the audio for important details.")
        }
    }

    private func sourceRow(_ span: PipMeetingEvidenceSpan) -> some View {
        Button {
            sourceID = span.id
        } label: {
            VStack(alignment: .leading, spacing: PipMeetingsMetrics.tight) {
                HStack {
                    Text(Self.time(span.start) + " to " + Self.time(span.end)).monospacedDigit()
                    if !span.speaker.isEmpty { Text(span.speaker) }
                    if span.suppressed { Text("Possible duplicate") }
                    Spacer()
                    if sourceID == span.id { Image(systemName: "checkmark.circle.fill") }
                }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(palette.secondary)
                Text(span.text).font(.system(size: 14)).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(PipMeetingsMetrics.row)
            .background(sourceID == span.id ? palette.fill : palette.surface, in: RoundedRectangle(cornerRadius: PipMeetingsMetrics.smallRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Source at " + Self.time(span.start) + ": " + span.text)
        .accessibilityAddTraits(sourceID == span.id ? .isSelected : [])
    }

    private func keepPendingItem() {
        PipMeetingDrafts.shared.keepPendingItem(.init(text: newItem, kind: kind, spanID: sourceID), meetingID: record.id)
    }

    private func addItem() {
        do {
            _ = try library.addDecision(meetingID: record.id, kind: kind, text: newItem, spanID: sourceID)
            newItem = ""
            keepPendingItem()
            feedback = "Item saved with this meeting."
        } catch { feedback = "The item could not be saved. Your words are still here. Try again." }
    }

    @discardableResult private func save() -> Bool {
        do {
            try library.update(id: record.id, title: draft.title, notes: draft.notes,
                               transcript: draft.transcript == record.transcript ? nil : draft.transcript)
            PipMeetingDrafts.shared.saved(record.id)
            feedback = "Changes saved."
            return true
        } catch {
            PipMeetingDrafts.shared.keep(draft, for: record.id)
            feedback = "Changes could not be saved to the meeting. Your editing draft is kept. Try again before quitting."
            return false
        }
    }

    private func archive() {
        guard save() else { return }
        do {
            _ = try library.remove(id: record.id)
            PipMeetingDrafts.shared.saved(record.id)
            onArchived()
        } catch { feedback = "The meeting could not be archived. Its existing files are kept." }
    }

    private func export(html: Bool) {
        guard save(), let latest = library.meetings.first(where: { $0.id == record.id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = html ? [.html] : [UTType(filenameExtension: "md") ?? .plainText]
        let title = latest.title.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r")).joined(separator: "-")
        panel.nameFieldStringValue = String(title.prefix(100)) + (html ? ".html" : ".md")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = html ? PipMeetingLibrary.html(latest) : PipMeetingLibrary.markdown(latest)
            try Data(text.utf8).write(to: url, options: .atomic)
            feedback = "Meeting exported."
        } catch { feedback = "The export could not be written. Your meeting is still saved in the library." }
    }

    static func time(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0, interval < Double(Int.max) else { return "Unknown time" }
        let seconds = Int(interval)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct PipDecisionEditor: View {
    let decision: PipMeetingDecision
    let record: PipMeetingRecord
    let library: PipMeetingLibrary
    let onSource: (UUID) -> Void
    @State private var text: String
    @State private var problem: String?
    @State private var removeConfirmation = false
    @State private var wasRemoved = false
    @Environment(\.colorScheme) private var scheme

    init(decision: PipMeetingDecision, record: PipMeetingRecord, library: PipMeetingLibrary, onSource: @escaping (UUID) -> Void) {
        self.decision = decision; self.record = record; self.library = library; self.onSource = onSource
        _text = State(initialValue: PipMeetingDrafts.shared.decisionText(meetingID: record.id, decision: decision))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PipMeetingsMetrics.gap) {
            HStack(alignment: .top, spacing: PipMeetingsMetrics.gap) {
                Toggle(isOn: Binding(get: { decision.complete }, set: { value in
                    do { try library.updateDecision(meetingID: record.id, decisionID: decision.id, complete: value) }
                    catch { problem = "The completion change could not be saved. Try again." }
                })) { Text(decision.kind == .action ? "Action" : "Decision") }
                .toggleStyle(.checkbox)
                TextField("Item", text: $text, axis: .vertical).textFieldStyle(.roundedBorder).onSubmit(save)
                Button("Save", action: save).disabled(text == decision.text)
                Button { removeConfirmation = true } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Remove item")
            }
            if let span = record.evidenceSpans.first(where: { $0.id == decision.spanID }) {
                Button { onSource(span.id) } label: {
                    Label("Source " + PipMeetingDetail.time(span.start) + ": " + span.text, systemImage: "link")
                        .font(.system(size: 12)).lineLimit(2)
                }
                .buttonStyle(.plain)
            } else { Text("Your own note").font(.system(size: 12)).foregroundStyle(.secondary) }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(PipMeetingsPalette(scheme).danger) }
        }
        .padding(PipMeetingsMetrics.row)
        .background(PipMeetingsPalette(scheme).surface, in: RoundedRectangle(cornerRadius: PipMeetingsMetrics.smallRadius))
        .onChange(of: decision.text) { old, new in if text == old { text = new } }
        .onChange(of: text) { _, next in
            if next != decision.text { PipMeetingDrafts.shared.keepDecision(next, meetingID: record.id, decisionID: decision.id) }
        }
        .onDisappear { if !wasRemoved, text != decision.text { save() } }
        .confirmationDialog("Remove this item?", isPresented: $removeConfirmation, titleVisibility: .visible) {
            Button("Remove item", role: .destructive) {
                do {
                    try library.removeDecision(meetingID: record.id, decisionID: decision.id)
                    wasRemoved = true
                    PipMeetingDrafts.shared.decisionSaved(meetingID: record.id, decisionID: decision.id)
                }
                catch { problem = "The item could not be removed. Try again." }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func save() {
        do {
            try library.updateDecision(meetingID: record.id, decisionID: decision.id, text: text)
            PipMeetingDrafts.shared.decisionSaved(meetingID: record.id, decisionID: decision.id)
            problem = nil
        }
        catch { problem = "This edit could not be saved. Your words remain here. Try again." }
    }
}
#endif
