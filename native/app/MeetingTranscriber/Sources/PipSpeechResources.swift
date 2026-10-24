#if PIP_EDITION
import AppKit
import CryptoKit
import Foundation
import Observation
import WhisperKit

enum PipSpeechResourceError: LocalizedError {
    case missingFiles, invalidReceipt, changedFiles, downloadsNotEnabled
    var errorDescription: String? {
        switch self {
        case .missingFiles: "Choose the complete speech folder created by the setup script. Your recordings are kept."
        case .invalidReceipt: "The speech folder has no valid file receipt. Run speech setup again, then choose its folder."
        case .changedFiles: "The speech files differ from their receipt. Run speech setup again. Your recordings are kept."
        case .downloadsNotEnabled: "Additional speech downloads are off. Prepare the selected speech engine in Settings first."
        }
    }
}

/// Only explicit local files enter the default Whisper engine. Its model and
/// tokenizer constructors cannot repair missing files by contacting the Hub.
@Observable @MainActor
final class PipSpeechResources {
    struct Configuration: Codable, Equatable {
        let root: URL
        var model: URL { root.appendingPathComponent("openai_whisper-tiny.en", isDirectory: true) }
        var tokenizer: URL { root.appendingPathComponent("tokenizer", isDirectory: true) }
    }
    struct Receipt: Decodable {
        let repo: String
        let revision: String
        let local: String
        let size: Int
        let sha256: String
    }
    static let shared = PipSpeechResources()
    static let variant = "openai_whisper-tiny.en"
    // Exact pinned file identities, independent of the mutable local receipt.
    private static let expectedHashes: [String: String] = [
        "openai_whisper-tiny.en/AudioEncoder.mlmodelc/analytics/coremldata.bin": "eaaaa6671a96a359a0bbd5e97885246dcc17f7435b6ffad8d871bb940964500b",
        "openai_whisper-tiny.en/AudioEncoder.mlmodelc/coremldata.bin": "325b182d0a4266730a81795ae6b7a787b5111dd091500fc0c04dedf610015d46",
        "openai_whisper-tiny.en/AudioEncoder.mlmodelc/metadata.json": "c0468bfcd4c940e479812dc35db6c9bb380c1a9da1786471c0b916e1ee784ff0",
        "openai_whisper-tiny.en/AudioEncoder.mlmodelc/model.mil": "6423991df85b6811ef08a935c86ab4f0cc0a7a072fe24913f3bcfab2c5bebd84",
        "openai_whisper-tiny.en/AudioEncoder.mlmodelc/model.mlmodel": "030d64a3ddd296d6f709691a66a870aab7ee9f19e5fe07e8086245fb85302802",
        "openai_whisper-tiny.en/AudioEncoder.mlmodelc/weights/weight.bin": "f3706dac8d9d4bec269d3cee10fa4eda39b4240a46091c8323c1731a8c6d59c2",
        "openai_whisper-tiny.en/MelSpectrogram.mlmodelc/analytics/coremldata.bin": "160d9737169d22dc01a899e1c6a0a9c44d0637d41f0dedb2a0b7c1422c4035d2",
        "openai_whisper-tiny.en/MelSpectrogram.mlmodelc/coremldata.bin": "cb3b3f51b080f58b12a6888a5e8ad57419be9e4c6843b96a7577f171b300e660",
        "openai_whisper-tiny.en/MelSpectrogram.mlmodelc/metadata.json": "d92e196c14b4d03167a8ded97d9f925617ff302942588aa460257eb0c58de35b",
        "openai_whisper-tiny.en/MelSpectrogram.mlmodelc/model.mil": "5fe83a96c41965219d39734aa3248bd4956d2427705539fba2d406aa4eeb4862",
        "openai_whisper-tiny.en/MelSpectrogram.mlmodelc/weights/weight.bin": "801024dbc7a89c677be1f8b285de3409e35f7d1786c9c8d9d0d6842ac57a1c83",
        "openai_whisper-tiny.en/TextDecoder.mlmodelc/analytics/coremldata.bin": "edb99a30ccee8e157fbec80dc3dce49349ba0982391b327d753e10ccab0a01c3",
        "openai_whisper-tiny.en/TextDecoder.mlmodelc/coremldata.bin": "65c043a081845d190918b4c7d244f94a55df1a15fae796abedc1f414995542c6",
        "openai_whisper-tiny.en/TextDecoder.mlmodelc/metadata.json": "41dccfd0fe75a8f333abf74a1b0ab5ca007a589e5cb50fa34ec6033936763b58",
        "openai_whisper-tiny.en/TextDecoder.mlmodelc/model.mil": "0faaeee40f86f6e4bc69b81c7142bc9ca8af7859a597ee0a22eb3df8ad30ab65",
        "openai_whisper-tiny.en/TextDecoder.mlmodelc/model.mlmodel": "5c3e91bc036014426708e2ceb0e35cb1bbbf34e8121d2070d2b174a7957581d0",
        "openai_whisper-tiny.en/TextDecoder.mlmodelc/weights/weight.bin": "763f915f0126093fc2c506572b3ab0fad134c04cfc2221333ccc7d73552c9252",
        "openai_whisper-tiny.en/config.json": "4d7b75a6f18d3cd9a4f936cdc16d9e5d855c0acbca21d6a11fbac602a422b6a8",
        "openai_whisper-tiny.en/generation_config.json": "aea4069565b5adaec331005991a1d8613192687aa4cedf2e9dd91b126991df5a",
        "tokenizer/README.md": "13627ce3d7dce389223eab7b6ed06738f0f1c786e5245e650b029e4e314c8ff1",
        "tokenizer/added_tokens.json": "560be47bea388757f8d4cc185c5d82067426cbb6361e38016dd90ddc01ab203a",
        "tokenizer/config.json": "b5366317df280f79e6cc366f259f379674f81a8721d458acf2e00680ccb10b1d",
        "tokenizer/merges.txt": "1ce1664773c50f3e0cc8842619a93edc4624525b728b188a9e0be33b7726adc5",
        "tokenizer/normalizer.json": "bf1c507dc8724ca9cf9903640dacfb69dae2f00edee4f21ceba106a7392f26dd",
        "tokenizer/special_tokens_map.json": "014f8f802366ed818919550be0ad9e35907327cb9e142e8aaa102420f460bda8",
        "tokenizer/tokenizer.json": "5eb60cec1e77aeeb6869a2bb5a8e01a84c3fe5d072d75369343021fe6f5310d0",
        "tokenizer/tokenizer_config.json": "14f84bdf4b9ecdbd4738ddc81c17a1baedfc02bb93c6e049c951e15a1b40b70d",
        "tokenizer/vocab.json": "3ba3c3109ff33976c4bd966589c11ee14fcaa1f4c9e5e154c2ed7f99d80709e7",
    ]
    private static let expectedSizes: [String: Int] = [
        "openai_whisper-tiny.en/AudioEncoder.mlmodelc/analytics/coremldata.bin": 243,
        "openai_whisper-tiny.en/AudioEncoder.mlmodelc/coremldata.bin": 347,
        "openai_whisper-tiny.en/AudioEncoder.mlmodelc/metadata.json": 1807,
        "openai_whisper-tiny.en/AudioEncoder.mlmodelc/model.mil": 308780,
        "openai_whisper-tiny.en/AudioEncoder.mlmodelc/model.mlmodel": 54965,
        "openai_whisper-tiny.en/AudioEncoder.mlmodelc/weights/weight.bin": 16422784,
        "openai_whisper-tiny.en/MelSpectrogram.mlmodelc/analytics/coremldata.bin": 243,
        "openai_whisper-tiny.en/MelSpectrogram.mlmodelc/coremldata.bin": 328,
        "openai_whisper-tiny.en/MelSpectrogram.mlmodelc/metadata.json": 1848,
        "openai_whisper-tiny.en/MelSpectrogram.mlmodelc/model.mil": 10132,
        "openai_whisper-tiny.en/MelSpectrogram.mlmodelc/weights/weight.bin": 354080,
        "openai_whisper-tiny.en/TextDecoder.mlmodelc/analytics/coremldata.bin": 243,
        "openai_whisper-tiny.en/TextDecoder.mlmodelc/coremldata.bin": 633,
        "openai_whisper-tiny.en/TextDecoder.mlmodelc/metadata.json": 4754,
        "openai_whisper-tiny.en/TextDecoder.mlmodelc/model.mil": 135272,
        "openai_whisper-tiny.en/TextDecoder.mlmodelc/model.mlmodel": 108558,
        "openai_whisper-tiny.en/TextDecoder.mlmodelc/weights/weight.bin": 59215664,
        "openai_whisper-tiny.en/config.json": 1454,
        "openai_whisper-tiny.en/generation_config.json": 1006,
        "tokenizer/README.md": 14861,
        "tokenizer/added_tokens.json": 34604,
        "tokenizer/config.json": 1937,
        "tokenizer/merges.txt": 456318,
        "tokenizer/normalizer.json": 52666,
        "tokenizer/special_tokens_map.json": 1830,
        "tokenizer/tokenizer.json": 2405679,
        "tokenizer/tokenizer_config.json": 805,
        "tokenizer/vocab.json": 798156,
    ]
    private(set) var configuration: Configuration?
    private(set) var status = "Choose your speech files to prepare English transcription."
    private let path: URL

