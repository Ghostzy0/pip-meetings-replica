#if PIP_EDITION
import AppKit
import SwiftUI

struct PipPrivacySettingsView: View {
    var body: some View {
        Form {
            Section("On this Mac") {
                Text("Audio, transcripts and your notes are kept in your local app folders. There is no account or external note service.")
                Text("Recording starts only when you choose a microphone or app. Automatic meeting detection is unavailable in this edition.")
            }
            Section("Recording permissions") {
                Text("Microphone access records your voice. System audio access records the app you choose. You decide when to grant each permission.")
                Button("Open microphone settings") { openSettings("Privacy_Microphone") }
                Button("Open system audio settings") { openSettings("Privacy_ScreenCapture") }
            }
            Section("Your files") {
                Text("Audio is retained with the original recording. Archiving a library entry keeps a recoverable copy. Library removal does not remove the original audio or transcript.")
                Button("Open app folder") { NSWorkspace.shared.open(AppPaths.dataDir) }
            }
        }
        .formStyle(.grouped)
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) { NSWorkspace.shared.open(url) }
    }
}

struct PipOutputSettingsView: View {
    @Bindable var settings: AppSettings
    var body: some View {
        Form {
            Section("Recorded files") {
                Text("Recordings and transcripts are kept in your app folder unless you choose a different local folder.")
                Text(settings.effectiveOutputDir.path).textSelection(.enabled).font(.system(.caption, design: .monospaced))
                Button("Choose output folder") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { settings.setCustomOutputDir(url) }
                }
                Button("Use app folder") { settings.clearCustomOutputDir() }
                Button("Open output folder") { NSWorkspace.shared.open(settings.effectiveOutputDir) }
            }
            Section("Meeting notes") {
                Text("Write decisions and actions yourself and link them to transcript passages. This edition does not send meeting content to a note generator.")
            }
        }
        .formStyle(.grouped)
    }
}

struct PipSpeechSettingsView: View {
    @Bindable var settings: AppSettings
    let whisperKitEngine: WhisperKitEngine
    let parakeetEngine: ParakeetEngine
    @State private var feedback = ""
    @State private var preparing = false
    @State private var resources = PipSpeechResources.shared

    var body: some View {
        Form {
            Section("English speech") {
                Text("Run the speech setup script once, then choose its folder. Your meetings are transcribed on this Mac using those verified files.")
                Text(resources.status)
                if let root = resources.configuration?.root {
                    Text(root.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                HStack {
                    Button("Choose speech folder") { resources.chooseFolder() }
                    Button(preparing ? "Preparing speech" : "Prepare speech") { prepareEnglish() }
                        .disabled(resources.configuration == nil || preparing)
                }
                if !feedback.isEmpty { Text(feedback).accessibilityIdentifier("pip-speech-status") }
                Text("Small English recogniser. Accuracy varies with accents, noise and overlapping voices. Check important words against the recording.")
            }
            Section("Additional local speech tools") {
                Text("Multilingual recognition and speaker separation need additional speech files. Only prepare these tools when you want to download those files. Meeting audio stays on this Mac.")
                Button("Prepare multilingual speech") {
                    PipSpeechResources.additionalDownloadDefaults.set(true, forKey: "pipAdditionalSpeechDownloadsEnabled")
                    preparing = true
                    Task { @MainActor in
                        await parakeetEngine.loadModel()
                        preparing = false
                        if parakeetEngine.modelState == .loaded {
                            settings.transcriptionEngine = .parakeet
                            feedback = "Multilingual speech is ready on this Mac."
                        } else { feedback = "Speech could not be prepared. Check the download and try again. Your recordings are kept." }
                    }
                }
                .disabled(preparing)
                Toggle("Separate speakers locally", isOn: $settings.diarize)
                    .disabled(!PipSpeechResources.additionalDownloadsEnabled)
                Text("Speaker labels are estimates. They do not establish a person's identity.")
                if PipSpeechResources.additionalDownloadsEnabled {
                    Button("Turn additional downloads off") {
                        PipSpeechResources.additionalDownloadDefaults.set(false, forKey: "pipAdditionalSpeechDownloadsEnabled")
                        settings.diarize = false
                        settings.liveTranscriptionEnabled = false
                        settings.transcriptionEngine = .whisperKit
                        feedback = "Additional downloads are off. English speech still uses your selected local files."
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func prepareEnglish() {
        preparing = true
        settings.transcriptionEngine = .whisperKit
        settings.whisperKitModel = PipSpeechResources.variant
        whisperKitEngine.resetPipSpeechResources()
        Task { @MainActor in
            await whisperKitEngine.loadModel()
            preparing = false
            feedback = whisperKitEngine.modelState == .loaded
                ? "English speech is ready on this Mac."
                : "Speech could not be prepared. Verify the selected folder and try again. Your recordings are kept."
        }
    }
}

struct PipAboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PipMeetingsMetrics.section) {
                HStack(spacing: PipMeetingsMetrics.inset) {
                    PipStillMark()
                    VStack(alignment: .leading, spacing: PipMeetingsMetrics.tight) {
                        Text(MeetingsBuildIdentity.displayName).font(.system(size: 24, weight: .semibold))
                        Text("Local meeting notes, with the source kept close.").foregroundStyle(.secondary)
                    }
                }
                PipSectionHeading(title: "Experimental native build", detail: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development")
                Text("A native adaptation of Meeting Transcriber 0.8.1. It retains the upstream audio capture, recovery and on-device speech pipeline. The local edition adds a meeting library and editable source-linked decisions and actions.")
                Text("Native permission, speech accuracy and long meeting acceptance are measured separately. An ad-hoc build is not notarised.")
                Link("Maintained by Ghostzy0", destination: URL(string: "https://github.com/Ghostzy0")!)
                Link("Meeting Transcriber source and MIT licence", destination: URL(string: "https://github.com/pasrom/meeting-transcriber")!)
                Button("Open bundled licences") {
                    if let resources = Bundle.main.resourceURL { NSWorkspace.shared.open(resources.appendingPathComponent("licenses")) }
                }
            }
            .padding(PipMeetingsMetrics.section)
            .frame(maxWidth: PipMeetingsMetrics.detailWidth, alignment: .leading)
        }
    }
}
#endif
