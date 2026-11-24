import AppKit
import SwiftUI

// Janela à parte (clara): o mesmo conteúdo do popover, só que com espaço pra ver tudo.
// A menu bar continua igual; isto abre pelo botão do popover, pelo ⚙︎ ou com ⌥⇧Z.

enum Secao: Hashable {
    case zap, conversas, mentions
    case mine, done, others
    case client(String)
}

@MainActor
final class JanelaController: NSObject, NSWindowDelegate {
    let store: Store
    private var window: NSWindow?
    let model = JanelaModel()

    init(store: Store) {
        self.store = store
        super.init()
        model.onTema = { [weak self] in self?.aplicarTema() }
        store.onLayout = { [weak self] in self?.aplicarLayout() }
    }

    /// claro / escuro / automático (segue o macOS)
    func aplicarTema() {
        switch model.tema {
        case "claro": window?.appearance = NSAppearance(named: .aqua)
        case "escuro": window?.appearance = NSAppearance(named: .darkAqua)
        default: window?.appearance = nil
        }
    }

    /// abre direto numa conversa (no layout que estiver escolhido)
    /// chat = true: abre o chat de verdade daquela conversa (botão Responder de demanda/marcação)
    func abrirConversa(_ jid: String, chat: Bool = false) {
        switch store.layout {
        case .classico: model.fixar = jid; model.secao = .conversas; model.sel = jid
        case .conversa: model.sel = jid
        case .caixa, .hoje: model.sel = chat ? "c:" + jid : (store.feed.first { $0.jid == jid }?.id)
        }
        show()
    }

    /// título nativo só no clássico (os layouts novos desenham a própria barra)
    func aplicarLayout() {
        window?.titleVisibility = store.layout == .classico ? .visible : .hidden
        model.sel = nil
    }

