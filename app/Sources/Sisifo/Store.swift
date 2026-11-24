import Foundation
import AppKit
import SwiftUI

struct Demand: Codable, Identifiable, Equatable {
    let id: String
    let jid: String
    let title: String
    let detail: String
    let client: String
    let who: String
    let chatName: String
    let isGroup: Bool
    let ts: Int
    let quote: String
    let due: String?
    let urgent: Bool
    let status: String
    let autoDone: Bool
    let doneAt: Int?
    let isNew: Bool
    let mine: Bool
    let area: String
    /// quantas fotos de referência mandaram junto
    var imgs: Int? = nil
    var imgCount: Int { imgs ?? 0 }
    /// quem pegou: "claude" (cliquei em Claude Code) ou "eu" (disse no Zap que tô vendo / marquei na mão)
    var doing: String? = nil
    var doingAt: Int? = nil
    /// mensagem do pedido (pra abrir o chat já nela)
    var msgId: String? = nil
    /// "parece pronto": "eu" (mandei "pronto/subiu…") ou "claude" (sessão do Claude parou). Só sugere.
    var doneHint: String? = nil
    var doneHintQuote: String? = nil
    var fazendoTexto: String? {
        guard let doing else { return nil }
        let m = doingAt.map { max(0, (Int(Date().timeIntervalSince1970) - $0) / 60) }
        let t = m.map { $0 < 60 ? "\($0) min" : "\($0 / 60) h" } ?? ""
        return doing == "claude" ? "Claude fazendo" + (t.isEmpty ? "" : " · " + t) : "fazendo (tu)" + (t.isEmpty ? "" : " · " + t)
    }
    /// "respondida" (outra pessoa já respondeu) ou "esperando_cliente" (falta o cliente mandar algo)
    var espera: String? = nil
    var esperaPor: String? = nil
    var esperaNota: String? = nil
    var esperaTexto: String? { esperaRotulo(espera, esperaPor, esperaNota) }

    var areaLabel: String {
        switch area { case "trafego": return "tráfego"; case "operacao": return "operação"; case "dev": return "dev"; default: return area }
    }

    var waitMinutes: Int { max(0, (Int(Date().timeIntervalSince1970) - ts) / 60) }

    /// número grande + unidade ("3" "h")
    var waitParts: (String, String) {
        let m = waitMinutes
        if m < 1 { return ("agora", "") }
        if m < 60 { return ("\(m)", "min") }
        if m < 60 * 48 { return ("\(m / 60)", "h") }
        return ("\(m / 1440)", m / 1440 == 1 ? "dia" : "dias")
    }
    var waitColor: Color {
        let m = waitMinutes
        if m < 120 { return Mood.calm }
        if m < 360 { return Mood.warm }
        return Mood.hot
    }

    enum DueState { case late, today, tomorrow, later(String) }
    var dueState: DueState? {
        guard let due, let d = Self.ymd.date(from: due) else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        if d < today { return .late }
        if cal.isDateInToday(d) { return .today }
        if cal.isDateInTomorrow(d) { return .tomorrow }
        return .later(Self.short.string(from: d))
    }
    static let ymd: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "America/Sao_Paulo"); return f }()
    static let short: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "EEE dd/MM"; return f }()

    var priority: Int {
        var p = 0
        if case .late = dueState { p -= 3 }
        if case .today = dueState { p -= 2 }
        if urgent { p -= 2 }
        return p
    }
}

/// texto da pílula de estado
func esperaRotulo(_ e: String?, _ por: String?, _ nota: String?) -> String? {
    switch e {
    case "respondida": return por.map { "respondida por \($0)" } ?? "já respondida"
    case "esperando_cliente": return nota.map { "esperando cliente · \($0)" } ?? "esperando cliente"
    default: return nil
    }
}

enum Mood {
    static let calm = Color(red: 0.16, green: 0.70, blue: 0.47)
    static let warm = Color(red: 0.93, green: 0.60, blue: 0.13)
    static let hot = Color(red: 0.93, green: 0.36, blue: 0.33)
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
}

