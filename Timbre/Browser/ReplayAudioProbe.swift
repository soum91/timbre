import Foundation
import SwiftUI
import ReplayKit
import CoreMedia
import AudioToolbox
import AVFoundation

// User-triggered diagnostic: examines signal levels in memory, never writes audio or keys.
@MainActor
final class ReplayAudioProbe: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var report = "Not tested."

    private let metrics = ReplayPCMMetric()
    private var finishTask: Task<Void, Never>?
    private var referencePlayer: AVAudioPlayer?
    private var measuringReference = false
    private var referencePlaybackMessage = ""

    func start(referenceTone: Bool = false) {
        guard !isRunning else { return }
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            report = "ReplayKit is unavailable on this device right now."
            return
        }
        recorder.isMicrophoneEnabled = false
        metrics.reset()
        measuringReference = referenceTone
        referencePlaybackMessage = ""
        isRunning = true
        report = "Requesting ReplayKit capture permission..."

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
                    self.report = "ReplayKit start failed: " + error.localizedDescription
                    return
                }
                guard self.isRunning else { return }
                if referenceTone {
                    do {
                        let player = try AVAudioPlayer(data: Self.referenceWAV())
                        player.prepareToPlay()
                        self.referencePlayer = player
                        self.referencePlaybackMessage = player.play()
                            ? "Reference tone started."
                            : "Reference tone could not start."
                    } catch {
                        self.referencePlaybackMessage = "Reference tone error: " + error.localizedDescription
                    }
                }
                self.report = (referenceTone ? "Capturing reference tone." : "Capturing website playback.") +
                    " Measuring for six seconds..."
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
        referencePlayer?.stop()
        referencePlayer = nil
        let label = measuringReference ? "Timbre reference-tone test" : "Website playback test"
        let toneMessage = referencePlaybackMessage
        RPScreenRecorder.shared().stopCapture { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRunning = false
                self.report = label + "\n" + toneMessage +
                    (toneMessage.isEmpty ? "" : "\n") +
                    self.metrics.summary() +
                    (error.map { "\nStop error: " + $0.localizedDescription } ?? "")
            }
        }
    }

    // An audible, short, 440 Hz reference only. No file or persistent recording.
    private static func referenceWAV() -> Data {
        let sampleRate = 44_100
        let frames = sampleRate * 2
        var output = Data()
        func word(_ n: UInt16) {
            output.append(UInt8(truncatingIfNeeded: n))
            output.append(UInt8(truncatingIfNeeded: n >> 8))
        }
        func dword(_ n: UInt32) {
            output.append(UInt8(truncatingIfNeeded: n))
            output.append(UInt8(truncatingIfNeeded: n >> 8))
            output.append(UInt8(truncatingIfNeeded: n >> 16))
            output.append(UInt8(truncatingIfNeeded: n >> 24))
        }
        output.append(contentsOf: "RIFF".utf8)
        dword(UInt32(36 + frames * 2))
        output.append(contentsOf: "WAVEfmt ".utf8)
        dword(16)
        word(1)                         // signed 16-bit PCM
        word(1)                         // mono
        dword(UInt32(sampleRate))
        dword(UInt32(sampleRate * 2))
        word(2)
        word(16)
        output.append(contentsOf: "data".utf8)
        dword(UInt32(frames * 2))
        for i in 0..<frames {
            let envelope = min(1.0, min(Double(i) / 441.0, Double(frames - 1 - i) / 441.0))
            let wave = sin(2 * Double.pi * 440 * Double(i) / Double(sampleRate))
            let sample = Int16((wave * 0.10 * envelope * 32767.0).rounded())
            word(UInt16(bitPattern: sample))
        }
        return output
    }
}

// Native audio buffer layout can be planar or interleaved. Inspect each AudioBuffer.
private final class ReplayPCMMetric {
    private let mutex = NSLock()
    private var buffers = 0
    private var decoded = 0
    private var aboveThreshold = 0
    private var peak = 0.0
    private var firstFormat = "none received"
    private var readFailures = 0
    private var unsupportedFormats = 0

    func reset() {
        mutex.lock()
        buffers = 0
        decoded = 0
        aboveThreshold = 0
        peak = 0
        firstFormat = "none received"
        readFailures = 0
        unsupportedFormats = 0
        mutex.unlock()
    }

