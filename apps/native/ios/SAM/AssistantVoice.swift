import AVFoundation
import SwiftUI

/// A bounded recording, uploaded to SAM's existing transcription endpoint.
@MainActor @Observable final class AssistantVoice: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var file: URL?
    private var generation = 0
    var recording = false
    var error: String?

    func start() async {
        error = nil
        let started = generation
        #if os(iOS)
        let permitted = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
        #else
        let permitted = await AVCaptureDevice.requestAccess(for: .audio)
        #endif
        guard started == generation else { return }
        guard permitted else { error = String(localized: "Allow microphone access in Settings to record a message."); return }
        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
            file = url
            let next = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
            recorder = next
            next.delegate = self
            recording = next.record(forDuration: 120)
        } catch { self.error = String(localized: "Could not start recording. Try again."); cancel() }
    }
    func finish() -> Data? {
        recorder?.stop(); recorder = nil; recording = false
        defer { cleanup() }
        guard let file else { return nil }
        return try? Data(contentsOf: file)
    }
    func cancel() { generation += 1; recorder?.stop(); recorder = nil; recording = false; cleanup() }
    private func cleanup() {
        if let file { try? FileManager.default.removeItem(at: file) }; file = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            // Keep the bounded recording until the user chooses to transcribe or cancel.
            if self.recorder === recorder { self.recording = false }
        }
    }
    var hasRecording: Bool { file != nil }
}
