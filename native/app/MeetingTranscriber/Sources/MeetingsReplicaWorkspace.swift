#if MEETINGS_REPLICA
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Neutral Core's reference-informed layout. Product behavior remains local:
/// no calendar, cloud assistant, or generated “enhanced notes” are implied.
struct MeetingsReplicaWorkspace: View {
    let appState: AppState
    let onRecordApp: (UUID) -> Void
    let onImport: () -> Void
    let onSettings: () -> Void

    @State private var bridge = PipLibraryBridge.shared
    @State private var capture = PipCaptureSession.shared
    @State private var query = ""
    @State private var selectedID: UUID?
    @State private var showSidebar = false
    @State private var showSearch = false
    @State private var showArchived = false
    @State private var archivedItems: [URL] = []
    @State private var status: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var records: [PipMeetingRecord] { bridge.library?.filtered(query) ?? [] }
    private var selected: PipMeetingRecord? { bridge.library?.meetings.first { $0.id == selectedID } }
    private var canvas: Color { Color(nsColor: .windowBackgroundColor) }
    private var secondary: Color { Color.secondary }
    private var divider: Color { Color(nsColor: .separatorColor) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                if let selected, let library = bridge.library {
                    MeetingsReplicaDetail(
                        record: selected,
                        library: library,
                        capture: capture,
                        appState: appState,
                        onBack: { selectedID = nil },
                        onRecordApp: onRecordApp,
                        onImport: onImport,
                        onSettings: onSettings,
                        onArchived: { selectedID = nil },
                        onStatus: { status = $0 }
                    )
                    .id(selected.id)
                } else {
                    home
                }

                if showSidebar && proxy.size.width > 720 {
                    sidebar
                        .frame(width: min(280, proxy.size.width * 0.38))
                        .transition(reduceMotion ? .identity : .move(edge: .leading))
                        .zIndex(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(canvas)
            .overlay(alignment: .bottom) {
                if let status {
                    HStack(spacing: 10) {
                        Text(status).font(.system(size: 12))
                        Button { self.status = nil } label: { Image(systemName: "xmark") }
                            .accessibilityLabel("Dismiss message")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: showSidebar)
        }
        .frame(minWidth: 480, minHeight: 560)
        .onChange(of: capture.meetingID) { _, id in if let id { selectedID = id } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            capture.stop(appState: appState)
        }
        .sheet(isPresented: $showArchived) { archiveSheet }
        .accessibilityIdentifier("meetings-replica-workspace")
    }

    private var home: some View {
        VStack(spacing: 0) {
            homeToolbar
            if showSearch {
                TextField("Search local meeting notes", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search local meeting notes")
                    .padding(.horizontal, 24).padding(.top, 12)
                    .frame(maxWidth: 720)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Coming up")
                        .font(.system(size: 32, weight: .regular, design: .serif))
                        .accessibilityAddTraits(.isHeader)
                    calendarUnavailableCard
                    if records.isEmpty {
                        Text(query.isEmpty ? "Your notes will live here." : "No local notes match this search.")
                            .font(.system(size: 16))
                            .foregroundStyle(secondary)
                            .frame(maxWidth: .infinity, minHeight: 140)
                    } else {
                        meetingRecords
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 24).padding(.vertical, 34)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private var homeToolbar: some View {
        HStack(spacing: 10) {
            Button { showSidebar.toggle() } label: { Image(systemName: "sidebar.left") }
                .help("Show local meetings")
                .accessibilityLabel(showSidebar ? "Hide local meetings" : "Show local meetings")
            Button { showSearch.toggle(); if !showSearch { query = "" } } label: { Image(systemName: "magnifyingglass") }
                .help("Search local meetings")
                .accessibilityLabel("Search local meetings")
                .keyboardShortcut("f", modifiers: [.command])
            Spacer()
            Button(action: createNote) { Label("New note", systemImage: "plus") }
                .keyboardShortcut("n", modifiers: [.command])
                .buttonStyle(.bordered)
                .accessibilityIdentifier("replica-new-note")
            Menu {
                Button("Import audio…", systemImage: "waveform.badge.plus", action: onImport)
                Button("Archived meetings…", systemImage: "archivebox") { loadArchive() }
                Button("Settings…", systemImage: "gearshape", action: onSettings)
            } label: {
                Image(systemName: "ellipsis").frame(width: 30, height: 30)
            }
            .accessibilityLabel("More meeting options")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(divider).frame(height: 0.5) }
    }

    private var meetingRecords: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your meetings").font(.system(size: 18, weight: .medium, design: .serif))
            ForEach(records) { record in
                Button { selectedID = record.id } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.title.isEmpty ? "Untitled meeting" : record.title)
                                .font(.system(size: 15, weight: .medium))
                            Text(record.updatedAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                                .font(.system(size: 12)).foregroundStyle(secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium)).foregroundStyle(secondary)
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHint("Open local meeting notes")
            }
        }
    }


    private var calendarUnavailableCard: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Date.now, format: .dateTime.day())
                    .font(.system(size: 42, weight: .regular, design: .serif))
                Text(Date.now, format: .dateTime.month(.wide).weekday(.wide))
                    .font(.system(size: 12)).foregroundStyle(secondary)
            }
            .frame(width: 100, alignment: .leading)
            Rectangle().fill(divider).frame(width: 0.5)
            VStack(alignment: .leading, spacing: 8) {
                Label("Calendar events are unavailable", systemImage: "calendar.badge.exclamationmark")
                    .font(.system(size: 14, weight: .medium))
                Text("This local build does not connect to a calendar.")
                    .font(.system(size: 12)).foregroundStyle(secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(divider.opacity(0.6)) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Local meetings").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button { showSidebar = false } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close local meetings")
            }
            TextField("Search", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search local meetings")
            if records.isEmpty {
                Text(query.isEmpty ? "No saved meetings yet." : "No matches.")
                    .font(.system(size: 13)).foregroundStyle(secondary).padding(.vertical, 8)
            }
            List {
                ForEach(records) { record in
                    Button { selectedID = record.id } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.title.isEmpty ? "Untitled meeting" : record.title).lineLimit(2)
                            Text(record.updatedAt, format: .dateTime.day().month(.abbreviated))
                                .font(.system(size: 11)).foregroundStyle(secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)
            Button("Import audio…", systemImage: "waveform.badge.plus", action: onImport)
                .keyboardShortcut("o", modifiers: [.command])
            Button("Archived meetings…", systemImage: "archivebox") { loadArchive() }
            Button("Settings…", systemImage: "gearshape", action: onSettings)
                .keyboardShortcut(",", modifiers: [.command])
            Text("Stored on this Mac").font(.system(size: 11)).foregroundStyle(secondary)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .trailing) { Rectangle().fill(divider).frame(width: 0.5) }
    }

    private var archiveSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Archived meetings").font(.system(size: 20, weight: .regular, design: .serif))
                    Text("Restore a local library entry. Original recordings stay in place.")
                        .font(.system(size: 12)).foregroundStyle(secondary)
                }
                Spacer()
                Button("Close") { showArchived = false }.keyboardShortcut(.cancelAction)
            }
            if archivedItems.isEmpty {
                Text("No archived meetings.").foregroundStyle(secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List(archivedItems, id: \.self) { item in
                    HStack {
                        Text("Meeting " + String(item.lastPathComponent.prefix(8)))
                            .font(.system(size: 13, design: .monospaced))
                        Spacer()
                        Button("Restore") { restoreArchive(item) }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(20).frame(minWidth: 440, minHeight: 340)
        .onAppear(perform: loadArchive)
    }

    private func loadArchive() {
        do {
            archivedItems = try bridge.library?.archivedMeetings() ?? []
            showArchived = true
        } catch { status = "Archived meetings could not be opened. Their files are kept." }
    }

    private func restoreArchive(_ url: URL) {
        do {
            _ = try bridge.library?.restore(from: url)
            archivedItems.removeAll { $0 == url }
            status = "Meeting restored to the local library."
        } catch { status = "The meeting could not be restored. Its archived files are kept." }
    }

    private func createNote() {
        guard let library = bridge.library else {
            status = "The local library could not open. Existing files are kept."
            return
        }
        do { selectedID = try library.create(title: "Untitled meeting") }
        catch { status = "The note could not be saved. Try again after reloading the library." }
    }
}

private struct MeetingsReplicaDetail: View {
    let record: PipMeetingRecord
    let library: PipMeetingLibrary
    let capture: PipCaptureSession
    let appState: AppState
    let onBack: () -> Void
    let onRecordApp: (UUID) -> Void
    let onImport: () -> Void
    let onSettings: () -> Void
    let onArchived: () -> Void
    let onStatus: (String) -> Void

    @State private var draft: PipMeetingDraft
    @State private var drafts = PipMeetingDrafts.shared
    @State private var newAction = ""
    @State private var newItemKind: PipMeetingDecision.Kind = .action
    @State private var newItemSourceID: UUID?
    @State private var showItems = true
    @State private var showTranscript = false
    @State private var transcriptQuery = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    init(record: PipMeetingRecord, library: PipMeetingLibrary, capture: PipCaptureSession, appState: AppState,
         onBack: @escaping () -> Void, onRecordApp: @escaping (UUID) -> Void, onImport: @escaping () -> Void,
         onSettings: @escaping () -> Void, onArchived: @escaping () -> Void, onStatus: @escaping (String) -> Void) {
        self.record = record; self.library = library; self.capture = capture; self.appState = appState
        self.onBack = onBack; self.onRecordApp = onRecordApp; self.onImport = onImport
        self.onSettings = onSettings; self.onArchived = onArchived; self.onStatus = onStatus
        _draft = State(initialValue: PipMeetingDrafts.shared.draft(for: record))
    }

    private var secondary: Color { Color.secondary }
    private var panel: Color { Color(nsColor: .controlBackgroundColor) }
    private var visibleSpans: [PipMeetingEvidenceSpan] {
        let spans = record.currentEvidenceSpans
        guard !transcriptQuery.isEmpty else { return spans }
        return spans.filter { $0.text.localizedCaseInsensitiveContains(transcriptQuery) || $0.speaker.localizedCaseInsensitiveContains(transcriptQuery) }
    }
    private var modified: Bool { draft != PipMeetingDraft(record) }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                detailToolbar
                if let message = capture.message {
                    Label(message, systemImage: "info.circle")
                        .font(.system(size: 12)).foregroundStyle(secondary)
                        .frame(maxWidth: 680, alignment: .leading)
                        .padding(.horizontal, 24).padding(.top, 8)
                }
                if let problem = drafts.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                        .frame(maxWidth: 680, alignment: .leading)
                        .padding(.horizontal, 24).padding(.top, 8)
                }
                ForEach(appState.pipelineQueue.jobs.filter { $0.pipMeetingID == record.id }) { job in
                    HStack {
                        Text(job.state == .error ? "Transcription failed. Audio is kept." : "Transcription: \(job.meetingTitle)")
                            .font(.system(size: 12)).foregroundStyle(secondary)
                        Spacer()
                        if job.state == .error {
                            Button("Try again") { _ = appState.pipelineQueue.retryJob(id: job.id) }
                            if let audio = job.mixPath {
                                Button("Show audio") { NSWorkspace.shared.activateFileViewerSelecting([audio]) }
                            }
                        }
                    }
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 24).padding(.top, 6)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        TextField("Meeting title", text: $draft.title)
                            .font(.system(size: 34, weight: .regular, design: .serif))
                            .textFieldStyle(.plain)
                            .accessibilityLabel("Meeting title")
                        HStack(spacing: 10) {
                            Label {
                                Text(record.createdAt, format: .dateTime.day().month(.abbreviated).year())
                            } icon: { Image(systemName: "calendar") }
                            Label("Local note", systemImage: "folder")
                        }
                        .font(.system(size: 12)).foregroundStyle(secondary)
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $draft.notes)
                                .font(.system(size: 16))
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 300)
                                .padding(.horizontal, -5)
                                .accessibilityLabel("Meeting notes")
                                .accessibilityIdentifier("replica-meeting-notes")
                            if draft.notes.isEmpty {
                                Text("Write notes")
                                    .font(.system(size: 16))
                                    .foregroundStyle(secondary)
                                    .padding(.leading, 4).padding(.top, 8)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        decisionAndActionItems
                        if !draft.transcript.isEmpty && record.currentEvidenceSpans.isEmpty {
                            Text("Transcript text is available in the transcript panel.")
                                .font(.system(size: 12)).foregroundStyle(secondary)
                        }
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 24).padding(.top, 26).padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                if modified {
                    HStack {
                        Text(drafts.problem ?? "Unsaved changes are kept as a local draft.")
                            .font(.system(size: 11))
                            .foregroundStyle(drafts.problem == nil ? secondary : .orange)
                        Spacer()
                        Button("Save") { save() }.keyboardShortcut("s", modifiers: [.command])
                    }
                    .padding(.horizontal, 24).padding(.vertical, 8)
                }
                bottomDock
            }
            if showTranscript { transcriptDrawer.transition(reduceMotion ? .identity : .move(edge: .bottom)) }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: draft) { _, next in
            if next != PipMeetingDraft(record) { drafts.keep(next, for: record.id) }
        }
        .onChange(of: record.updatedAt) { _, _ in
            if !modified { draft = drafts.draft(for: record) }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: showTranscript)
        .accessibilityIdentifier("meetings-replica-detail")
    }

    private var detailToolbar: some View {
        HStack {
            Button(action: back) { Label("Back", systemImage: "house") }
                .buttonStyle(.bordered).keyboardShortcut(.leftArrow, modifiers: [.command])
            Spacer()
            ShareLink(item: shareText) { Label("Share", systemImage: "square.and.arrow.up") }
                .buttonStyle(.bordered)
                .help("Share a copy of this meeting's local notes")
            Menu {
                Button("Archive meeting", systemImage: "archivebox") { archive() }
                    .disabled(capture.hasSession && capture.meetingID == record.id)
                Button("Import audio…", systemImage: "waveform.badge.plus", action: onImport)
                Menu("Export a copy") {
                    Button("Markdown…") { export(html: false) }
                    Button("HTML…") { export(html: true) }
                }
                Button("Settings…", systemImage: "gearshape", action: onSettings)
            } label: {
                Image(systemName: "ellipsis").frame(width: 30, height: 30)
            }
            .accessibilityLabel("More meeting options")
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5) }
    }

    private var shareText: String {
        "\(draft.title.isEmpty ? "Untitled meeting" : draft.title)\n\n\(draft.notes)"
    }

    private var bottomDock: some View {
        HStack(spacing: 10) {
            Button { showTranscript.toggle() } label: {
                Label(showTranscript ? "Hide transcript" : "Transcript", systemImage: "waveform")
                    .labelStyle(.iconOnly)
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(showTranscript ? "Hide transcript" : "Show transcript")
            captureControl
            Spacer(minLength: 4)
            Button("Import audio…", systemImage: "waveform.badge.plus", action: onImport)
                .buttonStyle(.bordered)
                .help("Import a local recording")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5) }
    }

    @ViewBuilder private var captureControl: some View {
        switch capture.phase {
        case .recording:
            Button("Pause", systemImage: "pause.fill") { capture.pause(appState: appState) }.buttonStyle(.bordered)
            Button("Stop", systemImage: "stop.fill") { capture.stop(appState: appState) }
                .buttonStyle(.borderedProminent)
        case .paused, .interrupted:
            Button("Resume", systemImage: "record.circle") { Task { await capture.resume(appState: appState) } }
                .buttonStyle(.borderedProminent).disabled(capture.storageProblem)
            Button("Stop") { capture.stop(appState: appState) }.buttonStyle(.bordered)
        case .idle, .starting, .failed:
            Menu {
                Button("Record microphone", systemImage: "mic") {
                    startMicrophone()
                }
                .disabled(appState.settings.noMic)
                Button("Record an app…", systemImage: "macwindow", action: startAppRecording)
            } label: {
                Label(capture.phase == .starting ? "Starting…" : "Record", systemImage: "waveform")
            }
            .buttonStyle(.borderedProminent)
            .disabled(capture.isBusy || capture.storageProblem)
        }
    }

    private var transcriptDrawer: some View {
        GeometryReader { proxy in
        VStack(spacing: 0) {
            HStack {
                Text("Transcript").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Copy") { copyTranscript() }.disabled(draft.transcript.isEmpty && record.currentEvidenceSpans.isEmpty)
                Button { showTranscript = false } label: { Image(systemName: "xmark") }.accessibilityLabel("Close transcript")
            }
            .padding(14)
            TextField("Find in transcript", text: $transcriptQuery)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 14).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Working transcript").font(.system(size: 12, weight: .medium)).foregroundStyle(secondary)
                    TextEditor(text: $draft.transcript)
                        .font(.system(size: 14)).scrollContentBackground(.hidden)
                        .frame(minHeight: 100).accessibilityLabel("Editable working transcript")
                    if draft.transcript.isEmpty && record.currentEvidenceSpans.isEmpty {
                        Text("Import a local recording or write a transcript here.")
                            .font(.system(size: 12)).foregroundStyle(secondary)
                    }
                    ForEach(visibleSpans) { span in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(Self.time(span.start) + "–" + Self.time(span.end)).monospacedDigit()
                                if !span.speaker.isEmpty { Text(span.speaker) }
                            }
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(secondary)
                            Text(span.text).font(.system(size: 14))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(11)
                        .background(panel, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if !transcriptQuery.isEmpty && visibleSpans.isEmpty {
                        Text("No transcript passages match this search.").foregroundStyle(secondary)
                    }
                }
                .frame(maxWidth: 700, alignment: .leading)
                .padding(.horizontal, 14).padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            HStack {
                Label(capture.phase == .recording ? "Recording" : capture.phase == .paused ? "Paused" : "Local transcript", systemImage: capture.phase == .recording ? "waveform" : "waveform")
                    .font(.system(size: 12)).foregroundStyle(secondary)
                Spacer()
                if capture.phase == .paused || capture.phase == .interrupted {
                    Button("Resume") { Task { await capture.resume(appState: appState) } }.disabled(capture.storageProblem)
                }
            }
            .padding(13).overlay(alignment: .top) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5) }
        }
        .frame(maxWidth: .infinity)
        .frame(height: min(480, max(240, proxy.size.height * 0.62)))
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(Color(nsColor: .separatorColor)) }
        .shadow(color: .black.opacity(scheme == .dark ? 0.24 : 0.12), radius: 18, y: -5)
        .padding(.horizontal, 12).padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    @discardableResult private func save() -> Bool {
        do {
            try library.update(id: record.id, title: draft.title, notes: draft.notes, transcript: draft.transcript)
            drafts.saved(record.id)
            onStatus("Meeting saved on this Mac.")
            return true
        } catch {
            drafts.keep(draft, for: record.id)
            let recovery = drafts.problem ?? "Your local draft is kept."
            onStatus("The meeting could not be saved. \(recovery)")
            return false
        }
    }

    private func back() {
        if modified, drafts.problem != nil {
            guard save() else { return }
        }
        onBack()
    }

    private func startMicrophone() {
        guard save() else { return }
        Task { await capture.start(appState: appState, request: .microphone, meetingID: record.id) }
    }

    private func startAppRecording() {
        guard save() else { return }
        onStatus("Choose an app to record into this meeting.")
        onRecordApp(record.id)
    }

    private var decisionAndActionItems: some View {
        DisclosureGroup(isExpanded: $showItems) {
            VStack(alignment: .leading, spacing: 10) {
                if record.decisions.isEmpty {
                    Text("No decisions or actions yet. Add an item and optionally link it to a source passage.")
                        .font(.system(size: 12)).foregroundStyle(secondary)
                }
                ForEach(record.decisions) { item in
                    ReplicaMeetingItemEditor(item: item, record: record, library: library) { source in
                        transcriptQuery = source.text
                        showTranscript = true
                    }
                }
                HStack(spacing: 8) {
                    Picker("Item type", selection: $newItemKind) {
                        Text("Action").tag(PipMeetingDecision.Kind.action)
                        Text("Decision").tag(PipMeetingDecision.Kind.decision)
                    }
                    .labelsHidden().frame(width: 110)
                    TextField("Add a decision or action", text: $newAction, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("New meeting decision or action")
                    Button("Add", action: addAction).disabled(newAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !record.evidenceSpans.isEmpty {
                    Menu(newItemSourceID.flatMap { id in
                        record.evidenceSpans.first(where: { $0.id == id }).map { "Source at \(Self.time($0.start))" }
                    } ?? "Link to source passage") {
                        Button("No source passage") { newItemSourceID = nil }
                        ForEach(record.evidenceSpans) { span in
                            Button("\(Self.time(span.start)) · \(String(span.text.prefix(52)))") { newItemSourceID = span.id }
                        }
                    }
                    .font(.system(size: 12))
                }
            }
            .padding(.top, 10)
        } label: {
            Text("Decisions and actions").font(.system(size: 16, weight: .medium, design: .serif))
        }
    }

    private func addAction() {
        let value = newAction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            _ = try library.addDecision(meetingID: record.id, kind: newItemKind, text: value, spanID: newItemSourceID)
            newAction = ""
            newItemSourceID = nil
            onStatus("Item saved with this meeting.")
        } catch { onStatus("The item could not be saved. Your words are still here.") }
    }

    private func export(html: Bool) {
        guard save(), let latest = library.meetings.first(where: { $0.id == record.id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = html ? [.html] : [UTType(filenameExtension: "md") ?? .plainText]
        let safeTitle = latest.title.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r")).joined(separator: "-")
        panel.nameFieldStringValue = String(safeTitle.prefix(100)) + (html ? ".html" : ".md")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let content = html ? PipMeetingLibrary.html(latest) : PipMeetingLibrary.markdown(latest)
            try Data(content.utf8).write(to: url, options: .atomic)
            onStatus("Meeting exported to a local file.")
        } catch { onStatus("The export could not be written. The saved meeting remains in the library.") }
    }

    private func archive() {
        guard !capture.hasSession || capture.meetingID != record.id else {
            onStatus("Stop this recording before archiving its meeting.")
            return
        }
        if modified && !save() { return }
        do {
            _ = try library.remove(id: record.id)
            onArchived()
            onStatus("Meeting archived. Restore it from Archived meetings.")
        } catch { onStatus("The meeting could not be archived. Its library files are kept.") }
    }

    private func copyTranscript() {
        let sourceText = record.currentEvidenceSpans.map { "\(Self.time($0.start)) \($0.text)" }.joined(separator: "\n")
        let value = draft.transcript.isEmpty ? sourceText : draft.transcript
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        onStatus("Transcript copied.")
    }

    private static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct ReplicaMeetingItemEditor: View {
    let item: PipMeetingDecision
    let record: PipMeetingRecord
    let library: PipMeetingLibrary
    let onSource: (PipMeetingEvidenceSpan) -> Void
    @State private var text: String
    @State private var kind: PipMeetingDecision.Kind
    @State private var sourceID: UUID?
    @State private var complete: Bool
    @State private var problem: String?
    @State private var confirmRemoval = false

    init(item: PipMeetingDecision, record: PipMeetingRecord, library: PipMeetingLibrary,
         onSource: @escaping (PipMeetingEvidenceSpan) -> Void) {
        self.item = item; self.record = record; self.library = library; self.onSource = onSource
        _text = State(initialValue: PipMeetingDrafts.shared.decisionText(meetingID: record.id, decision: item))
        _kind = State(initialValue: item.kind)
        _sourceID = State(initialValue: item.spanID)
        _complete = State(initialValue: item.complete)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Toggle("Complete action", isOn: $complete)
                    .labelsHidden().toggleStyle(.checkbox)
                    .accessibilityLabel("Complete item: \(text)")
                Picker("Item type", selection: $kind) {
                    Text("Action").tag(PipMeetingDecision.Kind.action)
                    Text("Decision").tag(PipMeetingDecision.Kind.decision)
                }
                .labelsHidden().frame(width: 105)
                TextField("Decision or action", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                Button("Save", action: save).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button { confirmRemoval = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).accessibilityLabel("Remove decision or action")
            }
            HStack(spacing: 8) {
                if let source = record.evidenceSpans.first(where: { $0.id == sourceID }) {
                    Button("Source at \(Self.time(source.start))") { onSource(source) }
                        .buttonStyle(.plain)
                    Text(source.text).lineLimit(1).foregroundStyle(.secondary)
                } else { Text("Your own note").foregroundStyle(.secondary) }
                Spacer()
                Menu("Link source") {
                    Button("No source passage") { sourceID = nil }
                    ForEach(record.evidenceSpans) { span in
                        Button("\(Self.time(span.start)) · \(String(span.text.prefix(52)))") { sourceID = span.id }
                    }
                }
            }
            .font(.system(size: 11))
            if let problem { Text(problem).font(.system(size: 11)).foregroundStyle(.orange) }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: text) { _, value in
            if value != item.text { PipMeetingDrafts.shared.keepDecision(value, meetingID: record.id, decisionID: item.id) }
        }
        .onChange(of: item.text) { old, new in if text == old { text = new } }
        .onChange(of: item.kind) { old, new in if kind == old { kind = new } }
        .onChange(of: item.spanID) { old, new in if sourceID == old { sourceID = new } }
        .onChange(of: item.complete) { old, new in if complete == old { complete = new } }
        .confirmationDialog("Remove this item?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove item", role: .destructive) {
                do {
                    try library.removeDecision(meetingID: record.id, decisionID: item.id)
                    PipMeetingDrafts.shared.decisionSaved(meetingID: record.id, decisionID: item.id)
                } catch { problem = "The item could not be removed. Its saved version is kept." }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func save() {
        do {
            try library.updateDecision(meetingID: record.id, decisionID: item.id,
                text: text, complete: complete, kind: kind, spanID: sourceID, replaceReference: true)
            PipMeetingDrafts.shared.decisionSaved(meetingID: record.id, decisionID: item.id)
            problem = nil
        } catch {
            PipMeetingDrafts.shared.keepDecision(text, meetingID: record.id, decisionID: item.id)
            problem = "This edit could not be saved. The previous saved item remains available."
        }
    }

    private static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
#endif
