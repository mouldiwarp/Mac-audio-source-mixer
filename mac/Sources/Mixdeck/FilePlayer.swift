import AudioToolbox
import CMixEngine
import Foundation

/// Plays an audio file into a strip (spec/features/control-and-recording.md §2).
/// A decoder thread converts the file to 48 kHz and keeps the strip's ring filled;
/// the audio thread only reads the ring.
final class FilePlayer: @unchecked Sendable {
    enum PlayerError: Error, CustomStringConvertible {
        case open(OSStatus), format(OSStatus)
        var description: String {
            switch self {
            case .open(let s): return "cannot open file (\(s))"
            case .format(let s): return "unsupported file (\(s))"
            }
        }
    }

    let ring: OpaquePointer
    let totalFrames: Int64          // at 48 kHz
    private let file: ExtAudioFileRef
    private let channels: Int
    private let lock = NSLock()
    private var playing = false
    private var loopOn = false
    private var stopRequested = false
    private var alive = true
    private var decoded: Int64 = 0  // frames pushed since the last rewind (keeps counting across loops)
    private let done = DispatchSemaphore(value: 0)
    /// Called on the main queue when playback ends (no loop) and the player has rewound.
    var onFinished: (() -> Void)?

    init(url: URL) throws {
        var f: ExtAudioFileRef?
        var st = ExtAudioFileOpenURL(url as CFURL, &f)
        guard st == noErr, let f else { throw PlayerError.open(st) }
        file = f
        var fmt = AudioStreamBasicDescription()
        var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        st = ExtAudioFileGetProperty(f, kExtAudioFileProperty_FileDataFormat, &sz, &fmt)
        guard st == noErr, fmt.mSampleRate > 0, fmt.mChannelsPerFrame > 0 else { ExtAudioFileDispose(f); throw PlayerError.format(st) }
        channels = Int(fmt.mChannelsPerFrame)
        var client = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                                 mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                                 mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        st = ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard st == noErr else { ExtAudioFileDispose(f); throw PlayerError.format(st) }
        var len: Int64 = 0
        sz = UInt32(MemoryLayout<Int64>.size)
        ExtAudioFileGetProperty(f, kExtAudioFileProperty_FileLengthFrames, &sz, &len)
        totalFrames = Int64(Double(len) * 48000 / fmt.mSampleRate)
        guard let r = StereoRingCreate(48000) else { ExtAudioFileDispose(f); throw PlayerError.format(-1) }
        ring = r
        StereoRingSetPaused(r, true)
        Thread.detachNewThread { [self] in decodeLoop() }
    }

    deinit {
        lock.lock(); alive = false; lock.unlock()
        done.wait()
        ExtAudioFileDispose(file)
        StereoRingDestroy(ring)
    }

    var isPlaying: Bool { lock.lock(); defer { lock.unlock() }; return playing }

    func play() { lock.lock(); playing = true; lock.unlock(); StereoRingSetPaused(ring, false) }
    func pause() { lock.lock(); playing = false; lock.unlock(); StereoRingSetPaused(ring, true) }
    func stop() { lock.lock(); playing = false; stopRequested = true; lock.unlock(); StereoRingSetPaused(ring, true) }
    func setLoop(_ on: Bool) { lock.lock(); loopOn = on; lock.unlock() }

    /// Playback position in seconds.
    var position: Double {
        lock.lock(); let d = decoded; lock.unlock()
        guard totalFrames > 0 else { return 0 }
        let p = max(0, d - Int64(StereoRingAvailable(ring)))
        return Double(p % totalFrames) / 48000
    }
    var duration: Double { Double(totalFrames) / 48000 }

    private func rewind() {
        StereoRingRequestFlush(ring)
        // The audio thread clears the request on its next cycle; if the engine is
        // stopped nobody will, so give up after a moment and clear it ourselves.
        for _ in 0..<100 where StereoRingFlushPending(ring) { usleep(2000) }
        if StereoRingFlushPending(ring) { StereoRingTrim(ring, 0) }
        ExtAudioFileSeek(file, 0)
        lock.lock(); decoded = 0; lock.unlock()
    }

    private func decodeLoop() {
        let chunk = 4096
        let bufs = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: chunk) }
        let abl = AudioBufferList.allocate(maximumBuffers: channels)
        defer { abl.unsafeMutablePointer.deallocate(); bufs.forEach { $0.deallocate() } }
        var ended = false
        while true {
            lock.lock()
            let isAlive = alive, isPlaying = playing, wantStop = stopRequested, loop = loopOn
            stopRequested = false
            lock.unlock()
            if !isAlive { break }
            if wantStop { rewind(); ended = false; continue }
            if ended {
                // Let the ring play out, then stop and rewind.
                if StereoRingAvailable(ring) == 0 || !isPlaying {
                    ended = false
                    if isPlaying {
                        pause(); rewind()
                        DispatchQueue.main.async { [weak self] in self?.onFinished?() }
                    }
                }
                usleep(10_000); continue
            }
            guard isPlaying, StereoRingSpace(ring) >= UInt32(chunk) else { usleep(10_000); continue }
            var frames = UInt32(chunk)
            for c in 0..<channels {
                abl[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(chunk * 4), mData: bufs[c])
            }
            let got: UInt32 = ExtAudioFileRead(file, &frames, abl.unsafeMutablePointer) == noErr ? frames : 0
            if got == 0 {
                if loop { ExtAudioFileSeek(file, 0); continue }   // seamless: ring keeps playing meanwhile
                ended = true
                continue
            }
            _ = StereoRingWrite(ring, bufs[0], channels > 1 ? bufs[1] : bufs[0], got)   // mono: both sides
            lock.lock(); decoded += Int64(got); lock.unlock()
        }
        done.signal()
    }
}
