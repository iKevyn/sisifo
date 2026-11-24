import Foundation
import SwiftUI
import AppKit
import UserNotifications

struct Chat: Codable, Identifiable, Equatable {
    let jid: String
    let name: String
    let last: String
    let lastTs: Int
    let unread: Int
    /// grupo de trabalho (eu + gente da equipe); conversas privadas vêm sem isso
    var group: Bool? = nil
    var work: Bool? = nil
    var isGroup: Bool { group ?? jid.hasSuffix("@g.us") }
    var id: String { jid }
    var initials: String {
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        let letters = words.prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

struct Msg: Codable, Identifiable, Equatable {
    let id: String
    let jid: String
    let me: Bool
    let ts: Int
    let type: String
    let text: String
    let caption: String
    let media: Bool
    let transcript: String?
    /// quem mandou (só em grupo)
    var who: String? = nil
}

struct Incoming: Codable {
    let id: String
    let jid: String
    let ts: Int
    let name: String
    let text: String
}

/// Presença da conversa aberta (vem da ponte Baileys, nada é gravado).
struct Presence: Codable, Equatable {
    let typing: Bool
    let recording: Bool
    static let idle = Presence(typing: false, recording: false)
}

/// Mensagem citada quando você dá dois cliques num balão.
struct ReplyTarget: Identifiable, Equatable {
    let id: String
    let jid: String
    let me: Bool
    let text: String
    let type: String
}

struct StateResp: Codable {
    let connected: Bool
    let chats: [Chat]
    let messages: [Msg]
    let me: String?
    let dbTs: Int?
    let incoming: [Incoming]?
}

struct OkResp: Codable {
    let ok: Bool?
    let error: String?
    let id: String?
    let text: String?
}

struct Sticker: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let mine: Bool
}

struct StickersResp: Codable {
    let items: [Sticker]
}

/// arquivo esperando o enviar (arrastado, colado, + ou áudio gravado)
struct Anexo: Identifiable, Equatable {
    let id = UUID()
    let url: URL          // cópia dentro de App Support/ZapPrivado/enviados
    let nome: String
    var ext: String { url.pathExtension.lowercased() }
    var imagem: Bool { ["png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "tiff", "tif", "bmp"].contains(ext) }
    var audio: Bool { ["ogg", "opus", "mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac"].contains(ext) }
    var video: Bool { ["mp4", "mov"].contains(ext) }
    var icone: String { imagem ? "photo" : audio ? "waveform" : video ? "video" : "doc" }
}

struct SuggestionsResp: Codable {
    let items: [String]
}

/// Tudo · Privado (1:1) · Trabalho (grupos com eu + gente da equipe)
enum Filtro: String, CaseIterable, Identifiable {
    case tudo, privado, trabalho
    var id: String { rawValue }
    var nome: String { L(self == .tudo ? "Tudo" : self == .privado ? "Privado" : "Trabalho") }
}

/// pílulas de status por conversa (vêm das não lidas, demandas e marcações)
struct Selos: Equatable {
    var responder = false
    var demandas = 0
    var marcacoes = 0
}

/// o que a IA do Zap (servidor de demandas) leu dessa conversa
struct IAInfo: Equatable {
    let resumo: String
    let sugestao: String?
    let pensando: Bool
    let precisaResposta: Bool
}

@MainActor
final class ChatStore: ObservableObject {
    @Published var chats: [Chat] = []
    @Published var messages: [Msg] = []
    @Published var connected = false
    @Published var serverUp = false
    @Published var sending = false
    @Published var stickerSending = false
    @Published var stickers: [Sticker] = []
    @Published var suggestions: [String] = []
    @Published var lastSync: Date?
    @Published var lastDbTs: Int = 0
    @Published var transcribing: String?
    @Published var presence = Presence.idle
    @Published var replyTo: ReplyTarget?
    /// abrir o chat já nessa mensagem (pedido da demanda/marcação); some depois de rolar
    @Published var irPara: String?
    /// jid cujo campo de texto deve ganhar o foco ao abrir
    @Published var focar: String?
    @Published var onlyUnread = false
    @Published var soundOn: Bool {
        didSet { UserDefaults.standard.set(soundOn, forKey: "zp.sound") }
    }
    @Published var erro: String?
    @Published var syncing = false
    @Published var anexos: [Anexo] = []
    @Published var pinned: [String] = UserDefaults.standard.stringArray(forKey: "zp.pinned") ?? [] {
        didSet { UserDefaults.standard.set(pinned, forKey: "zp.pinned") }
    }
    /// conversa visível na tela agora (popover ou janela) — o ⌘V de imagem só vale com ela aberta
    var chatAberto: String?
    @Published var fileSending: String?

    /// resumo + resposta pronta por conversa (preenchido pelo Store de demandas)
    @Published var ia: [String: IAInfo] = [:]
    @Published var selos: [String: Selos] = [:]
    @Published var filtro: Filtro = Filtro(rawValue: UserDefaults.standard.string(forKey: "zap.filtro") ?? "") ?? .tudo {
        didSet { UserDefaults.standard.set(filtro.rawValue, forKey: "zap.filtro") }
    }
    /// grupos de trabalho conhecidos (o servidor manda junto da lista)
    var trabalho: Set<String> { Set(chats.filter { $0.work == true }.map(\.jid)) }
    func passa(_ jid: String, grupo: Bool) -> Bool {
        switch filtro {
        case .tudo: return true
        case .privado: return !grupo
        case .trabalho: return grupo && trabalho.contains(jid)
        }
    }
    var onIAOk: ((String) -> Void)?
    var onIARedo: ((String, String) -> Void)?
    /// mandei algo nessa conversa (some das não lidas na hora)
    var onEnviou: ((String) -> Void)?
    /// abrir a conversa na janela grande
    var onJanela: ((String) -> Void)?

    /// saiu da conversa: para de perguntar presença
    func fechar() {
        selected = nil
        presence = .idle
        replyTo = nil
    }

    private var firstRefresh = true
    private var lastUnreadCount = 0
    private var notified = Set<String>()
    @Published var selected: String?

    init() {
        soundOn = UserDefaults.standard.object(forKey: "zp.sound") as? Bool ?? true
    }

    private let base = Sisifo.chatBase
    private let session = URLSession.shared

    var selectedChat: Chat? { chats.first { $0.jid == selected } }
    /// só conversas privadas contam pro número da barra e pros sons (grupo é muito barulho)
    var totalUnread: Int { chats.filter { !$0.isGroup }.reduce(0) { $0 + $1.unread } }

    func refresh() async {
        var comps = URLComponents(string: base + "/state")!
        var items: [URLQueryItem] = [URLQueryItem(name: "since", value: String(lastDbTs))]
        if let jid = selected { items.append(URLQueryItem(name: "chat", value: jid)) }
        comps.queryItems = items
        guard let url = comps.url else { return }
        let prevDb = lastDbTs
        let prevUnread = totalUnread
        do {
            let (data, resp) = try await session.data(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { serverUp = false; return }
            let s = try JSONDecoder().decode(StateResp.self, from: data)
            let unreadNow = s.chats.filter { !$0.isGroup }.reduce(0) { $0 + $1.unread }
            if !firstRefresh {
                let novas = (s.incoming ?? []).filter { !notified.contains($0.id) }
                for m in novas.prefix(5) { notificar(m) }
                let chegouAqui = s.messages.contains { !$0.me && $0.ts > prevDb && $0.who == nil }
                if !novas.isEmpty || unreadNow > prevUnread || ((s.dbTs ?? 0) > prevDb && chegouAqui) {
                    som("receive")
                }
            }
            firstRefresh = false
            lastUnreadCount = unreadNow
            serverUp = true
            if chats != s.chats { chats = s.chats }
            if messages != s.messages { messages = s.messages }
            if connected != s.connected { connected = s.connected }
            lastDbTs = s.dbTs ?? 0
            lastSync = Date()
        } catch {
            serverUp = false
        }
    }

    private func notificar(_ m: Incoming) {
        notified.insert(m.id)
        guard AvisoMensagens.ligado else { return }   // o WhatsApp do Mac já avisa: não duplica
        let c = UNMutableNotificationContent()
        c.title = m.name
        c.body = m.text.count > 140 ? String(m.text.prefix(140)) + "…" : m.text
        c.sound = UNNotificationSound(named: UNNotificationSoundName("ReceivedMessage.caf"))
        c.userInfo = ["jid": m.jid]
        c.categoryIdentifier = "zp.msg"
        let req = UNNotificationRequest(identifier: "zp-" + m.id, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
    }

    func testarNotificacao() {
        let m = Incoming(id: "teste-\(Int(Date().timeIntervalSince1970))", jid: selected ?? "555500000000@s.whatsapp.net",
                         ts: Int(Date().timeIntervalSince1970), name: "Zap Privado", text: "Notificação de teste 👋")
        notificar(m)
    }

    // Sons reais do Messages.app deste macOS (não os genéricos /System/Library/Sounds)
    private let soundFiles: [String: [String]] = [
        "receive": [
            "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/AlertTones/ReceivedMessage.caf",
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/ReceivedMessage.caf",
        ],
        "send": [
            "/System/Library/PrivateFrameworks/IMDaemonCore.framework/Versions/A/Resources/Sent Message.aiff",
            "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/SentMessage.caf",
        ],
    ]

    func testarSom(_ nome: String) { som(nome) }

    private func som(_ nome: String) {
        guard soundOn else { return }
        var s: NSSound?
        for p in soundFiles[nome] ?? [] {
            if let found = NSSound(contentsOfFile: p, byReference: false) { s = found; break }
        }
        if s == nil { s = NSSound(named: NSSound.Name(nome == "receive" ? "Pop" : "Glass")) }
        guard let s else { return }
        s.stop()
        s.play()
    }

    func select(_ jid: String) async {
        guard selected != jid else { return }
        selected = jid
        presence = .idle
        replyTo = nil
        await markRead(jid)
        await refresh()
        await loadSuggestions(jid)
    }

    func markRead(_ jid: String) async {
        await post("/read", ["jid": jid], quiet: true)
    }

    func send(_ text: String, to jid: String, quoteId: String? = nil) async -> Bool {
        var body = ["jid": jid, "text": text]
        if let quoteId { body["quote"] = quoteId }
        sending = true
        erro = nil
        defer { sending = false }
        let r = await post("/send", body, quiet: false)
        guard r?.ok == true else {
            erro = r?.error ?? "Não foi possível enviar. A ponte está ligada?"
            return false
        }
        som("send")
        onEnviou?(jid)
        replyTo = nil
        await markRead(jid)
        await refresh()
        return true
    }

    /// Dois cliques num balão preenchem a citação do compositor.
    func setReply(_ m: Msg) {
        let raw = m.media ? m.caption : m.text
        let rotulo: String
        if m.type == "stickerMessage" { rotulo = "🎭 Figurinha" }
        else if m.type == "audioMessage" { rotulo = "🎙 Áudio" }
        else if m.type == "videoMessage" { rotulo = "🎬 Vídeo" }
        else if m.media { rotulo = "📷 Foto" }
        else { rotulo = "" }
        let texto = m.transcript ?? raw
        replyTo = ReplyTarget(id: m.id, jid: m.jid, me: m.me,
                              text: (texto.isEmpty ? rotulo : texto).replacingOccurrences(of: "\n", with: " "),
                              type: m.type)
    }

    /// Chamado pelo timer do app; silencioso e barato.
    func refreshPresence() async {
        guard let jid = selected else {
            if presence != .idle { presence = .idle }
            return
        }
        guard let enc = jid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: base + "/presence?chat=" + enc) else { return }
        do {
            let (data, resp) = try await session.data(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            let p = try JSONDecoder().decode(Presence.self, from: data)
            if presence != p { presence = p }
        } catch {}
    }

    @discardableResult
    private func post(_ path: String, _ body: [String: String], quiet: Bool) async -> OkResp? {
        guard let url = URL(string: base + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await session.data(for: req)
            let ok = try JSONDecoder().decode(OkResp.self, from: data)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                if !quiet { erro = ok.error ?? "Erro ao enviar" }
                return ok
            }
            return ok
        } catch {
            if !quiet { erro = error.localizedDescription }
            return nil
        }
    }

    func loadSuggestions(_ jid: String) async {
        var c = URLComponents(string: base + "/suggestions")!
        c.queryItems = [URLQueryItem(name: "chat", value: jid)]
        guard let url = c.url else { return }
        do {
            let (data, _) = try await session.data(from: url)
            let r = try JSONDecoder().decode(SuggestionsResp.self, from: data)
            if suggestions != r.items { suggestions = r.items }
        } catch {}
    }

    func loadStickers() async {
        guard let url = URL(string: base + "/stickers") else { return }
        do {
            let (data, _) = try await session.data(from: url)
            let r = try JSONDecoder().decode(StickersResp.self, from: data)
            if stickers != r.items { stickers = r.items }
        } catch { erro = "Não foi possível carregar as figurinhas" }
    }

    func stickerURL(_ id: String) -> URL {
        var c = URLComponents(string: base + "/sticker-img")!
        c.queryItems = [URLQueryItem(name: "id", value: id)]
        return c.url!
    }

    func sendSticker(_ id: String, to jid: String) async -> Bool {
        stickerSending = true
        erro = nil
        defer { stickerSending = false }
        let r = await post("/sticker", ["jid": jid, "id": id], quiet: false)
        guard r?.ok == true else {
            erro = r?.error ?? "Não foi possível enviar a figurinha"
            return false
        }
        som("send")
        onEnviou?(jid)
        await markRead(jid)
        await refresh()
        return true
    }

    func audioURL(_ jid: String, _ id: String) -> URL {
        var c = URLComponents(string: base + "/audio")!
        c.queryItems = [URLQueryItem(name: "jid", value: jid), URLQueryItem(name: "id", value: id)]
        return c.url!
    }

    func transcribe(_ jid: String, _ id: String) async {
        let key = jid + "|" + id
        guard transcribing == nil else { return }
        transcribing = key
        erro = nil
        defer { transcribing = nil }
        let r = await post("/transcribe", ["jid": jid, "id": id], quiet: false)
        if r?.ok == true { await refresh() }
    }

    func avatarURL(_ jid: String) -> URL {
        var c = URLComponents(string: base + "/avatar")!
        c.queryItems = [URLQueryItem(name: "jid", value: jid)]
        return c.url!
    }

    func thumbURL(_ jid: String, _ id: String) -> URL {
        var c = URLComponents(string: base + "/thumb")!
        c.queryItems = [URLQueryItem(name: "jid", value: jid), URLQueryItem(name: "id", value: id)]
        return c.url!
    }
    // MARK: - arrastar arquivo (imagem, áudio, vídeo, documento)

    static let fileTypes: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "tiff", "tif", "bmp",
                                         "ogg", "opus", "mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac",
                                         "mp4", "mov", "pdf", "zip", "doc", "docx", "xls", "xlsx", "csv", "txt"]

    func sendFiles(_ urls: [URL], to jid: String) async {
        for u in urls.prefix(10) { _ = await sendFile(u, to: jid) }
    }

    /// copia pra pasta do app (a ponte é outro processo e não tem acesso à Mesa/Downloads) e manda
    func sendFile(_ url: URL, to jid: String) async -> Bool {
        let ext = url.pathExtension.lowercased()
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sisifo/conversas/enviados", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
        do { try FileManager.default.copyItem(at: url, to: dst) } catch {
            erro = "Não consegui ler \(url.lastPathComponent)"
            return false
        }
        fileSending = url.lastPathComponent
        erro = nil
        defer {
            fileSending = nil
            try? FileManager.default.removeItem(at: dst)
        }
        let r = await post("/send-file", ["jid": jid, "path": dst.path], quiet: false)
        guard r?.ok == true else {
            erro = r?.error ?? "Não foi possível enviar o arquivo"
            return false
        }
        som("send")
        onEnviou?(jid)
        await markRead(jid)
        await refresh()
        return true
    }

    /// botão de sincronizar: puxa o que faltou da conversa aberta e recarrega tudo
    func syncNow() async {
        guard !syncing else { return }
        syncing = true
        erro = nil
        defer { syncing = false }
        var body: [String: String] = [:]
        if let jid = selected { body["jid"] = jid }
        let r = await post("/sync", body, quiet: true)
        if r?.ok != true { erro = r?.error ?? "Servidor local offline" }
        await refresh()
        await refreshPresence()
    }
    // MARK: - anexos (chips acima do campo; só vão quando der enviar)

    private var pastaEnviados: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sisifo/conversas/enviados", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// copia pra pasta do app (a ponte é outro processo e não lê Mesa/Downloads) e põe na fila
    func anexar(_ urls: [URL], nomes: [String]? = nil) {
        for (i, u) in urls.prefix(10).enumerated() {
            let ext = u.pathExtension.lowercased()
            let dst = pastaEnviados.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
            do { try FileManager.default.copyItem(at: u, to: dst) } catch {
                erro = "Não consegui ler \(u.lastPathComponent)"; continue
            }
            anexos.append(Anexo(url: dst, nome: nomes?[safe: i] ?? u.lastPathComponent))
        }
    }

    func tirarAnexo(_ a: Anexo) {
        anexos.removeAll { $0.id == a.id }
        try? FileManager.default.removeItem(at: a.url)
    }

    func limparAnexos() {
        for a in anexos { try? FileManager.default.removeItem(at: a.url) }
        anexos = []
    }

    /// manda os anexos; o texto vira legenda da primeira foto/vídeo (se não tiver, volta false e o texto vai separado)
    func enviarAnexos(to jid: String, legenda: String) async -> Bool {
        var legendaUsada = false
        let fila = anexos
        for a in fila {
            let leg = (!legendaUsada && (a.imagem || a.video)) ? legenda : ""
            if !leg.isEmpty { legendaUsada = true }
            fileSending = a.nome
            erro = nil
            let r = await post("/send-file", ["jid": jid, "path": a.url.path, "text": leg], quiet: false)
            fileSending = nil
            guard r?.ok == true else {
                erro = r?.error ?? "Não foi possível enviar \(a.nome)"
                return legendaUsada
            }
            anexos.removeAll { $0.id == a.id }
            try? FileManager.default.removeItem(at: a.url)
            som("send")
            onEnviou?(jid)
        }
        await markRead(jid)
        await refresh()
        return legendaUsada
    }

    /// ⌘V com imagem ou arquivo no clipboard (print, Finder, navegador)
    func colar() -> Bool {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            anexar(urls); return true
        }
        let tipos = pb.types ?? []
        guard tipos.contains(.png) || tipos.contains(.tiff), let img = NSImage(pasteboard: pb),
              let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("print-\(UUID().uuidString.prefix(6)).png")
        guard (try? png.write(to: f)) != nil else { return false }
        anexar([f], nomes: ["Imagem colada"])
        try? FileManager.default.removeItem(at: f)
        return true
    }

    func togglePin(_ jid: String) {
        if let i = pinned.firstIndex(of: jid) { pinned.remove(at: i) }
        else { pinned = Array((pinned + [jid]).suffix(4)) }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