    // Explicit setup action, not inferred from recording or an old cloud setting.
    nonisolated static var additionalDownloadDefaults: UserDefaults {
        #if DEBUG
        if let directory = ProcessInfo.processInfo.environment["PIP_TEST_DATA_DIR"] {
            let key = SHA256.hash(data: Data(directory.utf8)).map { String(format: "%02x", $0) }.joined()
            return UserDefaults(suiteName: "uk.pipreps.meetings.tests." + key)!
        }
        #endif
        return .standard
    }
    nonisolated static var additionalDownloadsEnabled: Bool {
        additionalDownloadDefaults.bool(forKey: "pipAdditionalSpeechDownloadsEnabled")
    }

    init(path: URL = AppPaths.dataDir.appendingPathComponent("speech-resources.json")) {
        self.path = path
        if let data = try? Data(contentsOf: path), let stored = try? JSONDecoder().decode(Configuration.self, from: data) {
            configuration = stored
            status = "Speech folder selected. Press Prepare speech to verify and load it."
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose your speech folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try configure(root: url) }
        catch { status = "The speech folder could not be verified. Run speech setup again, then choose its folder." }
    }

    func configure(root: URL) throws {
        let next = Configuration(root: root.standardizedFileURL.resolvingSymlinksInPath())
        try Self.verify(next)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(next).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        configuration = next
        status = "Speech files verified. Press Prepare speech to load them."
    }

