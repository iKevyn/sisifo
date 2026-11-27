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

/// "Marcar como lido no WhatsApp": quando ligado, "ok, li", abrir a conversa e responder no Sísifo
/// mandam o azulzinho e tiram o "não lida" do celular. Fica no config.json (os servidores leem de lá).
/// "Ignorar conversas arquivadas": arquivada no WhatsApp não vira demanda nem não-lida. Padrão ligado.
enum IgnorarArquivadas {
    static var ligado: Bool {
        get { SisifoConfig.load().ignorarArquivadas != false }
        set { var c = SisifoConfig.load(); c.ignorarArquivadas = newValue; c.save() }
    }
}

enum LidoNoWhats {
    static var ligado: Bool {
        get { SisifoConfig.load().marcarLidoWhats == true }
        set { var c = SisifoConfig.load(); c.marcarLidoWhats = newValue; c.save() }
    }
}

/// "Mini WhatsApp": janelinha com todas as conversas (privadas e grupos). Padrão desligado.
enum MiniWhats {
    static let chave = "miniWhats"
    static var ligado: Bool {
        get { UserDefaults.standard.bool(forKey: chave) }
        set { UserDefaults.standard.set(newValue, forKey: chave); NotificationCenter.default.post(name: .miniWhatsMudou, object: nil) }
    }
}
extension Notification.Name { static let miniWhatsMudou = Notification.Name("miniWhatsMudou") }
