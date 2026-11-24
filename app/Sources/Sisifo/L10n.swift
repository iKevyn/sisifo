import Foundation

/// tradução de textos que chegam como String (rótulos, avisos, menus). Chave = texto em português.
func L(_ s: String) -> String { Bundle.main.localizedString(forKey: s, value: s, table: nil) }

enum Idioma {
    static var atual: String {
        let pref = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first ?? Locale.preferredLanguages.first ?? "pt"
        return pref.hasPrefix("en") ? "en" : "pt"
    }
    static var ingles: Bool { atual == "en" }
}
