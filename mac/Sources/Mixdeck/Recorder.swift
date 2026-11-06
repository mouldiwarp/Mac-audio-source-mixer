import AVFoundation
import CMixEngine
import Foundation

/// Multitrack recorder (spec/features/control-and-recording.md §1).
///
/// While anything is armed, the engine copies each armed strip/bus into its own
/// ring in the same cycles. A writer thread keeps the pre-record window, and
/// when recording, reads the same number of frames from every ring into the
/// files, so tracks stay sample-aligned.
final class RecordWriter: @unchecked Sendable {
    enum Mode { case armed, recording, paused, stopping }

    private let lock = NSLock()
    private var mode = Mode.armed
    let names: [String]
    private let rings: [OpaquePointer]          // immutable after init
    private var files: [AVAudioFile?]           // under lock
    private let preFrames: UInt64
    private let mono: Bool
    private var alive = true
    private var written: Int64 = 0
    private var writeError: String?
    private let done = DispatchSemaphore(value: 0)
    var onStopped: (() -> Void)?

    init(tracks: [(String, OpaquePointer)], preRecordSeconds: Int, mono: Bool) {
        names = tracks.map(\.0)
        rings = tracks.map(\.1)
        files = Array(repeating: nil, count: tracks.count)
        preFrames = UInt64(preRecordSeconds) * 48000
        self.mono = mono
        Thread.detachNewThread { [self] in loop() }
    }

    /// Stops the thread. Call after the engine stopped feeding the rings.
    func shutdown() {
        lock.lock(); alive = false; lock.unlock()
        done.wait()
        for r in rings { StereoRingDestroy(r) }
    }

    var framesWritten: Int64 { lock.lock(); defer { lock.unlock() }; return written }
    var error: String? { lock.lock(); defer { lock.unlock() }; return writeError }
    var dropped: UInt64 { rings.reduce(0) { $0 + StereoRingDropped($1) } }
    var currentMode: Mode { lock.lock(); defer { lock.unlock() }; return mode }

    func start(files: [AVAudioFile]) {
        lock.lock()
        self.files = files
        written = 0; writeError = nil
        mode = .recording
        lock.unlock()
    }
    func setPaused(_ p: Bool) { lock.lock(); if mode == .recording || mode == .paused { mode = p ? .paused : .recording }; lock.unlock() }
    func stop() { lock.lock(); if mode == .recording || mode == .paused { mode = .stopping }; lock.unlock() }

    private func loop() {
        let chunk = 8192
        let l = UnsafeMutablePointer<Float>.allocate(capacity: chunk), r = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
        defer { l.deallocate(); r.deallocate() }
        while true {
            lock.lock()
            let isAlive = alive, m = mode
            lock.unlock()
            if !isAlive { break }
            guard !rings.isEmpty else { usleep(20_000); continue }
            // All rings were filled in the same cycles; the common end is the minimum.
            let end = rings.map { StereoRingWriteCount($0) }.min() ?? 0
            switch m {
            case .armed:
                for ring in rings { StereoRingTrimTo(ring, end > preFrames ? end - preFrames : 0) }
                usleep(20_000)
            case .paused:
                for ring in rings { StereoRingTrimTo(ring, end) }
                usleep(20_000)
            case .recording, .stopping:
                var n = rings.map { Int(StereoRingAvailable($0)) }.min() ?? 0
                lock.lock(); let fs = files; lock.unlock()
                if m == .recording && n < 2048 { usleep(20_000); continue }
                while n > 0 {
                    let k = min(n, chunk)
                    for i in rings.indices {
                        let got = Int(StereoRingRead(rings[i], l, r, UInt32(k)))
                        if let f = fs[i] { write(i, f, l, r, got) }
                    }
                    lock.lock(); written += Int64(k); lock.unlock()
                    n -= k
                }
                if m == .stopping {
                    lock.lock()
                    files = Array(repeating: nil, count: rings.count)   // closes the files
                    mode = .armed
                    lock.unlock()
                    DispatchQueue.main.async { [weak self] in self?.onStopped?() }
                }
            }
        }
        lock.lock(); files = Array(repeating: nil, count: rings.count); lock.unlock()
        done.signal()
    }

    private func write(_ i: Int, _ f: AVAudioFile, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        guard n > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(n)),
              let ch = buf.floatChannelData else { return }
        buf.frameLength = AVAudioFrameCount(n)
        if mono {
            for i in 0..<n { ch[0][i] = 0.5 * (l[i] + r[i]) }
        } else {
            ch[0].update(from: l, count: n)
            ch[1].update(from: r, count: n)
        }
        do { try f.write(from: buf) } catch {
            lock.lock(); writeError = "write failed: \(error.localizedDescription)"; files[i] = nil; lock.unlock()
        }
    }
}

extension RecorderSettings {
    var fileExtension: String { format.rawValue }

    var fileSettings: [String: Any] {
        let ch = mono ? 1 : 2
        switch format {
        case .m4a:
            return [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: ch,
                    AVEncoderBitRateKey: kbps * 1000]
        case .wav, .caf:
            return [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: ch,
                    AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: bits == 32,
                    AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        }
    }

    var formatLabel: String {
        switch format {
        case .m4a: return "M4A \(kbps) kbps"
        case .wav, .caf: return "\(format.rawValue.uppercased()) " + (bits == 32 ? "32-bit float" : "\(bits)-bit")
        }
    }

    /// `<prefix> YYYY-MM-DD at HHhMMmSSs`
    static func baseName(prefix: String, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH'h'mm'm'ss's'"
        return "\(prefix) \(f.string(from: date))"
    }
}
