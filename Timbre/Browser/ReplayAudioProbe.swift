import Foundation
import SwiftUI
import ReplayKit
import CoreMedia
import AudioToolbox

// Opt-in iOS capture check. Buffers are only inspected in memory and never stored.
@MainActor
final class ReplayAudioProbe: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var report = "Not tested."
    private let metrics = ReplayPCMMetric()
    private var finishTask: Task<Void, Never>?

    func start() {
        guard !isRunning else { return }
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            report = "ReplayKit is unavailable on this device right now."
            return
        }
        recorder.isMicrophoneEnabled = false
        metrics.reset()
        isRunning = true
        report = "Requesting system capture permission..."
        let counters = metrics
        recorder.startCapture(handler: { sample, kind, error in
            if kind == .audioApp && error == nil {
                counters.record(sample)
            }
        }, completionHandler: { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.isRunning = false
                    self.report = "Capture failed: " + error.localizedDescription
                    return
                }
                self.report = "Measuring app-audio levels for six seconds..."
                self.finishTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    if !Task.isCancelled { self?.stop() }
                }
            }
        })
    }

    func stop() {
        guard isRunning else { return }
        finishTask?.cancel()
        finishTask = nil
        RPScreenRecorder.shared().stopCapture { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRunning = false
                self.report = self.metrics.summary() + (error.map { "\nStop error: " + $0.localizedDescription } ?? "")
            }
        }
    }
}

private final class ReplayPCMMetric {
    private let mutex = NSLock()
    private var appBuffers = 0
    private var pcmBuffers = 0
    private var aboveThreshold = 0
    private var peak = 0.0

    func reset() {
        mutex.lock()
        appBuffers = 0
        pcmBuffers = 0
        aboveThreshold = 0
        peak = 0
        mutex.unlock()
    }

    func record(_ sample: CMSampleBuffer) {
        var observedPeak: Double?
        if let format = CMSampleBufferGetFormatDescription(sample),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
           asbd.mFormatID == kAudioFormatLinearPCM,
           let block = CMSampleBufferGetDataBuffer(sample) {
            let byteCount = min(CMBlockBufferGetDataLength(block), 16384)
            if byteCount > 0 {
                var data = [UInt8](repeating: 0, count: byteCount)
                let result: OSStatus = data.withUnsafeMutableBytes { bytes in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0,
                                               dataLength: byteCount,
                                               destination: bytes.baseAddress!)
                }
                if result == kCMBlockBufferNoErr {
                    let isBigEndian = (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
                    let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
                    let isSigned = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
                    var measured = 0.0
                    if asbd.mBitsPerChannel == 16 && isSigned {
                        for i in stride(from: 0, to: data.count - 1, by: 2) {
                            let bits: UInt16 = isBigEndian
                                ? (UInt16(data[i]) << 8) | UInt16(data[i + 1])
                                : (UInt16(data[i + 1]) << 8) | UInt16(data[i])
                            let value = Double(abs(Int(Int16(bitPattern: bits)))) / 32768.0
                            measured = max(measured, value)
                        }
                        observedPeak = measured
                    } else if asbd.mBitsPerChannel == 32 && isFloat {
                        for i in stride(from: 0, to: data.count - 3, by: 4) {
                            let bits: UInt32 = isBigEndian
                                ? (UInt32(data[i]) << 24) | (UInt32(data[i + 1]) << 16) |
                                  (UInt32(data[i + 2]) << 8) | UInt32(data[i + 3])
                                : (UInt32(data[i + 3]) << 24) | (UInt32(data[i + 2]) << 16) |
                                  (UInt32(data[i + 1]) << 8) | UInt32(data[i])
                            let value = Double(Float(bitPattern: bits))
                            if value.isFinite { measured = max(measured, abs(value)) }
                        }
                        observedPeak = measured
                    }
                }
            }
        }

        mutex.lock()
        appBuffers += 1
        if let observedPeak {
            pcmBuffers += 1
            peak = max(peak, observedPeak)
            if observedPeak > 0.001 { aboveThreshold += 1 }
        }
        mutex.unlock()
    }

    func summary() -> String {
        mutex.lock()
        let buffers = appBuffers
        let pcm = pcmBuffers
        let audible = aboveThreshold
        let maxValue = peak
        mutex.unlock()
        if buffers == 0 {
            return "No app-audio buffers received. ReplayKit did not expose audio in this test."
        }
        if pcm == 0 {
            return "App-audio buffers: \(buffers). Unsupported or unavailable PCM format; inconclusive."
        }
        return "App-audio buffers: \(buffers); measured PCM: \(pcm); non-silent: \(audible); peak: \(String(format: "%.5f", maxValue)). " +
            (audible > 0
             ? "Nonzero app audio reached ReplayKit (not yet proof of EQ routing)."
             : "No measurable app-audio signal. Protected playback or capture limitations remain possible.")
    }
}
