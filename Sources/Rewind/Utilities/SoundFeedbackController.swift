import AppKit

/// Plays the app's UI feedback sounds (save, recording start/end, error),
/// caching the loaded `NSSound` per cue and layering a boosted copy at high
/// volumes. Loading falls back to the source-tree `Resources` folder so sounds
/// play when running from a dev build outside an app bundle.
@MainActor
final class SoundFeedbackController {
    enum Cue: Hashable {
        case saved
        case recordingStart
        case recordingEnd
        case error
    }

    private var cache: [Cue: (primary: NSSound, boost: NSSound?)] = [:]

    /// Drops the cached sound for a cue so the next play reloads it (used when
    /// the user changes the selected sound).
    func invalidate(_ cue: Cue) {
        cache[cue] = nil
    }

    func play(
        _ cue: Cue,
        enabled: Bool,
        volume: Double,
        sound: FeedbackSound,
        defaultSoundName: String
    ) {
        guard enabled else { return }

        let soundName = sound.id == "default" ? defaultSoundName : sound.systemSoundName

        let primary: NSSound
        if let cached = cache[cue]?.primary {
            primary = cached
        } else if let loaded = loadSound(named: soundName) {
            primary = loaded
        } else {
            return
        }

        let boost: NSSound?
        if let cachedBoost = cache[cue]?.boost {
            boost = cachedBoost
        } else {
            boost = primary.copy() as? NSSound
        }

        cache[cue] = (primary, boost)

        let normalizedVolume = volume / 100
        let primaryVolume = Float(min(1, normalizedVolume * 1.25))
        let boostMix = max(0, normalizedVolume - 0.55) / 0.45
        let boostVolume = Float(min(1, boostMix * 0.9))

        primary.stop()
        primary.volume = primaryVolume
        primary.play()

        if boostVolume > 0, let boost {
            boost.stop()
            boost.volume = boostVolume
            boost.play()
        }
    }

    private func loadSound(named soundName: String) -> NSSound? {
        if let named = NSSound(named: NSSound.Name(soundName)) {
            return named
        }
        // Running from source (no app bundle): look in the repo Resources folder.
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Utilities
            .deletingLastPathComponent()  // Rewind
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // repo root
        let soundsURL = rootURL.appendingPathComponent("Resources/Sounds/\(soundName).wav")
        if let sound = NSSound(contentsOf: soundsURL, byReference: true) {
            return sound
        }
        let rootDevURL = rootURL.appendingPathComponent("Resources/\(soundName).wav")
        return NSSound(contentsOf: rootDevURL, byReference: true)
    }
}