struct ClientGroup: Identifiable, Equatable {
    let name: String
    let demands: [Demand]
    var id: String { name }
    var oldest: Demand { demands.min { $0.ts < $1.ts }! }
    var face: Demand { demands.first { $0.isGroup } ?? demands[0] }
    var people: [String] { Array(NSOrderedSet(array: demands.map(\.who).filter { !$0.isEmpty })) as? [String] ?? [] }
    var priority: Int { demands.map(\.priority).min() ?? 0 }
}

/// alguém te marcou (@) ou respondeu tua mensagem num grupo; a IA resume em 1 linha
struct Mention: Codable, Identifiable, Equatable {
    let id: String
    let jid: String
    let ts: Int
    let how: String
    let chatName: String
    let client: String
    let who: String
    let quote: String
    let summary: String
    let kind: String
    let urgent: Bool
    let seen: Bool
    let ok: Bool
    let demandId: String?
    /// "respondida" (outra pessoa já respondeu) ou "esperando_cliente" (falta o cliente mandar algo)
    var espera: String? = nil
    var esperaPor: String? = nil
    var esperaNota: String? = nil
    var esperaTexto: String? { esperaRotulo(espera, esperaPor, esperaNota) }

    var kindLabel: (String, String, Color) {
        switch kind {
        case "fazer": return ("pra fazer", "hammer.fill", Mood.warm)
        case "aviso": return ("só aviso", "info.circle.fill", .secondary)
        case "resolvido": return ("já resolvido", "checkmark", Mood.calm)
        default: return ("responder", "bubble.left.fill", .blue)
        }
    }
    var ago: String {
        let m = max(0, (Int(Date().timeIntervalSince1970) - ts) / 60)
        if m < 1 { return "agora" }
        if m < 60 { return "\(m) min" }
        if m < 60 * 48 { return "\(m / 60) h" }
        return "\(m / 1440) d"
    }
}
struct MentionsResp: Codable, Equatable { let unseen: Int; let items: [Mention] }

/// conversa com mensagem que eu ainda não li em aparelho nenhum, já resumida pela IA
struct UnreadChat: Codable, Identifiable, Equatable {
    struct Line: Codable, Equatable, Hashable { let me: Bool; let who: String; let text: String; let ts: Int }
    let jid: String
    let name: String
    let isGroup: Bool
    let client: String
    let count: Int
    let lastTs: Int
    let summary: String
    let needsReply: Bool
    let urgent: Bool
    let kind: String
    let suggestion: String?
    let pending: Bool
    let failed: Bool
    let demands: Int
    let tail: [Line]
    /// "respondida" (outra pessoa já respondeu) ou "esperando_cliente" (falta o cliente mandar algo)
    var espera: String? = nil
    var esperaPor: String? = nil
    var esperaNota: String? = nil
    var esperaTexto: String? { esperaRotulo(espera, esperaPor, esperaNota) }
    var id: String { jid }
    var ago: String {
        let m = max(0, (Int(Date().timeIntervalSince1970) - lastTs) / 60)
        if m < 1 { return "agora" }
        if m < 60 { return "\(m) min" }
        if m < 60 * 48 { return "\(m / 60) h" }
        return "\(m / 1440) d"
    }
    /// título: grupo = nome do grupo; conversa direta = pessoa
    var title: String { name }
}
struct UnreadResp: Codable, Equatable { let busy: Int; let needReply: Int; let items: [UnreadChat] }

private struct DemandsResp: Codable { let connected: Bool; let scanning: Int; let booted: Bool; let open: [Demand]; let doneToday: [Demand]; var mentions: MentionsResp? = nil; var unread: UnreadResp? = nil }
private struct PromptResp: Codable { let text: String }

enum Tab: String { case zap, open, mentions }

