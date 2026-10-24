// Original Pip fixture adapter. Explicit local inputs and an isolated fixture
// data directory; no recording permissions are requested.
import Foundation
import WhisperKit

enum PipFixtureRunner {
    private struct Span: Codable { let start: Double; let end: Double; let text: String }
    private struct Report: Codable {
        let formatVersion: Int
        let engine: String
        let variant: String
        let inputName: String
        let segments: [Span]
    }
    @MainActor static func run(arguments: [String]) async -> Int32? {
        guard let flag = arguments.firstIndex(of: "--pip-transcribe-fixture") else { return nil }
        func argument(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard arguments.indices.contains(flag + 1),
              let modelPath = argument("--pip-model-folder"),
              let tokenizerPath = argument("--pip-tokenizer-folder"),
              let outputPath = argument("--pip-fixture-output"),
              argument("--pip-data-dir") != nil else {
            fputs("Fixture needs audio, --pip-model-folder, --pip-tokenizer-folder, --pip-fixture-output and --pip-data-dir.\n", stderr)
            return 2
        }
        let audio = URL(fileURLWithPath: arguments[flag + 1])
        let folder = URL(fileURLWithPath: modelPath, isDirectory: true)
        let tokenizer = URL(fileURLWithPath: tokenizerPath, isDirectory: true)
        let variant = argument("--pip-model-variant") ?? "openai_whisper-tiny.en"
        guard FileManager.default.fileExists(atPath: audio.path),
              WhisperKitLocalSnapshot.locate(variant: folder.lastPathComponent, in: folder.deletingLastPathComponent()) != nil,
              FileManager.default.fileExists(atPath: tokenizer.appendingPathComponent("tokenizer.json").path),
              FileManager.default.fileExists(atPath: tokenizer.appendingPathComponent("tokenizer_config.json").path) else {
            fputs("Fixture refused: complete local audio, CoreML bundles and tokenizer are required.\n", stderr)
            return 2
        }
        do {
            let engine = WhisperKitEngine()
            engine.modelVariant = variant
            engine.language = "en"
            #if PIP_EDITION
            // Run the exact product engine and its pinned integrity boundary.
            guard tokenizer.standardizedFileURL == folder.deletingLastPathComponent().appendingPathComponent("tokenizer").standardizedFileURL else {
                fputs("Fixture tokenizer must belong to the pinned speech folder.\n", stderr); return 2
            }
            try PipSpeechResources.shared.configure(root: folder.deletingLastPathComponent())
            #else
            engine.installModelSourceForTesting(WhisperKitModelSource(
                locateLocal: { _ in folder },
                download: { _, _ in throw CocoaError(.fileReadNoSuchFile) },
                makePipe: { name, local in
                    try await WhisperKit(WhisperKitConfig(model: name, modelFolder: local.path(percentEncoded: false), tokenizerFolder: tokenizer, verbose: false, download: false))
                }
            ))
            #endif
            let results = try await engine.transcribeSegments(audioPath: audio)
            let segments = results.map { Span(start: $0.start, end: $0.end, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard !segments.isEmpty, segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }) else {
                fputs("Fixture returned no valid timestamped speech.\n", stderr); return 1
            }
            let report = Report(formatVersion: 1, engine: "WhisperKit 1.1.0", variant: variant, inputName: audio.lastPathComponent, segments: segments)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            print("FIXTURE PASS: \(segments.count) timestamped segments; local report written.")
            return 0
        } catch {
            // Avoid dumping arbitrary content or account paths from library errors.
            fputs("Fixture transcription failed. Check compatible local model/tokenizer and inspect the local run log.\n", stderr)
            return 1
        }
    }
}
