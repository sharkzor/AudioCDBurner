import Foundation
import AVFoundation
import AudioToolbox

/// One audio item the user added to the burn list.
struct AudioItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var displayName: String
    /// Duration in seconds at source sample rate. CD redbook frames are computed
    /// at 75 frames/sec from the decoded 44.1 kHz stream length later.
    var duration: TimeInterval
    /// True if the file format is acceptable / decodable.
    var isDecodable: Bool
    /// Tag-derived metadata (best-effort).
    var trackTitle: String?
    var albumTitle: String?
    var artist: String?

    static func from(url: URL) -> AudioItem {
        var dur: TimeInterval = 0

        // AVAudioFile uses ExtAudioFile under the hood and reliably reports
        // length/sampleRate for FLAC/MP3/AAC/M4A/WAV/AIFF on macOS.
        if let f = try? AVAudioFile(forReading: url) {
            let sr = f.processingFormat.sampleRate
            if sr > 0 { dur = Double(f.length) / sr }
        }

        let tags = readTags(url: url)
        let displayName = tags.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? url.deletingPathExtension().lastPathComponent

        let ok = dur > 0
        return AudioItem(url: url,
                         displayName: displayName,
                         duration: dur,
                         isDecodable: ok,
                         trackTitle: tags.title,
                         albumTitle: tags.album,
                         artist: tags.artist)
    }

    /// Read tag metadata via AudioToolbox's InfoDictionary. This handles
    /// FLAC (Vorbis comments), MP3 (ID3), AAC/M4A (iTunes atoms), WAV INFO,
    /// AIFF, etc. uniformly — returns lowercase keys like "title", "album",
    /// "artist".
    private static func readTags(url: URL) -> (title: String?, album: String?, artist: String?) {
        var fileID: AudioFileID?
        let openStatus = AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID)
        guard openStatus == noErr, let f = fileID else { return (nil, nil, nil) }
        defer { AudioFileClose(f) }

        var dict: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        let status = AudioFileGetProperty(f,
                                          kAudioFilePropertyInfoDictionary,
                                          &size,
                                          &dict)
        guard status == noErr,
              let d = dict?.takeRetainedValue() as? [String: Any] else {
            return (nil, nil, nil)
        }

        // Keys from AudioFile.h: kAFInfoDictionary_Title / _Album / _Artist
        // == "title" / "album" / "artist" (case-insensitive across formats).
        func pick(_ keys: [String]) -> String? {
            for k in keys {
                if let v = d[k] as? String, !v.isEmpty { return v }
                // Some containers spell keys differently
                for (dk, dv) in d where dk.caseInsensitiveCompare(k) == .orderedSame {
                    if let s = dv as? String, !s.isEmpty { return s }
                }
            }
            return nil
        }
        return (pick(["title"]), pick(["album"]), pick(["artist"]))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

enum GapMode: String, CaseIterable, Identifiable {
    case twoSeconds = "2 second gap"
    case gapless   = "Gapless"
    var id: String { rawValue }
}

/// Format MM:SS or H:MM:SS.
func formatDuration(_ s: TimeInterval) -> String {
    if !s.isFinite || s < 0 { return "--:--" }
    let total = Int(s.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let sec = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
    return String(format: "%d:%02d", m, sec)
}

/// Audio CD capacity. Standard 80-minute CD-R = 4500 sectors/min * 80 = 360000 sectors.
/// We expose a soft warning threshold of 79:30 to leave headroom for lead-in/out.
let cdCapacitySeconds: TimeInterval = 80 * 60
let cdSoftLimitSeconds: TimeInterval = 79 * 60 + 30

/// CD-Text per-field practical safe limit. Spec allows up to 160 bytes per pack
/// type, but most authoring tools cap titles at 64 ASCII chars.
let cdTextMaxChars = 64
