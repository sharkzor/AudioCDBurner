import Foundation
import AVFoundation
import AudioToolbox

/// Bridge an async throwing call to a synchronous context.
fileprivate func awaitSync<T>(_ op: @escaping () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    var result: Result<T, Error>!
    Task.detached {
        do { result = .success(try await op()) }
        catch { result = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return try result.get()
}

/// Decodes an arbitrary audio file (FLAC/MP3/AAC/M4A/WAV/AIFF/ALAC) to a temporary
/// AIFF file in Red Book CD-DA format: 44.1 kHz, 16-bit signed big-endian, stereo.
///
/// Returns the URL of the temp AIFF, plus the number of audio frames written.
/// Throws if decoding or conversion fails.
enum AudioDecoderError: Error, LocalizedError {
    case cannotOpen(URL)
    case conversionFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let u):       return "Cannot open audio file: \(u.lastPathComponent)"
        case .conversionFailed(let m): return "Audio conversion failed: \(m)"
        case .writeFailed(let m):      return "Failed writing temp AIFF: \(m)"
        }
    }
}

struct DecodedTrack {
    let aiffURL: URL
    let frameCount: Int64   // PCM frames @ 44.1 kHz
    var seconds: Double { Double(frameCount) / 44100.0 }
    /// CD sectors (75/sec). Each sector = 588 stereo frames.
    var sectors: Int { Int((frameCount + 587) / 588) }
}

final class AudioDecoder {
    static let cdSampleRate: Double = 44100.0

    /// Convert a single source file into a CD-DA AIFF in `tmpDir`.
    static func decodeToCDA(source: URL, tmpDir: URL) throws -> DecodedTrack {
        let outURL = tmpDir.appendingPathComponent(UUID().uuidString + ".aiff")

        let asset = AVURLAsset(url: source)
        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try awaitSync { try await asset.loadTracks(withMediaType: .audio) }
        } catch {
            throw AudioDecoderError.cannotOpen(source)
        }
        guard let track = audioTracks.first else {
            throw AudioDecoderError.cannotOpen(source)
        }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw AudioDecoderError.cannotOpen(source) }

        // Read out as 32-bit float interleaved stereo @ 44.1k, then quantize to int16 BE on write.
        // We ask AVAssetReader to deliver float samples and let it handle resampling.
        let readSettings: [String: Any] = [
            AVFormatIDKey:               kAudioFormatLinearPCM,
            AVSampleRateKey:             cdSampleRate,
            AVNumberOfChannelsKey:       2,
            AVLinearPCMBitDepthKey:      32,
            AVLinearPCMIsFloatKey:       true,
            AVLinearPCMIsBigEndianKey:   false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: readSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AudioDecoderError.conversionFailed("reader cannot add output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioDecoderError.conversionFailed(reader.error?.localizedDescription ?? "startReading failed")
        }

        // Open AIFF output via AudioFile / ExtAudioFile in CD-DA format.
        var cdaFmt = AudioStreamBasicDescription(
            mSampleRate: cdSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsBigEndian | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var extFile: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(outURL as CFURL,
                                                     kAudioFileAIFFType,
                                                     &cdaFmt,
                                                     nil,
                                                     AudioFileFlags.eraseFile.rawValue,
                                                     &extFile)
        guard createStatus == noErr, let extFileRef = extFile else {
            throw AudioDecoderError.writeFailed("ExtAudioFileCreate \(createStatus)")
        }
        defer { ExtAudioFileDispose(extFileRef) }

        // Tell ExtAudioFile what format we'll feed it (float32 interleaved stereo @ 44.1k).
        var clientFmt = AudioStreamBasicDescription(
            mSampleRate: cdSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let setStatus = ExtAudioFileSetProperty(extFileRef,
                                                kExtAudioFileProperty_ClientDataFormat,
                                                UInt32(MemoryLayout.size(ofValue: clientFmt)),
                                                &clientFmt)
        guard setStatus == noErr else {
            throw AudioDecoderError.writeFailed("ClientDataFormat \(setStatus)")
        }

        var totalFrames: Int64 = 0
        while reader.status == .reading {
            guard let sb = output.copyNextSampleBuffer() else { break }
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }

            var lengthAtOffset = 0
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let s = CMBlockBufferGetDataPointer(bb,
                                                atOffset: 0,
                                                lengthAtOffsetOut: &lengthAtOffset,
                                                totalLengthOut: &totalLength,
                                                dataPointerOut: &dataPointer)
            if s != kCMBlockBufferNoErr || dataPointer == nil { continue }

            let frameCount = totalLength / 8 // 2 ch * 4 bytes (float32)
            if frameCount == 0 { continue }

            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(totalLength),
                    mData: UnsafeMutableRawPointer(dataPointer)
                )
            )
            let writeStatus = ExtAudioFileWrite(extFileRef, UInt32(frameCount), &abl)
            if writeStatus != noErr {
                throw AudioDecoderError.writeFailed("ExtAudioFileWrite \(writeStatus)")
            }
            totalFrames += Int64(frameCount)
        }

        if reader.status == .failed {
            throw AudioDecoderError.conversionFailed(reader.error?.localizedDescription ?? "unknown")
        }

        // Pad to a full CD sector boundary (588 frames). Required because CD-DA
        // is sector-quantized; trailing partial sector would be silently truncated.
        let remainder = totalFrames % 588
        if remainder != 0 {
            let pad = 588 - Int(remainder)
            let bytes = pad * 4
            let zero = [UInt8](repeating: 0, count: bytes)
            try zero.withUnsafeBufferPointer { buf in
                var abl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(bytes),
                        mData: UnsafeMutableRawPointer(mutating: buf.baseAddress)
                    )
                )
                // The client format is float32; pad zeroes are valid floats too.
                var clientFloat = AudioStreamBasicDescription(
                    mSampleRate: cdSampleRate,
                    mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsBigEndian | kLinearPCMFormatFlagIsPacked,
                    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                    mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
                _ = ExtAudioFileSetProperty(extFileRef,
                                            kExtAudioFileProperty_ClientDataFormat,
                                            UInt32(MemoryLayout.size(ofValue: clientFloat)),
                                            &clientFloat)
                let s = ExtAudioFileWrite(extFileRef, UInt32(pad), &abl)
                if s != noErr {
                    throw AudioDecoderError.writeFailed("pad write \(s)")
                }
            }
            totalFrames += Int64(pad)
        }

        return DecodedTrack(aiffURL: outURL, frameCount: totalFrames)
    }
}