/// layout do popover e da janela (Ajustes ⚙︎ › Layout)
enum Layout: String, CaseIterable, Identifiable {
    case classico, caixa, conversa, hoje
    var id: String { rawValue }
    var nome: String {
        switch self {
        case .classico: return "Clássico (abas)"
        case .caixa: return "A · Caixa única"
        case .conversa: return "B · Conversa no centro"
        case .hoje: return "C · Hoje (um de cada vez)"
        }
    }
}

/// um item da caixa única: conversa pra responder, demanda, marcação ou só pra saber
struct ItemFeed: Identifiable, Equatable {
    enum Tipo: Int, CaseIterable { case responder = 0, marcacao = 1, demanda = 2, saber = 3, aguardando = 4 }
    let id: String
    let tipo: Tipo
    let jid: String
    let nome: String
    let grupo: Bool
    let ts: Int
    let resumo: String
    let urgente: Bool
    var unread: UnreadChat? = nil
    var demand: Demand? = nil
    var mention: Mention? = nil
    /// pílula "respondida por X" / "esperando cliente"
    var esperaTexto: String? { demand?.esperaTexto ?? unread?.esperaTexto ?? mention?.esperaTexto }
    var ago: String {
        let m = max(0, (Int(Date().timeIntervalSince1970) - ts) / 60)
        if m < 1 { return "agora" }
        if m < 60 { return "\(m) min" }
        if m < 60 * 48 { return "\(m / 60) h" }
        return "\(m / 1440) d"
    }
}

@MainActor
final class Store: ObservableObject {
    @Published var open: [Demand] = []
    @Published var doneToday: [Demand] = []
    @Published var connected = false
    @Published var serverUp = false
    @Published var scanning = 0
    @Published var booted = true
    @Published var tab: Tab = .zap
    @Published var unread: [UnreadChat] = []
    @Published var unreadBusy = 0
    @Published var expandedChat: String?
    @Published var showChatter = false
    @Published var showDone = false
    /// texto da resposta que eu tô editando, por conversa
    @Published var drafts: [String: String] = [:]
    @Published var sending: Set<String> = []
    @Published var redoing: Set<String> = []
    @Published var sendError: [String: String] = [:]
    @Published var clientFilter: String?
    @Published var expanded: String?
    @Published var showOthers = false
    @Published var mentions: [Mention] = []
    @Published var mentionsUnseen = 0
    @Published var showOkMentions = false
    /// popover aberto agora (só conta como "vi" se estiver na tela)
    @Published var popoverOpen = false {
        didSet { if popoverOpen && tab == .mentions { seeMentions() } }
    }

