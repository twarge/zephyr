import AudioToolbox
import Foundation
import UserNotifications

/// The Zulip web app's notification sounds, bundled from Zephyr/Sounds
/// (Scripts/import-zulip-sounds.swift makes them), in two tiers chosen in
/// Settings: a prominent one for direct messages and mentions, and a
/// quieter one for other messages — those in the conversation or channel
/// being read, and in channels with notifications on. A soft swish says
/// your own message reached the server.
///
/// A banner carries its sound, so System Settings and Focus govern it;
/// with no banner (what you're reading, your own sends) it plays here.
enum MessageSounds {
    enum Tier {
        /// Direct messages and mentions.
        case personal
        case other
        case send
    }

    /// Preference keys. The two tiers store a web app sound name ("deep
    /// tom"), or "none" — the values of Zulip's own `notification_sound`.
    static let personalKey = "personalMessageSound"
    static let otherKey = "otherMessageSound"
    static let sendKey = "sendSound"
    static let defaultPersonal = "chime"
    /// The web app's own default, and its quietest.
    static let defaultOther = "zulip"
    static let none = "none"

    /// Every sound the web app offers, in its order.
    static let names = [
        "ascend", "beep_boop", "bink", "bright", "brlip", "chime", "deep tom", "ding",
        "double tap", "down", "dry bongos", "dutdut", "fast ascend", "flute", "friendly",
        "kick roll", "loud tintong", "metallic snare", "pan", "shaker", "simple",
        "stairs", "subtle", "swish", "tintong", "up", "wood block", "zaping", "zing",
        "zulip",
    ]

    static func label(_ name: String) -> String {
        let spaced = name.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// Plays the tier's sound, unless it's off or just played.
    static func play(_ tier: Tier) {
        if let file = take(tier) { play(file: file) }
    }

    /// The tier's sound for a banner to carry; nil when it's off or just
    /// played (the banner still shows).
    static func notificationSound(_ tier: Tier) -> UNNotificationSound? {
        take(tier).map { UNNotificationSound(named: UNNotificationSoundName("\($0).caf")) }
    }

    /// Settings' preview of a choice: always plays.
    static func preview(_ name: String) {
        guard names.contains(name) else { return }
        play(file: file(for: name))
    }

    // MARK: Playing

    private static var lastPlayed: [Tier: ContinuousClock.Instant] = [:]
    private static var soundIds: [String: SystemSoundID] = [:]

    /// The tier's file, recording that it plays now. A burst of messages
    /// (catching up after reconnecting) sounds once per tier.
    private static func take(_ tier: Tier) -> String? {
        let defaults = UserDefaults.standard
        let file: String?
        switch tier {
        case .personal:
            file = chosenFile(defaults.string(forKey: personalKey) ?? defaultPersonal)
        case .other:
            file = chosenFile(defaults.string(forKey: otherKey) ?? defaultOther)
        case .send:
            file = defaults.object(forKey: sendKey) as? Bool ?? true ? "send" : nil
        }
        guard let file else { return nil }
        let now = ContinuousClock.now
        if let last = lastPlayed[tier], now - last < .seconds(1) { return nil }
        lastPlayed[tier] = now
        return file
    }

    private static func chosenFile(_ name: String) -> String? {
        names.contains(name) ? file(for: name) : nil
    }

    /// The bundled file's name ("deep tom" → deep-tom.caf).
    private static func file(for name: String) -> String {
        name.replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
    }

    /// As a system sound: at the alert volume, and on iPhone silenced by
    /// the ring/silent switch.
    private static func play(file: String) {
        if soundIds[file] == nil {
            guard let url = Bundle.main.url(forResource: file, withExtension: "caf")
            else { return }
            var id: SystemSoundID = 0
            guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError
            else { return }
            #if os(macOS)
            // Not gated on "Play user interface sound effects": the
            // choices in Settings are the switch.
            var isUISound: UInt32 = 0
            AudioServicesSetProperty(
                kAudioServicesPropertyIsUISound, UInt32(MemoryLayout<SystemSoundID>.size), &id,
                UInt32(MemoryLayout<UInt32>.size), &isUISound)
            #endif
            soundIds[file] = id
        }
        if let id = soundIds[file] { AudioServicesPlaySystemSound(id) }
    }
}