    static func verify(_ configuration: Configuration) throws {
        let fm = FileManager.default
        let receipt = configuration.root.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: receipt), data.count < 1024 * 1024,
              let entries = try? JSONDecoder().decode([Receipt].self, from: data),
              entries.count == expectedHashes.count, Set(entries.map(\.local)).count == expectedHashes.count else {
            throw PipSpeechResourceError.invalidReceipt
        }
        let coreRevision = "0f63a7800b00dd0226abd051b906c246e1907482"
        let tokenizerRevision = "87c7102498dcde7456f24cfd30239ca606ed9063"
        for entry in entries {
            guard (entry.repo == "argmaxinc/whisperkit-coreml" && entry.revision == coreRevision)
                    || (entry.repo == "openai/whisper-tiny.en" && entry.revision == tokenizerRevision),
                  !entry.local.hasPrefix("/"), !entry.local.split(separator: "/").contains(".."),
                  entry.size >= 0, entry.size < 128 * 1024 * 1024,
                  expectedHashes[entry.local] == entry.sha256, expectedSizes[entry.local] == entry.size else {
                throw PipSpeechResourceError.invalidReceipt
            }
            let file = configuration.root.appendingPathComponent(entry.local).standardizedFileURL
            guard file.resolvingSymlinksInPath().path.hasPrefix(configuration.root.path + "/"),
                  let bytes = try? Data(contentsOf: file, options: .mappedIfSafe), bytes.count == entry.size,
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == entry.sha256 else {
                throw PipSpeechResourceError.changedFiles
            }
        }
        guard WhisperKitLocalSnapshot.locate(variant: variant, in: configuration.root) != nil,
              fm.fileExists(atPath: configuration.tokenizer.appendingPathComponent("tokenizer.json").path),
              fm.fileExists(atPath: configuration.tokenizer.appendingPathComponent("tokenizer_config.json").path) else {
            throw PipSpeechResourceError.missingFiles
        }
    }

    static var modelSource: WhisperKitModelSource {
        WhisperKitModelSource(
            locateLocal: { variant in
                guard variant == Self.variant, let config = shared.configuration else { return nil }
                return WhisperKitLocalSnapshot.locate(variant: variant, in: config.root)
            },
            download: { _, _ in throw PipSpeechResourceError.missingFiles },
            makePipe: { variant, folder in
                guard variant == Self.variant, let config = shared.configuration, folder == config.model else {
                    throw PipSpeechResourceError.missingFiles
                }
                try Self.verify(config)
                return try await WhisperKit(WhisperKitConfig(
                    model: variant, modelFolder: folder.path(percentEncoded: false),
                    tokenizerFolder: config.tokenizer, verbose: false, download: false
                ))
            }
        )
    }
}
#endif
