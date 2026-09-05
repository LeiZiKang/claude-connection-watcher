import Foundation

enum AppLanguage: String {
    case chinese = "zh-Hans"
    case english = "en"

    static func resolve(saved: String?, preferred: [String]) -> AppLanguage {
        if let saved, let language = AppLanguage(rawValue: saved) { return language }
        return preferred.first?.lowercased().hasPrefix("zh") == true ? .chinese : .english
    }
}

enum L10n {
    private static let lock = NSLock()
    private static var selected = AppLanguage.resolve(saved: UserDefaults.standard.string(forKey: "AppLanguage"),
                                                      preferred: Locale.preferredLanguages)
    static var language: AppLanguage {
        get { lock.lock(); defer { lock.unlock() }; return selected }
        set {
            lock.lock(); selected = newValue; lock.unlock()
            UserDefaults.standard.set(newValue.rawValue, forKey: "AppLanguage")
        }
    }
    static func text(_ chinese: String, _ english: String) -> String {
        language == .chinese ? chinese : english
    }
}

/// Store both variants so an existing warning changes language immediately.
struct LocalizedMessage {
    let chinese: String
    let english: String
    init(_ chinese: String, _ english: String) { self.chinese = chinese; self.english = english }
    var value: String { L10n.text(chinese, english) }
}

final class RefreshGate {
    private let lock = NSLock()
    private var pending = false
    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !pending else { return false }
        pending = true
        return true
    }
    func finish() { lock.lock(); pending = false; lock.unlock() }
}
