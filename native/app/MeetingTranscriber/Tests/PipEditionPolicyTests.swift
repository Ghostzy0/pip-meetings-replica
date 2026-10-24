#if PIP_EDITION
@testable import MeetingTranscriber
import Foundation
import XCTest

@MainActor
final class PipEditionPolicyTests: XCTestCase {
    func testPersistedProviderWatcherAndUpdaterCannotEnablePipPaths() throws {
        let name = "PipPolicyTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "autoWatch")
        defaults.set(true, forKey: "checkForUpdates")
        defaults.set("openAICompatible", forKey: "protocolProvider")
        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.autoWatch)
        XCTAssertFalse(settings.watchTeams)
        XCTAssertFalse(settings.watchZoom)
        XCTAssertFalse(settings.checkForUpdates)
        XCTAssertEqual(settings.protocolProvider, .none)
        XCTAssertEqual(settings.whisperKitModel, "openai_whisper-tiny.en")
        XCTAssertEqual(settings.whisperLanguage, "en")
        XCTAssertFalse(PipEditionPolicy.allowsRemoteProviders)
        XCTAssertFalse(PipEditionPolicy.allowsAutomation)
    }

    func testProtocolFactoryRemainsNilEvenIfPreferenceChangesInMemory() throws {
        let name = "PipFactoryTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.protocolProvider = .openAICompatible
        settings.openAIEndpoint = "https://example.invalid/content"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = PipelineController(settings: settings, notifier: SilentNotifier(), queueEnvironment: .init(
            logDir: root, stagingDir: root.appendingPathComponent("recordings"), recoverStagedRecordings: nil
        ))
        XCTAssertNil(controller.makeProtocolGenerator())
    }

    func testAutomaticWatchLoopCannotStartInPip() {
        let loop = WatchLoop()
        loop.start()
        XCTAssertEqual(loop.state, .idle)
    }

    func testDefaultSpeechSourceCannotDownloadMissingFiles() async {
        do {
            _ = try await WhisperKitModelSource.production.download("openai_whisper-tiny.en") { _ in }
            XCTFail("The Pip speech source must never fall back to a Hub download")
        } catch { XCTAssertTrue(error is PipSpeechResourceError) }
    }

    func testDuplicateSelfAttestedSpeechReceiptIsRejectedBeforeFileUse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entry: [String: Any] = [
            "repo": "argmaxinc/whisperkit-coreml", "revision": "0f63a7800b00dd0226abd051b906c246e1907482",
            "local": "openai_whisper-tiny.en/AudioEncoder.mlmodelc/weights/weight.bin", "size": 1,
            "sha256": String(repeating: "0", count: 64)
        ]
        try JSONSerialization.data(withJSONObject: Array(repeating: entry, count: 28)).write(to: root.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try PipSpeechResources.verify(.init(root: root))) { error in
            guard case PipSpeechResourceError.invalidReceipt = error else { return XCTFail("Unexpected error \(error)") }
        }
    }
}
#endif
