import AVFoundation
import Speech

/// A recognized word (or short token) and when it was spoken.
struct TimedWord {
  let text: String
  let start: Double
  let end: Double

  var map: [String: Any] {
    ["startMs": Int(start * 1000), "endMs": Int(end * 1000), "text": text]
  }
}

enum TranscriptionError: LocalizedError {
  case noAudio
  case unsupportedLocale(String)
  case notAuthorized
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .noAudio: return "The video has no audio"
    case .unsupportedLocale(let id): return "Speech recognition is not available for \(id)"
    case .notAuthorized: return "Speech recognition permission denied"
    case .failed(let reason): return reason
    }
  }
}

/// On-device speech-to-text with Apple's models: SpeechAnalyzer/SpeechTranscriber
/// on iOS 26+ (built for long-form audio), SFSpeechRecognizer before that.
enum Transcriber {
  static func transcribe(video: URL, localeId: String) async throws -> [TimedWord] {
    let audio = try await extractAudio(from: video)
    defer { try? FileManager.default.removeItem(at: audio) }
    let locale = Locale(identifier: localeId)
    if #available(iOS 26.0, *) {
      do {
        return try await transcribeWithAnalyzer(audio: audio, locale: locale)
      } catch {
        // The new model may be missing (simulator, no network to fetch it).
        NSLog("bg_camera: SpeechAnalyzer failed, falling back: \(error)")
      }
    }
    return try await transcribeWithRecognizer(audio: audio, locale: locale)
  }

  @available(iOS 26.0, *)
  private static func transcribeWithAnalyzer(audio: URL, locale: Locale) async throws -> [TimedWord] {
    // False on the Simulator and on devices without Apple Intelligence-era models.
    guard SpeechTranscriber.isAvailable else {
      throw TranscriptionError.failed("SpeechTranscriber is not available on this device")
    }
    guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
      throw TranscriptionError.unsupportedLocale(locale.identifier)
    }
    let transcriber = SpeechTranscriber(
      locale: supported, transcriptionOptions: [], reportingOptions: [],
      attributeOptions: [.audioTimeRange])
    // The app must hold the language before its model can be checked or fetched.
    _ = try await AssetInventory.reserve(locale: supported)
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      try await request.downloadAndInstall()
    }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let collector = Task {
      var words: [TimedWord] = []
      for try await result in transcriber.results {
        for run in result.text.runs {
          guard let range = run.audioTimeRange else { continue }
          let text = String(result.text[run.range].characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if text.isEmpty { continue }
          words.append(
            TimedWord(text: text, start: range.start.seconds, end: range.end.seconds))
        }
      }
      return words
    }
    let file = try AVAudioFile(forReading: audio)
    try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
    return try await collector.value
  }

  private static func transcribeWithRecognizer(audio: URL, locale: Locale) async throws -> [TimedWord] {
    let status = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
    guard status == .authorized else { throw TranscriptionError.notAuthorized }
    guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(),
      recognizer.isAvailable
    else { throw TranscriptionError.unsupportedLocale(locale.identifier) }

    let request = SFSpeechURLRecognitionRequest(url: audio)
    request.shouldReportPartialResults = false
    request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
    if #available(iOS 16.0, *) { request.addsPunctuation = true }

    return try await withCheckedThrowingContinuation { continuation in
      var resumed = false
      recognizer.recognitionTask(with: request) { result, error in
        guard !resumed else { return }
        if let error {
          resumed = true
          continuation.resume(throwing: TranscriptionError.failed(error.localizedDescription))
        } else if let result, result.isFinal {
          resumed = true
          continuation.resume(
            returning: result.bestTranscription.segments.map {
              TimedWord(
                text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
            })
        }
      }
    }
  }

  /// Speech APIs read audio files; pull the soundtrack out of the .mp4.
  private static func extractAudio(from video: URL) async throws -> URL {
    let asset = AVURLAsset(url: video)
    guard !asset.tracks(withMediaType: .audio).isEmpty else { throw TranscriptionError.noAudio }
    guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
      throw TranscriptionError.failed("Cannot export audio")
    }
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("speech_\(UUID().uuidString).m4a")
    export.outputURL = output
    export.outputFileType = .m4a
    await withCheckedContinuation { continuation in
      export.exportAsynchronously { continuation.resume() }
    }
    guard export.status == .completed else {
      throw TranscriptionError.failed(export.error?.localizedDescription ?? "Audio export failed")
    }
    return output
  }
}