    func show() {
        if window == nil {
            // primeira vez: abre onde tem algo esperando por mim
            if !store.toReply.isEmpty { model.secao = .zap }
            window = build()
        }
        NSApp.setActivationPolicy(.regular)   // aparece no Dock e no ⌘Tab enquanto a janela está aberta
        Task { await store.refresh() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// debug: salva um PNG da janela (app.sisifo.cmd "janelaPrint:/caminho.png")
    func snapshot(_ path: String) {
        guard let v = window?.contentView?.superview else { return }
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func windowWillClose(_ n: Notification) {
        // Sísifo é app de verdade (Dock): fechar a janela não tira do Dock
    }

    private func build() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Sísifo"
        // fundo translúcido: a janela deixa ver o que está atrás (blur do sistema)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        w.toolbarStyle = .unified
        w.minSize = NSSize(width: 780, height: 460)
        w.contentViewController = NSHostingController(rootView: JanelaView(store: store, m: model))
        w.delegate = self
        window = w
        aplicarTema()
        w.titleVisibility = store.layout == .classico ? .visible : .hidden
        w.setContentSize(NSSize(width: 980, height: 600))
        w.center()
        w.setFrameAutosaveName("DemandasJanela")
        return w
    }
}

// MARK: - view

final class JanelaModel: ObservableObject {
    @Published var tema = UserDefaults.standard.string(forKey: "janelaTema") ?? "auto" {
        didSet { UserDefaults.standard.set(tema, forKey: "janelaTema"); onTema?() }
    }
    var onTema: (() -> Void)?
    @Published var secao: Secao? = .mine
    @Published var sel: String?
    /// popover "entregues hoje" do topo
    @Published var entregues = false
    /// seleção que a troca de seção não pode apagar (abrir conversa direto)
    var fixar: String?
    @Published var busca = ""
}

struct JanelaView: View {
    @ObservedObject var store: Store
    @ObservedObject var m: JanelaModel
    var secao: Secao? { m.secao }
    var sel: String? { m.sel }

    var body: some View {
        Group {
            switch store.layout {
            case .classico: classico
            case .caixa: JanelaCaixa(store: store, zp: store.zp, m: m)
            case .conversa: JanelaConversa(store: store, zp: store.zp, m: m)
            case .hoje: JanelaHoje(store: store, zp: store.zp, m: m)
            }
        }
        .background(Vidro().ignoresSafeArea())
    }

    var classico: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } content: {
            lista.navigationSplitViewColumnWidth(min: 310, ideal: 370, max: 480)
        } detail: {
            detalhe
        }
        .searchable(text: $m.busca, placement: .toolbar, prompt: "Buscar")
        .onChange(of: secao) { _, _ in m.sel = m.fixar ?? ids.first; m.fixar = nil; abrirChat() }
        .onChange(of: ids) { _, novos in
            guard let s = m.sel, !novos.contains(s) else { return }
            // respondi pela não lida: a conversa continua aberta (vai pra Conversas) pra eu mandar mais
            if secao == .zap && store.segurar.contains(s) { m.fixar = s; m.secao = .conversas; m.sel = s; return }
            m.sel = novos.first
        }
        .onChange(of: m.sel) { _, _ in abrirChat() }
        .onAppear { if sel == nil { m.sel = ids.first }; abrirChat() }
        .background(Vidro().ignoresSafeArea())
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Aparência", selection: $m.tema) {
                        Label("Automático", systemImage: "circle.lefthalf.filled").tag("auto")
                        Label("Claro", systemImage: "sun.max").tag("claro")
                        Label("Escuro", systemImage: "moon").tag("escuro")
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: m.tema == "claro" ? "sun.max" : m.tema == "escuro" ? "moon" : "circle.lefthalf.filled")
                }
                .help("Aparência: automático, claro ou escuro")
            }
        }
    }

    // MARK: barra lateral

    func item(_ t: String, _ sym: String, _ n: Int, destaque: Int = 0) -> some View {
        HStack(spacing: 9) {
            Image(systemName: sym).font(.system(size: 13, weight: .medium)).frame(width: 18, alignment: .center)
            Text(t).font(.cute(13, .medium)).lineLimit(1)
            Spacer(minLength: 4)
            if destaque > 0 {
                Text("\(destaque)").font(.cute(11, .bold)).monospacedDigit().foregroundStyle(.white)
                    .padding(.horizontal, 7).frame(minWidth: 20, minHeight: 18)
                    .background(Capsule().fill(Mood.calm))
            } else if n > 0 {
                Text("\(n)").font(.cute(11, .semibold)).monospacedDigit().foregroundStyle(.secondary)
                    .padding(.horizontal, 7).frame(minWidth: 20, minHeight: 18)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
        }
    }

    var sidebar: some View {
        List(selection: $m.secao) {
            Section("Zap") {
                item("Não lidas", "bubble.left.and.text.bubble.right", store.unread.count, destaque: store.toReply.count)
                    .help(store.toReply.isEmpty ? "Mensagens que tu ainda não leu" : "\(store.toReply.count) esperando tua resposta")
                    .tag(Secao.zap)
                item("Conversas", "bubble.left.and.bubble.right", store.zp.chats.filter { $0.unread > 0 }.count).tag(Secao.conversas)
                    .help("Todas as conversas privadas, como no WhatsApp")
                item("Marcações", "at", store.mentionsOpen.count).tag(Secao.mentions)
            }
            Section("Demandas") {
                item("Pra mim", "tray.full", store.mine.count).tag(Secao.mine)
                item("Feitas hoje", "checkmark.circle", store.doneToday.count).tag(Secao.done)
                item("Outras áreas", "arrow.turn.up.right", store.others.count).tag(Secao.others)
            }
            if !store.clients.isEmpty {
                Section("Clientes") {
                    ForEach(store.clients, id: \.name) { c in
                        HStack(spacing: 9) {
                            ClientAvatar(url: store.avatarURL(c.jid), name: c.name, isGroup: c.isGroup, size: 20)
                                .frame(width: 18)
                            Text(c.name).font(.cute(13, .medium)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(c.count)").font(.cute(11, .semibold)).monospacedDigit().foregroundStyle(.secondary)
                                .padding(.horizontal, 7).frame(minWidth: 20, minHeight: 18)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                        }
                        .tag(Secao.client(c.name))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { status }
    }

    @ViewBuilder var status: some View {
        let (sym, txt, cor): (String, String, Color) =
            !store.serverUp ? ("hourglass", "Ligando o motorzinho…", Mood.warm)
            : !store.connected ? ("wifi.exclamationmark", "Ponte do WhatsApp fora", Mood.warm)
            : store.scanning > 0 ? ("text.magnifyingglass", store.scanning == 1 ? "Lendo 1 conversa" : "Lendo \(store.scanning) conversas", .secondary)
            : ("checkmark.circle.fill", "Tudo em dia", Mood.calm)
        HStack(spacing: 6) {
            Image(systemName: sym).foregroundStyle(cor)
            Text(txt).foregroundStyle(.secondary)
            Spacer()
        }
        .font(.cute(11, .medium))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(Color.primary.opacity(0.045)))
        .padding(.horizontal, 10).padding(.bottom, 10)
    }

    // MARK: dados da lista do meio

    var itens: [Demand] {
        let base: [Demand]
        switch secao ?? .mine {
        case .zap, .mentions, .conversas: base = []
        case .mine: base = store.sortedOpen
        case .done: base = store.doneToday
        case .others: base = store.others
        case .client(let c): base = store.sortedOpen.filter { $0.client == c }
        }
        return base.filter { bate("\($0.title) \($0.client) \($0.who) \($0.quote) \($0.detail)") }
    }

    func bate(_ txt: String) -> Bool {
        let q = m.busca.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || txt.lowercased().contains(q)
    }
    var zapResponder: [UnreadChat] { store.toReply.filter { bate("\($0.name) \($0.summary) \($0.tail.map(\.text).joined(separator: " "))") } }
    var zapSaber: [UnreadChat] { store.toKnow.filter { bate("\($0.name) \($0.summary) \($0.tail.map(\.text).joined(separator: " "))") } }
    var marcAbertas: [Mention] { store.mentionsOpen.filter { bate("\($0.client) \($0.who) \($0.summary) \($0.quote)") } }
    var marcFeitas: [Mention] { store.mentionsDone.filter { bate("\($0.client) \($0.who) \($0.summary) \($0.quote)") } }

    /// ids da lista do meio na ordem em que aparecem (seleção e setas ↑↓)
    var ids: [String] {
        switch secao ?? .mine {
        case .zap: return (zapResponder + zapSaber).map(\.jid)
        case .mentions: return (marcAbertas + marcFeitas).map(\.id)
        case .conversas: return store.zp.chats.sorted { $0.lastTs > $1.lastTs }.map(\.jid)
        default: return itens.map(\.id)
        }
    }

    var titulo: String {
        switch secao ?? .mine {
        case .zap: return "Não lidas"
        case .mentions: return "Marcações"
        case .conversas: return "Conversas"
        case .mine: return "Pra mim"
        case .done: return "Feitas hoje"
        case .others: return "Outras áreas"
        case .client(let c): return c
        }
    }

    var subtitulo: String {
        if secao == .zap {
            let r = zapResponder.count, n = r + zapSaber.count
            return n == 0 ? "tudo lido" : r > 0 ? "\(r) esperando resposta · \(n) não lidas" : (n == 1 ? "1 não lida" : "\(n) não lidas")
        }
        if secao == .conversas {
            let n = store.zp.totalUnread
            return !store.zp.connected ? "WhatsApp desconectado" : n == 0 ? "tudo lido" : (n == 1 ? "1 não lida" : "\(n) não lidas")
        }
        if secao == .mentions {
            let n = marcAbertas.count
            return n == 0 ? "ninguém te chamando" : (n == 1 ? "1 aberta" : "\(n) abertas")
        }
        let n = itens.count
        if n == 0 { return "nada aqui" }
        if secao == .done { return n == 1 ? "1 entregue" : "\(n) entregues" }
        let base = n == 1 ? "1 aberta" : "\(n) abertas"
        if let o = itens.min(by: { $0.ts < $1.ts }) {
            let (v, u) = o.waitParts
            return v == "agora" ? base : "\(base) · mais antiga há \(v)\(u == "min" || u == "h" ? u : " " + u)"
        }
        return base
    }

    // MARK: lista do meio (cartões, sem faixas)

    @ViewBuilder var lista: some View {
        Group {
            switch secao ?? .mine {
            case .zap:
                if zapResponder.isEmpty && zapSaber.isEmpty {
                    Vazio(sym: "checkmark.bubble.fill", txt: "Tudo lido", sub: "Quando chegar mensagem que tu ainda não leu, eu resumo aqui e já deixo a resposta pronta.")
                } else {
                    Cartoes(m: m, ids: ids) {
                        if !zapResponder.isEmpty {
                            Cabecalho(texto: "Esperando tua resposta", n: zapResponder.count)
                            ForEach(zapResponder) { c in
                                Cartao(m: m, id: c.jid) { LinhaZap(store: store, c: c) }.contextMenu { menuZap(c) }
                            }
                        }
                        if !zapSaber.isEmpty {
                            Cabecalho(texto: zapResponder.isEmpty ? "Chegou" : "Só pra saber", n: zapSaber.count,
                                      acao: ("marcar tudo como lido", { store.unreadOKAll(zapSaber.filter { !$0.pending }) }))
                                .padding(.top, zapResponder.isEmpty ? 0 : 10)
                            ForEach(zapSaber) { c in
                                Cartao(m: m, id: c.jid) { LinhaZap(store: store, c: c) }.contextMenu { menuZap(c) }
                            }
                        }
                    }
                }
            case .conversas:
                ConversasLista(store: store.zp, selecionado: sel, buscaExterna: m.busca) { m.sel = $0 }
                    .padding(.top, 4)
            case .mentions:
                if marcAbertas.isEmpty && marcFeitas.isEmpty {
                    Vazio(sym: "at", txt: "Ninguém te chamando", sub: "Quando te marcarem num grupo, eu leio e deixo aqui só o que querem de ti, em uma linha.")
                } else {
                    Cartoes(m: m, ids: ids) {
                        if marcAbertas.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "leaf.fill").foregroundStyle(Mood.calm)
                                Text("Nenhuma aberta, respira").foregroundStyle(.secondary)
                            }
                            .font(.cute(12, .medium)).padding(.horizontal, 10).padding(.vertical, 6)
                        }
                        ForEach(marcAbertas) { x in
                            Cartao(m: m, id: x.id) { LinhaMarcacao(store: store, m: x) }
                                .contextMenu { Button("Ok, visto") { store.mentionOK(x) }; Button("Ver conversa no ZapFast") { openZapFast() } }
                        }
                        if !marcFeitas.isEmpty {
                            Cabecalho(texto: "Já resolvidas", n: marcFeitas.count).padding(.top, 10)
                            ForEach(marcFeitas) { x in
                                Cartao(m: m, id: x.id) { LinhaMarcacao(store: store, m: x).opacity(0.6) }
                                    .contextMenu { Button("Voltar pra lista") { store.mentionOK(x, false) } }
                            }
                        }
                    }
                    .onAppear { store.seeMentions() }
                }
            default:
                if itens.isEmpty {
                    Vazio(sym: secao == .done ? "checkmark.circle" : "leaf.fill",
                          txt: secao == .done ? "Nada feito hoje ainda" : "Nada pendente, respira",
                          sub: secao == .done ? "O que tu marcar como feito aparece aqui até o fim do dia." : "Quando um cliente pedir algo, vira um cartão aqui.")
                } else {
                    Cartoes(m: m, ids: ids) {
                        ForEach(itens) { d in
                            Cartao(m: m, id: d.id) { LinhaJanela(store: store, d: d, feita: secao == .done) }
                                .contextMenu { menu(d) }
                        }
                    }
                }
            }
        }
        .navigationTitle(titulo)
        .navigationSubtitle(subtitulo)
        .toolbar {
            ToolbarItem {
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Atualizar")
            }
        }
    }

    @ViewBuilder func menuZap(_ c: UnreadChat) -> some View {
        Button("Ok, li") { store.unreadOK(c) }
        Button("Outra sugestão de resposta") { store.redo(c) }
        Divider()
        Button("Ver conversa no ZapFast") { openZapFast() }
    }

    @ViewBuilder func menu(_ d: Demand) -> some View {
        if d.status == "done" {
            Button("Desfazer") { store.reopen(d) }
        } else {
            Button("Claude Code") { store.onClaude?(d) }
            Button("Feito") { feito(d) }
            Menu("Passar pra…") { PassarMenu(store: store, d: d) }
            Divider()
            Button("Ver conversa no ZapFast") { openZapFast() }
            Button("Não é demanda") { store.ignore(d) }
            Button("Ignorar \(d.isGroup ? "esse grupo" : "essa conversa")") { store.mute(d) }
        }
    }

    func feito(_ d: Demand) {
        let lst = itens
        if let i = lst.firstIndex(where: { $0.id == d.id }) {
            let prox = lst.indices.contains(i + 1) ? lst[i + 1] : (i > 0 ? lst[i - 1] : nil)
            m.sel = prox?.id
        }
        store.done(d)
    }

    // MARK: detalhe

    /// conversa privada (do chat de verdade); se ainda não carregou, monta com o nome das não lidas
    func chatPrivado(_ jid: String) -> Chat {
        store.zp.chats.first { $0.jid == jid }
            ?? Chat(jid: jid, name: store.unread.first { $0.jid == jid }?.name ?? jid, last: "", lastTs: 0, unread: 0)
    }

    /// conversa privada selecionada: carrega as mensagens dela
    func abrirChat() {
        guard let id = m.sel else { return }
        let privado = secao == .conversas || (secao == .zap && store.unread.first(where: { $0.jid == id }).map { !$0.isGroup } == true)
        guard privado, store.zp.selected != id else { return }
        Task { await store.zp.select(id) }
    }

    @ViewBuilder var detalhe: some View {
        if secao == .conversas, let id = sel {
            ChatView(store: store.zp, chat: chatPrivado(id), compact: false)
        } else if secao == .zap, let id = sel, let c = store.unread.first(where: { $0.jid == id }), !c.isGroup {
            ChatView(store: store.zp, chat: chatPrivado(id), compact: false)
        } else if secao == .zap, let id = sel, let c = store.unread.first(where: { $0.jid == id }) {
            DetalheZap(store: store, c: c).id(c.jid)
        } else if secao == .mentions, let id = sel, let x = store.mentions.first(where: { $0.id == id }) {
            DetalheMarcacao(store: store, m: x).id(x.id)
        } else if secao != .zap && secao != .mentions, let id = sel, let d = (store.open + store.doneToday).first(where: { $0.id == id }) {
            DetalheJanela(store: store, d: d, feito: { feito(d) }).id(d.id)
        } else {
            VStack(spacing: 10) {
                DaemonLogo(size: 40).opacity(0.45)
                Text(secao == .zap ? "Escolhe uma conversa" : secao == .mentions ? "Escolhe uma marcação" : "Escolhe uma demanda")
                    .font(.cute(13, .semibold)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - peças da lista do meio

/// lista de cartões com seleção própria (sem faixas do sistema) e setas ↑↓
struct Cartoes<Content: View>: View {
    @ObservedObject var m: JanelaModel
    let ids: [String]
    @ViewBuilder let content: () -> Content
    @FocusState private var foco: Bool

    var body: some View {
        ScrollViewReader { sp in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) { content() }
                    .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .scrollContentBackground(.hidden)
            .focusable()
            .focused($foco)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { mover(1, sp); return .handled }
            .onKeyPress(.upArrow) { mover(-1, sp); return .handled }
            .onAppear { foco = true }
        }
    }

    func mover(_ passo: Int, _ sp: ScrollViewProxy) {
        guard !ids.isEmpty else { return }
        let i = m.sel.flatMap { ids.firstIndex(of: $0) } ?? -1
        let n = min(max(i + passo, 0), ids.count - 1)
        m.sel = ids[n]
        withAnimation(.easeOut(duration: 0.15)) { sp.scrollTo(ids[n], anchor: .center) }
    }
}

struct Cartao<Content: View>: View {
    @ObservedObject var m: JanelaModel
    let id: String
    @ViewBuilder let content: () -> Content
    @StateObject private var h = Hover()

    var body: some View {
        let on = m.sel == id
        content()
            .padding(.horizontal, 10).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(on ? Color.accentColor.opacity(0.14) : Color.primary.opacity(h.on ? 0.045 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(on ? Color.accentColor.opacity(0.28) : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onTapGesture { m.sel = id }
            .onHover { v in withAnimation(.easeOut(duration: 0.12)) { h.on = v } }
            .animation(.easeOut(duration: 0.15), value: on)
            .id(id)
    }
}

struct Cabecalho: View {
    let texto: String
    let n: Int
    var acao: (String, () -> Void)? = nil
    var body: some View {
        HStack(spacing: 5) {
            Text(texto).font(.cute(11.5, .bold))
            Text("\(n)").font(.cute(11, .bold)).monospacedDigit().opacity(0.5)
            Spacer()
            if let (t, f) = acao {
                Button(t, action: f).buttonStyle(.plain).font(.cute(11, .semibold))
                    .help("Some daqui. No celular continua como não lida.")
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
    }
}

struct Vazio: View {
    let sym: String
    let txt: String
    let sub: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: sym).font(.system(size: 26, weight: .semibold)).foregroundStyle(Mood.calm)
            Text(txt).font(.cute(13.5, .semibold))
            Text(sub).font(.cute(11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 250)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// caixa de resposta flutuante (igual app de mensagem, sem faixa no rodapé)
struct Compositor<Rodape: View>: View {
    let placeholder: String
    @Binding var texto: String
    var enviando = false
    var pensando = false
    var erro: String? = nil
    var chips: [(String, () -> Void)] = []
    let enviar: () -> Void
    @ViewBuilder let rodape: () -> Rodape

    var vazio: Bool { texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !chips.isEmpty {
                HStack(spacing: 6) {
                    if pensando { ProgressView().controlSize(.mini) }
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, c in
                        Button(action: c.1) {
                            Text(c.0).font(.cute(11, .semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 9).frame(height: 22)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                        .disabled(pensando || enviando)
                    }
                    Spacer()
                    if let e = erro { Text(e).font(.cute(11, .medium)).foregroundStyle(Mood.hot).lineLimit(1) }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(pensando ? "pensando numa resposta…" : placeholder, text: $texto, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.cute(13.5))
                    .lineLimit(1...8)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(0.85)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                    .disabled(enviando)
                Button(action: enviar) {
                    Group {
                        if enviando { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold)) }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Mood.calm.opacity(vazio ? 0.3 : 1)))
                }
                .buttonStyle(.plain)
                .disabled(vazio || enviando)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Enviar no WhatsApp (⌘↩)")
            }
            HStack(spacing: 6) {
                rodape()
                Spacer()
                Text("⌘↩ envia").font(.cute(10.5, .medium)).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 1))
        .shadow(color: .black.opacity(0.07), radius: 14, y: 4)
        .padding(.horizontal, 20).padding(.bottom, 16).padding(.top, 6)
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
    }
}

/// botão discreto do rodapé do compositor
struct Quieto: View {
    let texto: String
    let sym: String
    var tint: Color = .secondary
    let acao: () -> Void
    @StateObject private var h = Hover()
    var body: some View {
        Button(action: acao) {
            HStack(spacing: 4) {
                Image(systemName: sym).font(.system(size: 10, weight: .bold))
                Text(texto).font(.cute(11, .semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8).frame(height: 22)
            .background(Capsule().fill(Color.primary.opacity(h.on ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { h.on = $0 }
    }
}

/// cabeçalho compacto do painel de detalhe
struct Topo: View {
    let avatar: AnyView
    let nome: String
    let sub: String
    let canto: AnyView
    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                Text(nome).font(.cute(14.5, .bold)).lineLimit(1)
                Text(sub).font(.cute(11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            canto.fixedSize()
        }
    }
}

// MARK: - linha da lista

struct LinhaJanela: View {
    @ObservedObject var store: Store
    let d: Demand
    var feita = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ClientAvatar(url: store.avatarURL(d.jid), name: d.client, isGroup: d.isGroup, size: 34)
                .saturation(feita ? 0.4 : 1).opacity(feita ? 0.8 : 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(d.who.isEmpty ? d.client : "\(d.client) · \(d.who)")
                    .font(.cute(11, .medium)).foregroundStyle(.secondary).lineLimit(1)
                Text(d.title).font(.cute(13, .semibold)).lineLimit(2)
                    .strikethrough(feita, color: .secondary)
                if !feita && (d.urgent || d.dueState != nil || !d.mine) {
                    HStack(spacing: 4) {
                        if d.urgent { Pill(text: "urgente", symbol: "bolt.fill", tint: Mood.hot) }
                        DuePill(d: d)
                        if !d.mine { Pill(text: d.areaLabel, symbol: "arrow.turn.up.right") }
                    }
                    .scaleEffect(0.92, anchor: .leading)
                }
            }
            Spacer(minLength: 6)
            if !feita {
                let (n, u) = d.waitParts
                Text(n == "agora" ? "agora" : "\(n)\(u == "min" || u == "h" ? u : " " + u)")
                    .font(.cute(12.5, .bold)).monospacedDigit()
                    .foregroundStyle(d.waitColor)
            }
        }
        .padding(.vertical, 5)
    }
}

// MARK: - painel de detalhe (demanda)

struct DetalheJanela: View {
    @ObservedObject var store: Store
    let d: Demand
    let feito: () -> Void

    var irmas: [Demand] { store.sortedOpen.filter { $0.client == d.client && $0.id != d.id } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Topo(avatar: AnyView(ClientAvatar(url: store.avatarURL(d.jid), name: d.client, isGroup: d.isGroup, size: 40)),
                     nome: d.client,
                     sub: d.isGroup ? "no grupo \(d.chatName)\(d.who.isEmpty ? "" : " · pediu \(d.who)")" : "conversa direta com \(d.who.isEmpty ? d.client : d.who)",
                     canto: AnyView(Group { if d.status != "done" { WaitBadge(d: d) } }))

                VStack(alignment: .leading, spacing: 9) {
                    Text(d.title).font(.cute(19, .bold)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    HStack(spacing: 5) {
                        if d.status == "done" { Pill(text: d.autoDone ? "vi que tu entregou" : "feita", symbol: "checkmark", tint: Mood.calm) }
                        if d.urgent { Pill(text: "urgente", symbol: "bolt.fill", tint: Mood.hot) }
                        DuePill(d: d)
                        if !d.who.isEmpty { Pill(text: d.who, symbol: d.isGroup ? "person.2.fill" : "person.fill") }
                        if !d.mine { Pill(text: d.areaLabel, symbol: "arrow.turn.up.right") }
                    }
                }

                acoes

                if !d.detail.isEmpty {
                    Text(d.detail).font(.cute(13.5)).foregroundStyle(Color.primary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("\u{201C}\(d.quote)\u{201D}")
                        .font(.cute(13)).foregroundStyle(Color.primary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    RefStrip(store: store, d: d, size: 92)
                    Text("\(d.who.isEmpty ? "mensagem" : "mensagem de \(d.who)") · \(Date(timeIntervalSince1970: TimeInterval(d.ts)).formatted(date: .abbreviated, time: .shortened))")
                        .font(.cute(11)).foregroundStyle(.tertiary)
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Capsule().fill(Mood.calm.opacity(0.5)).frame(width: 3) }

                if !irmas.isEmpty && d.status != "done" {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Mais do \(d.client)").font(.cute(12, .semibold)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(irmas) { o in
                                HStack(spacing: 8) {
                                    Circle().fill(o.waitColor).frame(width: 6, height: 6)
                                    Text(o.title).font(.cute(12.5)).lineLimit(1)
                                    DuePill(d: o).scaleEffect(0.9)
                                    Spacer()
                                }
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.04)))
                        if let g = store.groups.first(where: { $0.name == d.client }) {
                            ActionPill(text: "mandar as \(g.demands.count) pro Claude Code", symbol: "sparkle", tint: Mood.claude) {
                                store.onClaudeClient?(g)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
            .frame(maxWidth: 660, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder var acoes: some View {
        if d.status != "done" {
            if let f = d.fazendoTexto { PilulaFazendo(texto: f, claude: d.doing == "claude").fixedSize() }
            if let hint = d.doneHint { PareceProto(store: store, d: d, porClaude: hint == "claude") }
        }
        if d.status == "done" {
            ActionPill(text: "desfazer", symbol: "arrow.uturn.backward") { store.reopen(d) }
        } else {
            // painel estreito (layout Hoje) quebra em duas linhas em vez de estourar a largura
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { principais; secundarias }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) { principais }
                    HStack(spacing: 6) { secundarias }
                }
            }
        }
    }

    @ViewBuilder var principais: some View {
        ActionPill(text: "Claude Code", symbol: "sparkle", tint: Mood.claude, filled: true) { store.onClaude?(d) }
        ActionPill(text: "feito", symbol: "checkmark", tint: Mood.calm, action: feito)
        ActionPill(text: "Responder", symbol: "arrowshape.turn.up.left.fill", tint: .blue) { store.responderNoChat(jid: d.jid, msgId: d.msgId) }
    }

    @ViewBuilder var secundarias: some View {
        Menu {
            PassarMenu(store: store, d: d)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.turn.up.right").font(.system(size: 10.5, weight: .bold))
                Text("passar pra…").font(.cute(11.5, .semibold))
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .padding(.horizontal, 11).frame(height: 27)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .help("Mover pra outra pessoa da equipe")
        ActionPill(text: "ZapFast", symbol: "bubble.left.and.bubble.right") { openZapFast() }
        Menu {
            Button("Não é demanda") { store.ignore(d) }
            Button("Ignorar \(d.isGroup ? "esse grupo" : "essa conversa")") { store.mute(d) }
        } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .padding(.horizontal, 10).frame(height: 27)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

struct PassarMenu: View {
    @ObservedObject var store: Store
    let d: Demand
    var body: some View {
        if d.doing == nil {
            Button { store.fazendo(d, "eu") } label: { Label("Tô fazendo", systemImage: "hammer") }
        } else {
            Button { store.fazendo(d, nil) } label: { Label(d.doing == "claude" ? "Parar (Claude)" : "Parar", systemImage: "stop.circle") }
        }
        Divider()
        ForEach(Store.team, id: \.key) { t in
            Button {
                store.move(d, to: t.key)
            } label: {
                if t.area == d.area { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
            }
            .disabled(t.area == d.area)
        }
    }
}

/// vidro do sistema atrás da janela inteira (bem transparente, segue claro/escuro)
struct Vidro: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var mistura: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = mistura
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}


struct LinhaZap: View {
    @ObservedObject var store: Store
    let c: UnreadChat

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ClientAvatar(url: store.avatarURL(c.jid), name: c.name, isGroup: c.isGroup, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(c.title).font(.cute(11, .medium)).foregroundStyle(.secondary).lineLimit(1)
                    if c.count > 1 { Text("\(c.count)").font(.cute(10.5, .bold)).monospacedDigit().foregroundStyle(.tertiary) }
                }
                if c.summary.isEmpty {
                    HStack(spacing: 6) {
                        if c.pending { ProgressView().controlSize(.mini) }
                        Text(c.pending ? "lendo…" : (c.tail.last.map { "\($0.who): \($0.text)" } ?? ""))
                            .font(.cute(12.5)).foregroundStyle(.secondary).lineLimit(2)
                    }
                } else {
                    Text(c.summary).font(.cute(13, c.needsReply ? .semibold : .regular)).lineLimit(2)
                }
                if c.urgent || c.demands > 0 || store.drafts[c.jid] != nil {
                    HStack(spacing: 4) {
                        if c.urgent { Pill(text: "urgente", symbol: "bolt.fill", tint: Mood.hot) }
                        if c.demands > 0 { Pill(text: c.demands == 1 ? "1 demanda" : "\(c.demands) demandas", symbol: "tray.full.fill", tint: Mood.calm) }
                        if store.drafts[c.jid] != nil { Pill(text: "rascunho", symbol: "pencil") }
                    }
                    .scaleEffect(0.92, anchor: .leading)
                }
            }
            Spacer(minLength: 6)
            Text(c.ago).font(.cute(12, .semibold)).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }
}

struct DetalheZap: View {
    @ObservedObject var store: Store
    let c: UnreadChat

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { sp in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Topo(avatar: AnyView(ClientAvatar(url: store.avatarURL(c.jid), name: c.name, isGroup: c.isGroup, size: 40)),
                             nome: c.title,
                             sub: "\(c.isGroup ? "grupo" : "conversa direta") · \(c.count == 1 ? "1 mensagem nova" : "\(c.count) mensagens novas")",
                             canto: AnyView(Text(c.ago).font(.cute(12, .semibold)).monospacedDigit().foregroundStyle(.secondary)))

                        if !c.summary.isEmpty {
                            VStack(alignment: .leading, spacing: 9) {
                                Text(c.summary).font(.cute(17, .semibold)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                HStack(spacing: 5) {
                                    if c.needsReply { Pill(text: "esperando tua resposta", symbol: "bubble.left.fill", tint: .blue) }
                                    else { Pill(text: "só pra saber", symbol: "info.circle.fill") }
                                    if c.urgent { Pill(text: "urgente", symbol: "bolt.fill", tint: Mood.hot) }
                                    if c.demands > 0 { Pill(text: c.demands == 1 ? "1 demanda anotada" : "\(c.demands) demandas anotadas", symbol: "tray.full.fill", tint: Mood.calm) }
                                }
                            }
                        } else if c.pending {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("lendo a conversa…").font(.cute(13)).foregroundStyle(.secondary) }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(c.tail.enumerated()), id: \.offset) { i, l in
                                Bolha(l: l, grupo: c.isGroup, mesmoAutor: i > 0 && c.tail[i - 1].who == l.who && c.tail[i - 1].me == l.me).id(i)
                            }
                        }
                        .padding(.top, 2)
                    }
                    .padding(.horizontal, 28).padding(.vertical, 22)
                    .frame(maxWidth: 700, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollContentBackground(.hidden)
                .onAppear { if !c.tail.isEmpty { sp.scrollTo(c.tail.count - 1, anchor: .bottom) } }
            }

            let redoing = store.redoing.contains(c.jid) || (c.pending && c.suggestion == nil)
            Compositor(
                placeholder: "tua resposta",
                texto: Binding(get: { store.draft(c) },
                               set: { store.drafts[c.jid] = ($0 == (c.suggestion ?? "")) ? nil : $0 }),
                enviando: store.sending.contains(c.jid),
                pensando: redoing,
                erro: store.sendError[c.jid],
                chips: [("outra sugestão", { store.redo(c) }),
                        ("mais curta", { store.redo(c, hint: "bem mais curta, 1 frase") }),
                        ("vou ver e respondo", { store.drafts[c.jid] = c.isGroup ? "Vou ver isso e já te falo" : "vou ver isso e ja te falo" })],
                enviar: { store.reply(c) }
            ) {
                Quieto(texto: "ok, li", sym: "checkmark", tint: Mood.calm) { store.unreadOK(c) }
                Quieto(texto: "ZapFast", sym: "arrow.up.forward.app") { openZapFast() }
            }
        }
    }
}

/// uma mensagem da conversa: minhas à direita (verdinho), dos outros à esquerda
struct Bolha: View {
    let l: UnreadChat.Line
    let grupo: Bool
    var mesmoAutor = false
    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if l.me { Spacer(minLength: 70) }
            VStack(alignment: .leading, spacing: 2) {
                if grupo && !l.me && !mesmoAutor { Text(l.who).font(.cute(10.5, .semibold)).foregroundStyle(ClientAvatar.color(for: l.who)) }
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(l.text).font(.cute(13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Text(Date(timeIntervalSince1970: TimeInterval(l.ts)).formatted(date: .omitted, time: .shortened))
                        .font(.cute(9.5)).foregroundStyle(.tertiary).fixedSize()
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(l.me ? Mood.calm.opacity(0.16) : Color.primary.opacity(0.055)))
            .frame(maxWidth: 480, alignment: l.me ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
            if !l.me { Spacer(minLength: 70) }
        }
        .padding(.top, mesmoAutor ? 0 : 4)
    }
}


// MARK: - Marcações na janela

struct LinhaMarcacao: View {
    @ObservedObject var store: Store
    let m: Mention

    var body: some View {
        let (label, symbol, tint) = m.kindLabel
        HStack(alignment: .center, spacing: 10) {
            ClientAvatar(url: store.avatarURL(m.jid), name: m.client, isGroup: true, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(m.client) · \(m.who)").font(.cute(11, .medium)).foregroundStyle(.secondary).lineLimit(1)
                Text(m.summary).font(.cute(13, .semibold)).lineLimit(2)
                HStack(spacing: 4) {
                    Pill(text: label, symbol: symbol, tint: tint)
                    if m.urgent { Pill(text: "urgente", symbol: "bolt.fill", tint: Mood.hot) }
                    if m.demandId != nil { Pill(text: "já tá em Pra mim", symbol: "tray.full.fill", tint: Mood.calm) }
                }
                .scaleEffect(0.92, anchor: .leading)
            }
            Spacer(minLength: 6)
            Text(m.ago).font(.cute(12, .semibold)).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }
}

struct DetalheMarcacao: View {
    @ObservedObject var store: Store
    let m: Mention
    var chave: String { "m:" + m.id }

    var body: some View {
        let (label, symbol, tint) = m.kindLabel
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Topo(avatar: AnyView(ClientAvatar(url: store.avatarURL(m.jid), name: m.client, isGroup: true, size: 40)),
                         nome: m.client,
                         sub: "no grupo \(m.chatName) · \(m.who) \(m.how == "respondeu" ? "respondeu tua mensagem" : "te marcou")",
                         canto: AnyView(Text(m.ago).font(.cute(12, .semibold)).monospacedDigit().foregroundStyle(.secondary)))
                    VStack(alignment: .leading, spacing: 9) {
                        Text(m.summary).font(.cute(17, .semibold)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        HStack(spacing: 5) {
                            if m.ok { Pill(text: "resolvida", symbol: "checkmark", tint: Mood.calm) }
                            Pill(text: label, symbol: symbol, tint: tint)
                            if m.urgent { Pill(text: "urgente", symbol: "bolt.fill", tint: Mood.hot) }
                            if m.demandId != nil { Pill(text: "já tá em Pra mim", symbol: "tray.full.fill", tint: Mood.calm) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\u{201C}\(m.quote)\u{201D}")
                            .font(.cute(13)).foregroundStyle(Color.primary.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        Text("mensagem de \(m.who) · \(Date(timeIntervalSince1970: TimeInterval(m.ts)).formatted(date: .abbreviated, time: .shortened))")
                            .font(.cute(11)).foregroundStyle(.tertiary)
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Capsule().fill(Color.blue.opacity(0.45)).frame(width: 3) }
                }
                .padding(.horizontal, 28).padding(.vertical, 22)
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)

            Compositor(
                placeholder: "responder no grupo \(m.chatName)",
                texto: Binding(get: { store.drafts[chave] ?? "" }, set: { store.drafts[chave] = $0.isEmpty ? nil : $0 }),
                enviando: store.sending.contains(chave),
                erro: store.sendError[chave],
                chips: [("vou ver e respondo", { store.drafts[chave] = "Vou ver isso e já te falo" }),
                        ("feito", { store.drafts[chave] = "Feito!" })],
                enviar: { store.replyMention(m) }
            ) {
                if m.ok {
                    Quieto(texto: "voltar pra lista", sym: "arrow.uturn.backward") { store.mentionOK(m, false) }
                } else {
                    Quieto(texto: "ok, visto", sym: "checkmark", tint: Mood.calm) { store.mentionOK(m) }
                    Quieto(texto: "abrir chat", sym: "bubble.left.and.bubble.right", tint: .blue) { store.responderNoChat(jid: m.jid, msgId: m.id) }
                }
                Quieto(texto: "ZapFast", sym: "arrow.up.forward.app") { openZapFast() }
            }
        }
    }
}
