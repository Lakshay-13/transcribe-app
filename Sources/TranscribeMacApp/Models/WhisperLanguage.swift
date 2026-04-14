import Foundation

struct WhisperLanguage: Hashable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let code: String?

    static let auto = WhisperLanguage(id: "auto", displayName: "Auto Detect", code: nil)

    static let common: [WhisperLanguage] = [
        .auto,
        WhisperLanguage(id: "en", displayName: "English", code: "en"),
        WhisperLanguage(id: "hi", displayName: "Hindi", code: "hi"),
        WhisperLanguage(id: "es", displayName: "Spanish", code: "es"),
        WhisperLanguage(id: "fr", displayName: "French", code: "fr"),
        WhisperLanguage(id: "de", displayName: "German", code: "de"),
        WhisperLanguage(id: "it", displayName: "Italian", code: "it"),
        WhisperLanguage(id: "pt", displayName: "Portuguese", code: "pt"),
        WhisperLanguage(id: "ru", displayName: "Russian", code: "ru"),
        WhisperLanguage(id: "ja", displayName: "Japanese", code: "ja"),
        WhisperLanguage(id: "ko", displayName: "Korean", code: "ko"),
        WhisperLanguage(id: "zh", displayName: "Chinese", code: "zh"),
        WhisperLanguage(id: "ar", displayName: "Arabic", code: "ar"),
        WhisperLanguage(id: "bn", displayName: "Bengali", code: "bn"),
        WhisperLanguage(id: "pa", displayName: "Punjabi", code: "pa"),
        WhisperLanguage(id: "ta", displayName: "Tamil", code: "ta"),
        WhisperLanguage(id: "te", displayName: "Telugu", code: "te"),
        WhisperLanguage(id: "mr", displayName: "Marathi", code: "mr"),
        WhisperLanguage(id: "gu", displayName: "Gujarati", code: "gu"),
        WhisperLanguage(id: "tr", displayName: "Turkish", code: "tr"),
        WhisperLanguage(id: "vi", displayName: "Vietnamese", code: "vi"),
        WhisperLanguage(id: "id", displayName: "Indonesian", code: "id"),
        WhisperLanguage(id: "th", displayName: "Thai", code: "th"),
        WhisperLanguage(id: "uk", displayName: "Ukrainian", code: "uk"),
        WhisperLanguage(id: "nl", displayName: "Dutch", code: "nl"),
        WhisperLanguage(id: "sv", displayName: "Swedish", code: "sv"),
        WhisperLanguage(id: "pl", displayName: "Polish", code: "pl"),
        WhisperLanguage(id: "ro", displayName: "Romanian", code: "ro"),
        WhisperLanguage(id: "cs", displayName: "Czech", code: "cs"),
        WhisperLanguage(id: "el", displayName: "Greek", code: "el"),
        WhisperLanguage(id: "he", displayName: "Hebrew", code: "he"),
        WhisperLanguage(id: "ur", displayName: "Urdu", code: "ur"),
        WhisperLanguage(id: "fa", displayName: "Persian", code: "fa"),
        WhisperLanguage(id: "ms", displayName: "Malay", code: "ms"),
        WhisperLanguage(id: "fil", displayName: "Filipino", code: "tl")
    ]
}
