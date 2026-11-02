import Foundation

/// Preserve settings from older builds while retiring their previous key names.
public enum PreferenceMigration {
    private static let keyRenames: [(legacy: String, current: String)] = [
        ("metatron_speech_mode", "presstowrite_speech_mode"),
        ("metatron_auto_copy", "presstowrite_auto_copy"),
        ("metatron_auto_insert", "presstowrite_auto_insert"),
        ("metatron_pill_orientation", "presstowrite_pill_orientation"),
        ("metatron_hotkey", "presstowrite_hotkey"),
        ("metatron_mode", "presstowrite_mode"),
        ("metatron_style", "presstowrite_style"),
        ("metatron_auto_adaptive", "presstowrite_auto_adaptive"),
        ("metatron_sound", "presstowrite_sound"),
        ("metatron_vocab", "presstowrite_vocab"),
        ("metatron_replacements", "presstowrite_replacements"),
        ("metatron_correction_learning", "presstowrite_correction_learning"),
        ("metatron_learned_vocabulary", "presstowrite_learned_vocabulary"),
        ("metatron_microphone_uid", "presstowrite_microphone_uid"),
        ("metatron_pill_x", "presstowrite_pill_x"),
        ("metatron_pill_y", "presstowrite_pill_y"),
        ("metatron_pill_snap", "presstowrite_pill_snap"),
        ("metatron_pill_display", "presstowrite_pill_display")
    ]

    public static func migrate(_ defaults: UserDefaults = .standard) {
        for (legacy, current) in keyRenames {
            if defaults.object(forKey: current) == nil,
               let saved = defaults.object(forKey: legacy) {
                defaults.set(saved, forKey: current)
            }
            defaults.removeObject(forKey: legacy)
        }

        // Incognito also paused correction learning. With no history setting left,
        // keep learning off for anyone who had chosen Incognito.
        let retention = defaults.object(forKey: "presstowrite_retention") ?? defaults.object(forKey: "metatron_retention")
        if retention as? String == "Incognito (Never save history)" {
            defaults.set(false, forKey: "presstowrite_correction_learning")
        }

        // Cloud transcription and its credentials remain retired, never copied.
        // History retention is retired too: no dictation is ever kept.
        for key in [
            "metatron_engine", "metatron_groq_key", "metatron_openai_key",
            "presstowrite_engine", "presstowrite_groq_key", "presstowrite_openai_key",
            "metatron_retention", "presstowrite_retention"
        ] {
            defaults.removeObject(forKey: key)
        }
    }
}