    func record(_ sample: CMSampleBuffer) {
        let format = CMSampleBufferGetFormatDescription(sample)
        let asbd = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        var resultPeak: Double?
        var readFailed = false
        var unsupported = false
        var formatDescription = "unknown"

        if let asbd = asbd {
            let bitDepth = asbd.mBitsPerChannel
            let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            let signed = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
            let bigEndian = (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
            let layout = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
                ? "planar" : "interleaved"
            formatDescription = "\(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) channels, " +
                "\(bitDepth)-bit \(isFloat ? "float" : (signed ? "signed" : "other")), \(layout)"
            if asbd.mFormatID != kAudioFormatLinearPCM {
                unsupported = true
            } else {
                var required = 0
                let firstStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                    sample, bufferListSizeNeededOut: &required,
                    bufferListOut: nil, bufferListSize: 0,
                    blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                    flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                    blockBufferOut: nil)
                if firstStatus == noErr && required > 0 && required < 65536 {
                    let bytes = max(required, MemoryLayout<AudioBufferList>.size)
                    let memory = UnsafeMutableRawPointer.allocate(
                        byteCount: bytes, alignment: MemoryLayout<AudioBufferList>.alignment)
                    defer { memory.deallocate() }
                    let list = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
                    var retainedBlock: CMBlockBuffer?
                    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                        sample, bufferListSizeNeededOut: nil,
                        bufferListOut: list, bufferListSize: bytes,
                        blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                        flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                        blockBufferOut: &retainedBlock)
                    if status == noErr {
                        var maximum = 0.0
                        var supported = false
                        for buffer in UnsafeMutableAudioBufferListPointer(list) {
                            guard let memory = buffer.mData else { continue }
                            let byteCount = Int(buffer.mDataByteSize)
                            let raw = memory.assumingMemoryBound(to: UInt8.self)
                            let n = min(byteCount / Int(max(1, (bitDepth + 7) / 8)), 4096)
                            if bitDepth == 16 && signed && !isFloat {
                                supported = true
                                for i in 0..<n {
                                    let p = i * 2
                                    let bits = bigEndian
                                        ? (UInt16(raw[p]) << 8) | UInt16(raw[p + 1])
                                        : UInt16(raw[p]) | (UInt16(raw[p + 1]) << 8)
                                    let amplitude = abs(Double(Int16(bitPattern: bits))) / 32768.0
                                    maximum = max(maximum, amplitude)
                                }
                            } else if bitDepth == 32 && isFloat {
                                supported = true
                                for i in 0..<n {
                                    let p = i * 4
                                    let bits = bigEndian
                                        ? (UInt32(raw[p]) << 24) | (UInt32(raw[p + 1]) << 16) |
                                            (UInt32(raw[p + 2]) << 8) | UInt32(raw[p + 3])
                                        : UInt32(raw[p]) | (UInt32(raw[p + 1]) << 8) |
                                            (UInt32(raw[p + 2]) << 16) | (UInt32(raw[p + 3]) << 24)
                                    let v = Double(Float(bitPattern: bits))
                                    if v.isFinite { maximum = max(maximum, abs(v)) }
                                }
                            }
                        }
                        if supported { resultPeak = maximum }
                        else { unsupported = true }
                        _ = retainedBlock
                    } else {
                        readFailed = true
                    }
                } else {
                    readFailed = true
                }
            }
        } else {
            readFailed = true
        }

        mutex.lock()
        buffers += 1
        if firstFormat == "none received" { firstFormat = formatDescription }
        if let resultPeak {
            decoded += 1
            peak = max(peak, resultPeak)
            if resultPeak > 0.001 { aboveThreshold += 1 }
        }
        if readFailed { readFailures += 1 }
        if unsupported { unsupportedFormats += 1 }
        mutex.unlock()
    }

    func summary() -> String {
        mutex.lock()
        let values = (buffers, decoded, aboveThreshold, peak,
                      firstFormat, readFailures, unsupportedFormats)
        mutex.unlock()
        if values.0 == 0 { return "App-audio buffers: 0. No audio was delivered to ReplayKit." }
        return "App-audio buffers: \(values.0); decoded PCM: \(values.1); non-silent: \(values.2); " +
            "peak: \(String(format: "%.5f", values.3)); format: \(values.4); " +
            "read failures: \(values.5); unsupported: \(values.6). " +
            (values.2 > 0
              ? "Nonzero PCM measured by ReplayKit."
              : "No measurable PCM. Confirm the sound is audible during this test.")
    }
}
