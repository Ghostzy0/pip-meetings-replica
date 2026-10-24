#if PIP_EDITION
import AppKit
import SwiftUI

struct PipMeetingsWorkspace: View {
    let appState: AppState
    let onRecordApp: () -> Void
    let onImport: () -> Void
    let onSettings: () -> Void
    let onNameSpeakers: () -> Void
    @State private var bridge = PipLibraryBridge.shared
    @State private var capture = PipCaptureSession.shared
    @State private var drafts = PipMeetingDrafts.shared
    @State private var query = ""
    @State private var selection: UUID?
    @State private var showOpenActions = false
    @State private var localProblem: String?
    @State private var showArchived = false
    @State private var archived: [URL] = []
    @Environment(\.colorScheme) private var scheme
    private var palette: PipMeetingsPalette { PipMeetingsPalette(scheme) }
    private var records: [PipMeetingRecord] { bridge.library?.filtered(query) ?? [] }
    private var selected: PipMeetingRecord? { bridge.library?.meetings.first { $0.id == selection } }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: PipMeetingsMetrics.sidebar, max: 360)
        } detail: {
            VStack(spacing: 0) {
                captureBar
                statusMessages
                #if MEETINGS_ENHANCEMENTS
                if showOpenActions {
                    openActionsDetail
                } else if let selected, let library = bridge.library {
                    PipMeetingDetail(record: selected, library: library, canArchive: !(capture.hasSession && capture.meetingID == selected.id)) {
                        selection = nil
                    }
                    .id(selected.id)
                } else { emptyDetail }
                #else
                if let selected, let library = bridge.library {
                    PipMeetingDetail(record: selected, library: library, canArchive: !(capture.hasSession && capture.meetingID == selected.id)) {
                        selection = nil
                    }
                    .id(selected.id)
                } else { emptyDetail }
                #endif
            }
            .background(palette.canvas)
        }
        .tint(palette.accent)
        .foregroundStyle(palette.ink)
        .frame(minWidth: 780, minHeight: 560)
        .onChange(of: capture.meetingID) { _, id in if let id { selection = id } }
        .onChange(of: selection) { _, id in if id != nil { showOpenActions = false } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            capture.stop(appState: appState)
        }
        .sheet(isPresented: $showArchived) { archiveSheet }
        .accessibilityIdentifier("pip-meetings-workspace")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: PipMeetingsMetrics.inset) {
            HStack(spacing: PipMeetingsMetrics.row) {
                PipStillMark(size: 44, active: capture.phase == .recording)
                VStack(alignment: .leading, spacing: PipMeetingsMetrics.tight) {
                    Text(MeetingsBuildIdentity.displayName).font(.system(size: 20, weight: .semibold))
                    Text("Your words, kept close").font(.system(size: 12)).foregroundStyle(palette.secondary)
                }
            }
            .padding(.top, PipMeetingsMetrics.inset)
            TextField("Search meetings", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search meetings")
                .accessibilityIdentifier("pip-meeting-search")
            HStack {
                Text("Meetings").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: createMeeting) { Image(systemName: "plus") }
                    .help("New written meeting")
                    .accessibilityLabel("New written meeting")
                    .keyboardShortcut("n")
            }
            if records.isEmpty {
                Text(query.isEmpty ? "Your recorded and imported meetings will appear here." : "No meetings match this search.")
                    .font(.system(size: 13)).foregroundStyle(palette.secondary)
                    .padding(.vertical, PipMeetingsMetrics.row)
            }
            List(selection: $selection) {
                ForEach(records) { meeting in
                    VStack(alignment: .leading, spacing: PipMeetingsMetrics.tight) {
                        Text(meeting.title.isEmpty ? "Untitled meeting" : meeting.title).font(.system(size: 14, weight: .medium)).lineLimit(2)
                        Text(meeting.updatedAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                            .font(.system(size: 12)).foregroundStyle(palette.secondary)
                    }
                    .padding(.vertical, PipMeetingsMetrics.tight)
                    .tag(meeting.id)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            #if MEETINGS_ENHANCEMENTS
            Button("Open actions", systemImage: "checklist") {
                selection = nil
                showOpenActions = true
            }
            .accessibilityIdentifier("meetings-open-actions")
            #endif
            Divider()
            Button("Import audio", systemImage: "waveform.badge.plus", action: onImport)
                .keyboardShortcut("o")
            Button("Archived meetings", systemImage: "archivebox") { loadArchive() }
            Button("Settings", systemImage: "gearshape", action: onSettings)
                .keyboardShortcut(",")
            Text("On this Mac").font(.system(size: 12)).foregroundStyle(palette.secondary)
        }
        .padding(PipMeetingsMetrics.inset)
        .background(palette.surface)
    }

    private var captureBar: some View {
        HStack(spacing: PipMeetingsMetrics.row) {
            VStack(alignment: .leading, spacing: PipMeetingsMetrics.tight) {
                Label(captureLabel, systemImage: capture.phase == .recording ? "record.circle" : "waveform")
                    .font(.system(size: 14, weight: .semibold))
                Text(capture.phase == .recording ? "Audio is being captured from the source you chose." : "Start a meeting or import an existing recording.")
                    .font(.system(size: 12)).foregroundStyle(palette.secondary)
            }
            Spacer(minLength: PipMeetingsMetrics.gap)
            captureControls
        }
        .padding(PipMeetingsMetrics.inset)
        .background(palette.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
    }

    #if MEETINGS_ENHANCEMENTS
    private var openActionsDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PipMeetingsMetrics.section) {
                PipSectionHeading(title: "Open actions", detail: "Incomplete actions saved with your local meetings.")
                if let localProblem { Text(localProblem).foregroundStyle(palette.danger) }
                let items = bridge.library?.openActions() ?? []
                if items.isEmpty {
                    Text("No open actions yet. Add an action to a meeting to see it here.")
                        .font(.system(size: 14)).foregroundStyle(palette.secondary)
                        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
                } else {
                    VStack(spacing: PipMeetingsMetrics.gap) {
                        ForEach(items) { item in
                            HStack(alignment: .top, spacing: PipMeetingsMetrics.row) {
                                Button {
                                    selection = item.meetingID
                                    showOpenActions = false
                                } label: {
                                    VStack(alignment: .leading, spacing: PipMeetingsMetrics.tight) {
                                        Text(item.text).font(.system(size: 14, weight: .medium)).multilineTextAlignment(.leading)
                                        Text(item.meetingTitle.isEmpty ? "Untitled meeting" : item.meetingTitle)
                                            .font(.system(size: 12)).foregroundStyle(palette.secondary)
                                        Text(item.meetingDate, format: .dateTime.day().month(.abbreviated).year())
                                            .font(.system(size: 11)).foregroundStyle(palette.secondary)
                                        Text(item.spanID == nil ? "Your own note" : "Source passage linked")
                                            .font(.system(size: 11)).foregroundStyle(palette.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Open the meeting containing this action")
                                Toggle("Complete action", isOn: Binding(
                                    get: { false },
                                    set: { value in if value { completeOpenAction(item) } }
                                ))
                                .labelsHidden()
                                .accessibilityLabel("Complete action: \(item.text)")
                            }
                            .padding(PipMeetingsMetrics.inset)
                            .background(palette.surface, in: RoundedRectangle(cornerRadius: PipMeetingsMetrics.cardRadius))
                            .overlay { RoundedRectangle(cornerRadius: PipMeetingsMetrics.cardRadius).strokeBorder(palette.line) }
                        }
                    }
                }
            }
            .frame(maxWidth: PipMeetingsMetrics.detailWidth, alignment: .leading)
            .padding(PipMeetingsMetrics.section)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("meetings-open-actions-detail")
    }

    private func completeOpenAction(_ item: PipOpenAction) {
        do {
            try bridge.library?.updateDecision(meetingID: item.meetingID, decisionID: item.decisionID, complete: true)
            localProblem = nil
        } catch {
            localProblem = "The action could not be saved. Its previous state is kept."
        }
    }
    #endif

    private var captureLabel: String {
        switch capture.phase {
        case .idle: "Ready when you are"
        case .starting: "Starting recording"
        case .recording: "Recording"
        case .paused: "Paused"
        case .interrupted: "Recording needs a review"
        case .failed: "Recording could not start"
        }
    }

    @ViewBuilder private var captureControls: some View {
        if capture.phase == .recording {
            Button("Pause", systemImage: "pause.fill") { capture.pause(appState: appState) }
            Button("Stop", systemImage: "stop.fill") { capture.stop(appState: appState) }
                .buttonStyle(.borderedProminent)
        } else if capture.phase == .paused || capture.phase == .interrupted {
            Button("Stop") { capture.stop(appState: appState) }
            Button("Resume", systemImage: "record.circle") { Task { await capture.resume(appState: appState) } }
                .buttonStyle(.borderedProminent)
                .disabled(capture.storageProblem)
        } else {
            Button("Record app", systemImage: "macwindow", action: onRecordApp)
                .disabled(capture.isBusy || capture.storageProblem)
            Button("Record microphone", systemImage: "mic") {
                Task { await capture.start(appState: appState, request: .microphone) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(capture.isBusy || capture.storageProblem || appState.settings.noMic)
        }
    }

    @ViewBuilder private var statusMessages: some View {
        VStack(alignment: .leading, spacing: PipMeetingsMetrics.gap) {
            if let problem = bridge.problem ?? localProblem ?? drafts.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(palette.danger)
                Button("Reload library") { bridge.reload() }
            }
            if let message = capture.message { Text(message).foregroundStyle(palette.secondary) }
            if let issue = bridge.library?.issues.first { Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(palette.secondary) }
            if appState.engines.activeTranscriptionEngine.modelState != .loaded {
                HStack {
                    Text("Prepare speech in Settings before transcription. Recorded audio is kept if speech is unavailable.")
                    Spacer()
                    Button("Speech settings", action: onSettings)
                }
                .foregroundStyle(palette.secondary)
            }
            if !appState.pipelineQueue.jobs.isEmpty { processingQueue }
        }
        .font(.system(size: 13))
        .padding(.horizontal, PipMeetingsMetrics.inset)
        .padding(.vertical, PipMeetingsMetrics.gap)
    }

    private var processingQueue: some View {
        VStack(alignment: .leading, spacing: PipMeetingsMetrics.gap) {
            ForEach(appState.pipelineQueue.jobs) { job in
                HStack(spacing: PipMeetingsMetrics.gap) {
                    Text(job.meetingTitle).lineLimit(1)
                    Text(jobStatus(job.state)).foregroundStyle(palette.secondary)
                    Spacer()
                    if job.state == .error {
                        Button("Try again") { _ = appState.pipelineQueue.retryJob(id: job.id) }
                        if let audio = job.mixPath { Button("Show audio") { NSWorkspace.shared.activateFileViewerSelecting([audio]) } }
                    } else if job.state == .speakerNamingPending {
                        Button("Name speakers", action: onNameSpeakers)
                    } else if !job.state.isTerminal {
                        Button("Cancel transcription") { appState.pipelineQueue.cancelJob(id: job.id) }
                    }
                }
            }
        }
        .accessibilityIdentifier("pip-processing-queue")
    }

    private func jobStatus(_ state: JobState) -> String {
        switch state {
        case .waiting: "Queued"
        case .transcribing: "Transcribing"
        case .diarizing: "Separating speakers"
        case .generatingProtocol: "Saving transcript"
        case .speakerNamingPending: "Speaker names need a review"
        case .done: "Transcript saved"
        case .error: "Could not transcribe. Audio is kept."
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: PipMeetingsMetrics.inset) {
            Spacer()
            PipStillMark(size: 96)
            Text("Make room for the conversation").font(.system(size: 24, weight: .semibold))
            Text("Record a meeting on this Mac, then keep the transcript, decisions and next steps together.")
                .foregroundStyle(palette.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            Button("New written meeting", action: createMeeting).buttonStyle(.borderedProminent)
            Text("You choose the source. Recording starts only when you press Record.")
                .font(.system(size: 13)).foregroundStyle(palette.secondary)
            Spacer()
        }
        .padding(PipMeetingsMetrics.generous)
        .frame(maxWidth: .infinity)
    }

    private var archiveSheet: some View {
        VStack(alignment: .leading, spacing: PipMeetingsMetrics.inset) {
            HStack {
                PipSectionHeading(title: "Archived meetings", detail: "Restore a library entry. Original audio and transcripts are kept separately.")
                Spacer()
                Button("Close") { showArchived = false }.keyboardShortcut(.cancelAction)
            }
            if archived.isEmpty { Text("No archived meetings.").foregroundStyle(.secondary) }
            List(archived, id: \.self) { url in
                HStack {
                    Text(url.lastPathComponent).font(.system(.caption, design: .monospaced))
                    Spacer()
                    Button("Restore") {
                        do { try bridge.library?.restore(from: url); archived.removeAll { $0 == url } }
                        catch { localProblem = "The meeting could not be restored. Its archived files are kept." }
                    }
                }
            }
        }
        .padding(PipMeetingsMetrics.section)
        .frame(minWidth: 600, minHeight: 320)
    }

    private func createMeeting() {
        do {
            guard let library = bridge.library else { throw PipMeetingLibraryError.invalidDocument }
            selection = try library.create()
            localProblem = nil
        } catch { localProblem = "A new meeting could not be saved. Your existing meetings are kept. Try again." }
    }

    private func loadArchive() {
        do { archived = try bridge.library?.archivedMeetings() ?? []; showArchived = true }
        catch { localProblem = "The archive could not be opened. Its original files are kept." }
    }
}
#endif
