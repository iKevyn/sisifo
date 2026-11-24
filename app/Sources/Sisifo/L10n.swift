import AppKit

/// tradução de textos que chegam como String (rótulos, avisos, menus). Chave = texto em português.
func L(_ s: String) -> String { Bundle.main.localizedString(forKey: s, value: s, table: nil) }

enum Idioma {
    static var atual: String {
        let pref = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first ?? Locale.preferredLanguages.first ?? "pt"
        return pref.hasPrefix("en") ? "en" : "pt"
    }
    static var ingles: Bool { atual == "en" }
}

/// avisar no Mac cada mensagem nova do WhatsApp? Se o WhatsApp (ou outro app de WhatsApp) já está no Mac,
/// o padrão é não, pra não duplicar. As demandas continuam avisando sempre.
enum AvisoMensagens {
    static let chave = "avisarMensagens"
    static var outroAppDeWhats: Bool {
        ["net.whatsapp.WhatsApp", "desktop.WhatsApp", "me.paolino.fastsapp"].contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }
    static var ligado: Bool {
        get { UserDefaults.standard.object(forKey: chave) as? Bool ?? !outroAppDeWhats }
        set { UserDefaults.standard.set(newValue, forKey: chave) }
    }
}