    /// conversas privadas de verdade (o antigo Zap Privado, servidor :47831)
    let zp = ChatStore()
    /// popover: conversa aberta dentro da aba Zap (nil = lista)
    @Published var zapChat: String?
    /// popover: aba Zap mostrando todas as conversas em vez das não lidas resumidas
    @Published var zapTodas = false
    @Published var layout: Layout = Layout(rawValue: UserDefaults.standard.string(forKey: "zap.layout") ?? "") ?? .classico {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "zap.layout"); onLayout?() }
    }
    var onLayout: (() -> Void)?
    /// chip escolhido na caixa única (nil = tudo)
    @Published var chip: ItemFeed.Tipo?
    /// modo Hoje: itens que mandei "pra depois" nesta sessão
    @Published var depois: Set<String> = []

    var onChange: (() -> Void)?
    var onNew: (([Demand]) -> Void)?
    var onClaude: ((Demand) -> Void)?
    var onClaudeClient: ((ClientGroup) -> Void)?
    var onOpenWindow: (() -> Void)?
    /// abrir uma conversa privada na janela
    var onOpenChat: ((String) -> Void)?

    let base = URL(string: Sisifo.appBase)!

    func avatarURL(_ jid: String) -> URL {
        URL(string: "/avatar?jid=\(jid.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? jid)", relativeTo: base)!
    }

    func imgURL(_ d: Demand, _ n: Int) -> URL {
        URL(string: "/img?id=\(d.id)&n=\(n)", relativeTo: base)!
    }
    /// abre a foto no Preview
    func openImg(_ d: Demand, _ n: Int) {
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: URL(string: "/img-path?id=\(d.id)&n=\(n)", relativeTo: base)!),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let p = j["path"] as? String else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: p))
        }
    }

    /// só o que é trabalho de dev (meu)
    /// quem ninguém pegou primeiro, depois as que eu ou o Claude já estamos fazendo (ordem estável)
    var mine: [Demand] {
        let m = open.filter { $0.mine && $0.espera == nil }
        return m.filter { $0.doing == nil } + m.filter { $0.doing != nil }
    }
    /// minhas, mas parada: outra pessoa já respondeu ou estamos esperando o cliente
    var aguardando: [Demand] { open.filter { $0.mine && $0.espera != nil } }
    /// conversas onde acabei de mandar mensagem pelo app: o chat fica aberto pra eu mandar mais
    @Published var segurar: Set<String> = []
    var others: [Demand] { open.filter { !$0.mine }.sorted { $0.ts < $1.ts } }

    var sortedOpen: [Demand] {
        mine.sorted { ($0.priority, $0.ts) < ($1.priority, $1.ts) }
    }
    var visible: [Demand] {
        let list = sortedOpen
        guard let c = clientFilter else { return list }
        return list.filter { $0.client == c }
    }
    /// clientes com demanda aberta (mais demandas primeiro) + um jid pra foto
    var clients: [(name: String, jid: String, isGroup: Bool, count: Int)] {
        var dict: [String: (String, Bool, Int, Int)] = [:]
        for d in mine {
            let cur = dict[d.client]
            dict[d.client] = (cur?.0 ?? d.jid, cur?.1 ?? d.isGroup, (cur?.2 ?? 0) + 1, min(cur?.3 ?? d.ts, d.ts))
        }
        return dict.map { (name: $0.key, jid: $0.value.0, isGroup: $0.value.1, count: $0.value.2) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }
    var oldest: Demand? { mine.min { $0.ts < $1.ts } }

    /// um card por cliente: urgentes/atrasados primeiro, depois quem espera há mais tempo
    var groups: [ClientGroup] {
        Dictionary(grouping: sortedOpen, by: \.client)
            .map { ClientGroup(name: $0.key, demands: $0.value) }
            .sorted { ($0.priority, $0.oldest.ts) < ($1.priority, $1.oldest.ts) }
    }

    // MARK: rede
    func refresh() async {
        var r = URLRequest(url: URL(string: "/demands", relativeTo: base)!)
        r.timeoutInterval = 6
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let x = try JSONDecoder().decode(DemandsResp.self, from: d)
            // só publica o que mudou (cada atribuição invalidava o SwiftUI do painel a cada 5 s)
            if !serverUp { serverUp = true }
            if connected != x.connected { connected = x.connected }
            if scanning != x.scanning { scanning = x.scanning }
            if booted != x.booted { booted = x.booted }
            if x.open != open { open = x.open }
            if x.doneToday != doneToday { doneToday = x.doneToday }
            if let m = x.mentions {
                if m.items != mentions { mentions = m.items }
                if m.unseen != mentionsUnseen { mentionsUnseen = m.unseen }
                if popoverOpen && tab == .mentions { seeMentions() }
            }
            if let u = x.unread {
                if u.items != unread { unread = u.items }
                if u.busy != unreadBusy { unreadBusy = u.busy }
            }
            syncIA()
            if let c = clientFilter, !mine.contains(where: { $0.client == c }) { clientFilter = nil }
            let fresh = x.open.filter { $0.isNew }
            if !fresh.isEmpty {
                let minhas = fresh.filter(\.mine)
                if !minhas.isEmpty { onNew?(minhas) }
                await post("/notified", ["ids": fresh.map(\.id)])
            }
        } catch {
            if serverUp { serverUp = false }
        }
        onChange?()
    }

    @discardableResult
    func post(_ path: String, _ body: [String: Any]) async -> Bool {
        var r = URLRequest(url: URL(string: path, relativeTo: base)!)
        r.httpMethod = "POST"
        r.timeoutInterval = 8
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return ((try? await URLSession.shared.data(for: r))?.1 as? HTTPURLResponse)?.statusCode == 200
    }

    func prompt(for d: Demand) async -> String {
        var r = URLRequest(url: URL(string: "/prompt?id=\(d.id)", relativeTo: base)!)
        r.timeoutInterval = 5
        if let (data, _) = try? await URLSession.shared.data(for: r), let p = try? JSONDecoder().decode(PromptResp.self, from: data) { return p.text }
        return "Demanda do \(d.client) (\(d.who)): \(d.title). \(d.detail)\nMensagem original: \"\(d.quote)\"\n\nLê o contexto do \(d.client) na memória, me diz o plano rapidinho e faz."
    }

    func prompt(forClient name: String) async -> String {
        let q = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        var r = URLRequest(url: URL(string: "/prompt-client?client=\(q)", relativeTo: base)!)
        r.timeoutInterval = 5
        if let (data, _) = try? await URLSession.shared.data(for: r), let p = try? JSONDecoder().decode(PromptResp.self, from: data) { return p.text }
        let list = mine.filter { $0.client == name }.enumerated().map { "\($0.offset + 1). \($0.element.title). \($0.element.detail)" }.joined(separator: "\n")
        return "Demandas do \(name) pelo WhatsApp:\n\n\(list)\n\nLê o contexto do \(name) na memória, me diz o plano rapidinho pra cada uma e vai fazendo."
    }

    // MARK: ações (otimistas)
    func doneAll(_ g: ClientGroup) {
        let ids = Set(g.demands.map(\.id))
        withAnimation(.spring(response: 0.35)) { open.removeAll { ids.contains($0.id) } }
        onChange?()
        Task { for id in ids { await post("/done", ["id": id]) }; await refresh() }
    }
    func done(_ d: Demand) {
        withAnimation(.spring(response: 0.35)) { open.removeAll { $0.id == d.id } }
        onChange?()
        Task { await post("/done", ["id": d.id]); await refresh() }
    }
    /// passa a demanda pra alguém da equipe 
    static var team: [(key: String, name: String, area: String)] {
        let c = SisifoConfig.load()
        return [("eu", "\(c.nome) (eu)", "eu")] + c.equipe.map { p in
            (key: p.nome.split(separator: " ").first.map { String($0).folding(options: .diacriticInsensitive, locale: nil).lowercased() } ?? p.nome, name: p.nome, area: "equipe")
        }
    }
    func move(_ d: Demand, to owner: String) {
        Task { await post("/owner", ["id": d.id, "owner": owner]); await refresh() }
    }
    func reopen(_ d: Demand) {
        withAnimation(.spring(response: 0.35)) { doneToday.removeAll { $0.id == d.id } }
        Task { await post("/reopen", ["id": d.id]); await refresh() }
    }
    func ignore(_ d: Demand) {
        withAnimation(.spring(response: 0.35)) { open.removeAll { $0.id == d.id } }
        onChange?()
        Task { await post("/ignore", ["id": d.id]); await refresh() }
    }
    // MARK: marcações
    var mentionsOpen: [Mention] { mentions.filter { !$0.ok && $0.espera == nil } }
    var mentionsEspera: [Mention] { mentions.filter { !$0.ok && $0.espera != nil } }
    var mentionsDone: [Mention] { mentions.filter(\.ok) }
    /// abriu a aba Marcações = viu tudo, contador zera
    func seeMentions() {
        guard mentionsUnseen > 0 else { return }
        mentionsUnseen = 0
        onChange?()
        Task { await post("/mentions/seen", [:]) }
    }
    func mentionOK(_ m: Mention, _ ok: Bool = true) {
        withAnimation(.spring(response: 0.35)) {
            if let i = mentions.firstIndex(where: { $0.id == m.id }) {
                let x = mentions[i]
                mentions[i] = Mention(id: x.id, jid: x.jid, ts: x.ts, how: x.how, chatName: x.chatName, client: x.client, who: x.who,
                                      quote: x.quote, summary: x.summary, kind: x.kind, urgent: x.urgent, seen: true, ok: ok, demandId: x.demandId,
                                      espera: x.espera, esperaPor: x.esperaPor, esperaNota: x.esperaNota)
            }
        }
        onChange?()
        Task { await post("/mentions/ok", ["id": m.id, "ok": ok]); await refresh() }
    }
    // MARK: não lidas
    /// precisa de resposta minha (urgente primeiro, depois quem espera há mais tempo)
    var toReply: [UnreadChat] { unread.filter { $0.needsReply && $0.espera == nil }.sorted { ($0.urgent ? 0 : 1, $0.lastTs) < ($1.urgent ? 0 : 1, $1.lastTs) } }
    /// só pra saber (avisos, papo de grupo); ainda lendo = fica aqui também
    var toKnow: [UnreadChat] { unread.filter { !$0.needsReply || $0.espera != nil } }
    func draft(_ c: UnreadChat) -> String { drafts[c.jid] ?? c.suggestion ?? "" }
    func unreadOK(_ c: UnreadChat, motivo: String? = nil) {
        withAnimation(.spring(response: 0.35)) { unread.removeAll { $0.jid == c.jid } }
        drafts[c.jid] = nil
        onChange?()
        Task { await post("/unread/ok", ["jid": c.jid, "motivo": motivo ?? ""]); await refresh() }
        if !c.isGroup { Task { await zp.markRead(c.jid); await zp.refresh() } }
    }
    func unreadOKAll(_ list: [UnreadChat]) {
        let ids = Set(list.map(\.jid))
        withAnimation(.spring(response: 0.35)) { unread.removeAll { ids.contains($0.jid) } }
        onChange?()
        Task { for j in ids { await post("/unread/ok", ["jid": j]) }; await refresh() }
        Task { for c in list where !c.isGroup { await zp.markRead(c.jid) }; await zp.refresh() }
    }
    func redo(_ c: UnreadChat, hint: String = "") {
        redoing.insert(c.jid)
        drafts[c.jid] = nil
        syncIA()
        Task {
            await post("/unread/redo", ["jid": c.jid, "hint": hint])
            redoing.remove(c.jid)
            await refresh()
        }
    }

    /// passa o resumo e a resposta pronta pro chat de verdade (privadas e grupos) + pílulas de cada conversa
    func syncIA() {
        var sl: [String: Selos] = [:]
        for c in unread where c.needsReply { sl[c.jid, default: Selos()].responder = true }
        for d in mine { sl[d.jid, default: Selos()].demandas += 1 }
        for x in mentionsOpen { sl[x.jid, default: Selos()].marcacoes += 1 }
        if zp.selos != sl { zp.selos = sl }
        var m: [String: IAInfo] = [:]
        for c in unread {
            let pensando = redoing.contains(c.jid) || (c.needsReply && c.pending && c.suggestion == nil)
            m[c.jid] = IAInfo(resumo: c.summary, sugestao: pensando ? nil : c.suggestion,
                              pensando: pensando, precisaResposta: c.needsReply)
        }
        if zp.ia != m { zp.ia = m }
    }

    /// liga o chat às ações das não lidas (uma vez, no início)
    func ligarConversas() {
        zp.onIAOk = { [weak self] jid in
            guard let self, let c = self.unread.first(where: { $0.jid == jid }) else { return }
            self.unreadOK(c)
        }
        zp.onIARedo = { [weak self] jid, hint in
            guard let self, let c = self.unread.first(where: { $0.jid == jid }) else { return }
            self.redo(c, hint: hint)
        }
        zp.onEnviou = { [weak self] jid in
            guard let self else { return }
            self.segurar.insert(jid)
            if self.unread.contains(where: { $0.jid == jid }) {
                withAnimation(.spring(response: 0.35)) { self.unread.removeAll { $0.jid == jid } }
                self.syncIA()
                self.onChange?()
            }
            Task { await self.refresh() }
        }
    }

    /// abre a conversa privada dentro do popover (aba Zap)
    func abrirConversa(_ jid: String) {
        tab = .zap
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { zapChat = jid }
        Task { await zp.select(jid) }
    }
    // MARK: caixa única (layouts A e C)
    func passa(_ jid: String, grupo: Bool) -> Bool { zp.passa(jid, grupo: grupo) }
    /// tudo que pede algo de mim, já filtrado por Tudo/Privado/Trabalho, mais urgente primeiro
    var feed: [ItemFeed] {
        var out: [ItemFeed] = []
        for c in unread where passa(c.jid, grupo: c.isGroup) {
            out.append(ItemFeed(id: "u:" + c.jid, tipo: c.espera != nil ? .aguardando : (c.needsReply ? .responder : .saber), jid: c.jid, nome: c.name, grupo: c.isGroup,
                                ts: c.lastTs, resumo: c.summary.isEmpty ? (c.pending ? "lendo…" : (c.tail.last.map { "\($0.who): \($0.text)" } ?? "")) : c.summary,
                                urgente: c.urgent, unread: c))
        }
        for d in mine where passa(d.jid, grupo: d.isGroup) {
            out.append(ItemFeed(id: "d:" + d.id, tipo: .demanda, jid: d.jid, nome: d.isGroup ? d.chatName : d.who, grupo: d.isGroup,
                                ts: d.ts, resumo: d.title, urgente: d.urgent || d.priority < 0, demand: d))
        }
        for x in mentionsOpen where passa(x.jid, grupo: true) {
            out.append(ItemFeed(id: "m:" + x.id, tipo: .marcacao, jid: x.jid, nome: x.chatName, grupo: true,
                                ts: x.ts, resumo: x.summary, urgente: x.urgent, mention: x))
        }
        // parados: já respondida por alguém da equipe ou esperando o cliente (saem de Responder/Fazer)
        for d in aguardando where passa(d.jid, grupo: d.isGroup) {
            out.append(ItemFeed(id: "d:" + d.id, tipo: .aguardando, jid: d.jid, nome: d.isGroup ? d.chatName : d.who, grupo: d.isGroup,
                                ts: d.ts, resumo: d.title, urgente: false, demand: d))
        }
        for x in mentionsEspera where passa(x.jid, grupo: true) {
            out.append(ItemFeed(id: "m:" + x.id, tipo: .aguardando, jid: x.jid, nome: x.chatName, grupo: true,
                                ts: x.ts, resumo: x.summary, urgente: false, mention: x))
        }
        return out.sorted { a, b in
            if a.urgente != b.urgente { return a.urgente }
            if a.tipo != b.tipo { return a.tipo.rawValue < b.tipo.rawValue }
            let fa = a.demand?.doing != nil, fb = b.demand?.doing != nil
            if fa != fb { return !fa }   // já pegas vão pro fim
            return a.ts > b.ts
        }
    }
    func conta(_ t: ItemFeed.Tipo) -> Int { feed.filter { $0.tipo == t }.count }
    /// fila do modo Hoje: o que pede ação, sem os "pra depois" (eles vão pro fim)
    var fila: [ItemFeed] {
        let f = feed.filter { $0.tipo != .saber && $0.tipo != .aguardando }
        return f.filter { !depois.contains($0.id) } + f.filter { depois.contains($0.id) }
    }
    /// ação principal de um item (enviar resposta pronta / feito / visto)
    func agir(_ i: ItemFeed) {
        switch i.tipo {
        case .responder: if let c = i.unread { reply(c) }
        case .saber: if let c = i.unread { unreadOK(c) }
        case .aguardando:
            if let d = i.demand { done(d) } else if let c = i.unread { unreadOK(c) } else if let m = i.mention { mentionOK(m) }
        case .demanda: if let d = i.demand { done(d) }
        case .marcacao: if let m = i.mention { mentionOK(m) }
        }
    }

    func fecharConversa() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { zapChat = nil }
        zp.fechar()
    }
    func reply(_ c: UnreadChat) {
        enviar(jid: c.jid, texto: draft(c), chave: c.jid) { [weak self] in
            guard let self else { return }
            // enviou: some das não lidas, mas a conversa fica aberta pra mandar mais (antes o cartão fechava)
            self.segurar.insert(c.jid)
            withAnimation(.spring(response: 0.35)) { self.unread.removeAll { $0.jid == c.jid } }
            if self.popoverOpen && self.zapChat == nil { self.abrirConversa(c.jid) }
        }
    }
    // MARK: responder pelo chat de verdade
    var onResponderJanela: ((String) -> Void)?
    /// abre a conversa (privada ou grupo) no chat, rolada na mensagem do pedido e com o campo pronto; não fecha depois de enviar
    func responderNoChat(jid: String, msgId: String?) {
        segurar.insert(jid)
        zp.irPara = msgId
        zp.focar = jid
        if popoverOpen { abrirConversa(jid) } else { onResponderJanela?(jid) }
    }
    // MARK: fazendo
    /// who: "claude" | "eu" | nil (parar)
    func fazendo(_ d: Demand, _ who: String?, manual: Bool = true) {
        Task { await post("/doing", ["id": d.id, "who": who ?? "", "manual": manual]); await refresh() }
    }
    func fazendoCliente(_ client: String, _ who: String?) {
        Task { await post("/doing", ["client": client, "who": who ?? ""]); await refresh() }
    }
    /// "parece pronto" errado: some a sugestão (até ter outra mensagem de pronto)
    func descartarPronto(_ d: Demand) {
        Task { await post("/doing", ["id": d.id, "hint": 0]); await refresh() }
    }
    /// tira o "respondida/esperando" na mão: volta pra Pra mim
    func voltarPraMim(_ d: Demand) {
        Task { await post("/state", ["id": d.id, "state": ""]); await refresh() }
    }
    /// responder no grupo de onde veio a marcação (sem sugestão da IA, texto livre); enviou = resolvida
    func replyMention(_ m: Mention) {
        let k = "m:" + m.id
        enviar(jid: m.jid, texto: drafts[k] ?? "", chave: k) { [weak self] in self?.mentionOK(m) }
    }
    /// manda pela ponte (/reply) só quando eu clico; `chave` separa rascunho/erro/enviando por item
    func enviar(jid: String, texto: String, chave: String, ok: @escaping () -> Void) {
        let text = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending.contains(chave) else { return }
        sending.insert(chave)
        sendError[chave] = nil
        Task {
            var r = URLRequest(url: URL(string: "/reply", relativeTo: base)!)
            r.httpMethod = "POST"; r.timeoutInterval = 25
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: ["jid": jid, "text": text])
            let res = try? await URLSession.shared.data(for: r)
            sending.remove(chave)
            if (res?.1 as? HTTPURLResponse)?.statusCode == 200 {
                drafts[chave] = nil
                ok()
                onChange?()
            } else {
                let msg = (res.flatMap { try? JSONSerialization.jsonObject(with: $0.0) as? [String: Any] })?["error"] as? String
                sendError[chave] = msg ?? "não consegui enviar"
            }
            await refresh()
        }
    }

    func mute(_ d: Demand) {
        withAnimation(.spring(response: 0.35)) { open.removeAll { $0.jid == d.jid } }
        onChange?()
        Task { await post("/mute", ["jid": d.jid]); await refresh() }
    }
}

func openZapFast() {
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/ZapFast.app"), configuration: NSWorkspace.OpenConfiguration())
}
