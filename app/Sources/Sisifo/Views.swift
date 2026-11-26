import SwiftUI
import ServiceManagement

extension Font {
    static func cute(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

final class Hover: ObservableObject {
    @Published var on = false
    @Published var launch = false
    init(launch: Bool = false) { self.launch = launch }
}

// MARK: - fotos de referência que mandaram junto com o pedido

struct RefStrip: View {
    @ObservedObject var store: Store
    let d: Demand
    var size: CGFloat = 54

    var body: some View {
        if d.imgCount > 0 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(0..<d.imgCount, id: \.self) { n in
                        Button { store.openImg(d, n) } label: {
                            AsyncImage(url: store.imgURL(d, n), transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                                if let img = phase.image { img.resizable().scaledToFill() }
                                else { Rectangle().fill(Color.primary.opacity(0.06)).overlay(Image(systemName: "photo").foregroundStyle(.tertiary)) }
                            }
                            .frame(width: size, height: size)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("Abrir no Preview")
                    }
                }
            }
        }
    }
}

// MARK: - foto do cliente (grupo ou contato), com fallback de iniciais

struct ClientAvatar: View {
    let url: URL
    let name: String
    let isGroup: Bool
    var size: CGFloat = 44

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            if let img = phase.image {
                img.resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Self.color(for: name))
                    Text(Self.initials(name)).font(.cute(size * 0.34, .bold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    static func initials(_ n: String) -> String {
        let parts = n.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2)
        let s = parts.map { String($0.prefix(1)) }.joined()
        return (s.isEmpty ? String(n.prefix(2)) : s).uppercased()
    }
    static func color(for n: String) -> Color {
        let p: [Color] = [.pink, .purple, .orange, .teal, .indigo, .mint, .blue, .brown]
        var h = 5381
        for u in n.lowercased().unicodeScalars { h = (h &* 33) &+ Int(u.value) }
        return p[abs(h) % p.count]
    }
}

// MARK: - pills

struct Pill: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = .secondary
    var filled = false
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(L(text)).font(.cute(11, .semibold)).lineLimit(1)
        }
        .foregroundStyle(filled ? .white : tint)
        .padding(.horizontal, 8).frame(height: 21)
        .background(Capsule().fill(filled ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.13))))
        .fixedSize()
    }
}

struct DuePill: View {
    let d: Demand
    var body: some View {
        switch d.dueState {
        case .late: Pill(text: "atrasou", symbol: "exclamationmark", tint: Mood.hot)
        case .today: Pill(text: "hoje", symbol: "calendar", tint: Mood.warm)
        case .tomorrow: Pill(text: "amanhã", symbol: "calendar", tint: Mood.calm)
        case .later(let s): Pill(text: s, symbol: "calendar")
        case nil: EmptyView()
        }
    }
}

struct ActionPill: View {
    let text: String
    let symbol: String
    var tint: Color = .primary
    var filled = false
    let action: () -> Void
    @StateObject private var h = Hover()
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .bold))
                Text(L(text)).font(.cute(11.5, .semibold))
            }
            .foregroundStyle(filled ? .white : tint)
            .padding(.horizontal, 11).frame(height: 27)
            .background(Capsule().fill(filled ? AnyShapeStyle(tint.opacity(h.on ? 0.85 : 1)) : AnyShapeStyle(Color.primary.opacity(h.on ? 0.1 : 0.06))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h.on = $0 }
    }
}

/// tempo de espera bem grande
struct WaitBadge: View {
    let d: Demand
    var body: some View {
        let (n, unit) = d.waitParts
        VStack(alignment: .trailing, spacing: -2) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(n).font(.cute(n == "agora" ? 14 : 20, .heavy)).monospacedDigit()
                if !unit.isEmpty { Text(L(unit)).font(.cute(11, .bold)) }
            }
            .foregroundStyle(d.waitColor)
            Text("esperando").font(.cute(9.5, .medium)).foregroundStyle(.secondary)
        }
        .fixedSize()
        .help("Pediu \(Date(timeIntervalSince1970: TimeInterval(d.ts)).formatted(date: .abbreviated, time: .shortened))")
    }
}

// MARK: - card da demanda

struct DemandCard: View {
    @ObservedObject var store: Store
    let d: Demand
    @StateObject private var h = Hover()

    var body: some View {
        let expanded = store.expanded == d.id
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                ClientAvatar(url: store.avatarURL(d.jid), name: d.client, isGroup: d.isGroup, size: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text(d.client).font(.cute(11.5, .semibold)).foregroundStyle(.secondary).lineLimit(1)
                    Text(d.title).font(.cute(14, .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) {
                        if !d.who.isEmpty { Pill(text: d.who, symbol: d.isGroup ? "person.2.fill" : "person.fill") }
                        DuePill(d: d)
                        if d.urgent { Pill(text: "urgente", symbol: "bolt.fill", tint: Mood.hot) }
                        if !d.mine { Pill(text: d.areaLabel, symbol: "arrow.turn.up.right") }
                    }
                    if let f = d.fazendoTexto { PilulaFazendo(texto: f, claude: d.doing == "claude") }
                    if let hint = d.doneHint { PareceProto(store: store, d: d, porClaude: hint == "claude") }
                    if let e = d.esperaTexto { PilulaEspera(texto: e, respondida: d.espera == "respondida") }
                }
                Spacer(minLength: 6)
                WaitBadge(d: d)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if !d.detail.isEmpty { Text(d.detail).font(.cute(12.5)).fixedSize(horizontal: false, vertical: true) }
                    Text("\u{201C}\(d.quote)\u{201D}")
                        .font(.cute(12)).foregroundStyle(.secondary)
                        .padding(.leading, 9)
                        .overlay(alignment: .leading) { Capsule().fill(Color.primary.opacity(0.15)).frame(width: 2.5) }
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    RefStrip(store: store, d: d, size: 48)
                    Text(d.isGroup ? "no grupo \(d.chatName)" : "conversa direta")
                        .font(.cute(10.5)).foregroundStyle(.tertiary)
                }
                .padding(.leading, 56)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if expanded || h.on {
                HStack(spacing: 6) {
                    ActionPill(text: "Claude Code", symbol: "sparkle", tint: Mood.claude, filled: true) { store.onClaude?(d) }
                    ActionPill(text: "feito", symbol: "checkmark", tint: Mood.calm) { store.done(d) }
                    ActionPill(text: "responder", symbol: "arrowshape.turn.up.left.fill", tint: .blue) { store.responderNoChat(jid: d.jid, msgId: d.msgId) }
                    Menu {
                        Menu("Passar pra…") { PassarMenu(store: store, d: d) }
                        Button("Ver conversa no ZapFast") { openZapFast() }
                        Button("Não é demanda") { store.ignore(d) }
                        Button("Ignorar \(d.isGroup ? "esse grupo" : "essa conversa")") { store.mute(d) }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .padding(.horizontal, 10).frame(height: 27)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                .padding(.leading, 56)
                .transition(.opacity)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(h.on || expanded ? 0.06 : 0.035)))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onHover { on in withAnimation(.easeOut(duration: 0.15)) { h.on = on } }
        .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { store.expanded = expanded ? nil : d.id } }
    }
}

// demandas de outras áreas (tráfego, comercial…) ficam guardadas aqui, discretas
struct OthersSection: View {
    @ObservedObject var store: Store
    var body: some View {
        let others = store.others
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button { withAnimation(.spring(response: 0.3)) { store.showOthers.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: store.showOthers ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                        Text("\(others.count) de outras áreas").font(.cute(11.5, .semibold))
                        Text(Array(Set(others.map(\.areaLabel))).sorted().joined(separator: ", ")).font(.cute(11)).foregroundStyle(.tertiary).lineLimit(1)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.top, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if store.showOthers {
                    ForEach(others) { d in DemandCard(store: store, d: d).opacity(0.75) }
                }
            }
        }
    }
}

// MARK: - card por cliente (aba Todos)

struct ClientCard: View {
    @ObservedObject var store: Store
    let g: ClientGroup
    @StateObject private var h = Hover()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                ClientAvatar(url: store.avatarURL(g.face.jid), name: g.name, isGroup: g.face.isGroup, size: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text(g.name).font(.cute(15, .bold)).lineLimit(1)
                    HStack(spacing: 5) {
                        ForEach(g.people.prefix(g.demands.contains(where: \.urgent) ? 1 : 2), id: \.self) { Pill(text: $0, symbol: "person.fill") }
                        if g.demands.contains(where: \.urgent) { Pill(text: "urgente", symbol: "bolt.fill", tint: Mood.hot) }
                    }
                }
                Spacer(minLength: 6)
                WaitBadge(d: g.oldest)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(g.demands) { d in
                    HStack(spacing: 8) {
                        Circle().fill(d.waitColor).frame(width: 6, height: 6)
                        Text(d.title).font(.cute(12.5)).lineLimit(1)
                        DuePill(d: d).scaleEffect(0.9)
                        Spacer(minLength: 4)
                        if h.on {
                            Button { store.done(d) } label: {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Mood.calm)
                                    .frame(width: 22, height: 20).background(Capsule().fill(Mood.calm.opacity(0.13)))
                            }
                            .buttonStyle(.plain).help("Marcar essa como feita")
                        }
                    }
                }
            }
            .padding(.leading, 56)

            HStack(spacing: 6) {
                ActionPill(text: g.demands.count == 1 ? "Claude Code" : "mandar tudo pro Claude Code", symbol: "sparkle", tint: Mood.claude, filled: true) {
                    store.onClaudeClient?(g)
                }
                if h.on {
                    ActionPill(text: "ver uma por uma", symbol: "list.bullet") {
                        withAnimation(.spring(response: 0.3)) { store.clientFilter = g.name }
                    }
                    ActionPill(text: "tudo feito", symbol: "checkmark", tint: Mood.calm) { store.doneAll(g) }
                        .transition(.opacity)
                }
            }
            .padding(.leading, 56)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(h.on ? 0.06 : 0.035)))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onHover { on in withAnimation(.easeOut(duration: 0.15)) { h.on = on } }
        .onTapGesture { withAnimation(.spring(response: 0.3)) { store.clientFilter = g.name } }
    }
}

struct DoneRow: View {
    @ObservedObject var store: Store
    let d: Demand
    var body: some View {
        HStack(spacing: 10) {
            ClientAvatar(url: store.avatarURL(d.jid), name: d.client, isGroup: d.isGroup, size: 30)
                .saturation(0.4).opacity(0.8)
            VStack(alignment: .leading, spacing: 2) {
                Text(d.title).font(.cute(12.5, .medium)).strikethrough(color: .secondary).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 5) {
                    Text(d.client).font(.cute(10.5)).foregroundStyle(.tertiary)
                    if d.autoDone { Pill(text: "vi que tu entregou", symbol: "sparkle", tint: Mood.calm) }
                }
            }
            Spacer()
            Button("desfazer") { store.reopen(d) }.buttonStyle(.plain).font(.cute(11, .semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }
}

// MARK: - popover

struct PopoverView: View {
    @ObservedObject var store: Store

    var body: some View {
        if let jid = store.zapChat {
            conversa(jid)
        } else {
            switch store.layout {
            case .classico: lista
            case .caixa: PopCaixa(store: store, zp: store.zp)
            case .conversa: PopConversa(store: store, zp: store.zp)
            case .hoje: PopHoje(store: store, zp: store.zp)
            }
        }
    }

    /// conversa privada aberta direto no popover (o chat de verdade, com áudio, figurinha, anexo)
    @ViewBuilder func conversa(_ jid: String) -> some View {
        let chat = store.zp.chats.first { $0.jid == jid }
            ?? Chat(jid: jid, name: store.unread.first { $0.jid == jid }?.name ?? jid, last: "", lastTs: 0, unread: 0)
        ChatView(store: store.zp, chat: chat, compact: true,
                 onBack: { store.fecharConversa() },
                 onWindow: { store.onOpenChat?(jid) })
            .frame(width: 420, height: 580)
            .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    var lista: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !store.serverUp {
                Banner(symbol: "hourglass", text: "Ligando o motorzinho…")
            } else {
                PonteAviso(store: store)
            }
            switch store.tab {
            case .zap:
                ZapModo(store: store)
                if store.zapTodas {
                    ConversasLista(store: store.zp, compact: true) { store.abrirConversa($0) }
                        .frame(height: 470)
                } else {
                    ZapList(store: store)
                }
            case .open: openList
            case .mentions: MentionsList(store: store)
            }
        }
        .padding(12)
        .frame(width: 420)
    }

    var header: some View {
        HStack(spacing: 5) {
            tabButton(.zap, "Zap", store.unread.count, dot: !store.toReply.isEmpty)
            tabButton(.open, "Demandas", store.mine.count)
            tabButton(.mentions, "@", store.mentionsOpen.count, dot: store.mentionsUnseen > 0)
            Spacer(minLength: 4)
            if store.scanning > 0 || store.unreadBusy > 0 {
                ProgressView().controlSize(.mini)
                    .help(store.unreadBusy > 0 ? "Lendo \(store.unreadBusy) conversa(s)" : "Procurando demandas em \(store.scanning) conversa(s)")
            }
            PonteDot(store: store)
            JanelaButton { store.onOpenWindow?() }
            GearMenu(store: store)
        }
    }

    func tabButton(_ t: Tab, _ label: String, _ n: Int, dot: Bool = false) -> some View {
        let sel = store.tab == t
        return Button {
            withAnimation(.spring(response: 0.3)) { store.tab = t }
            if t == .mentions { store.seeMentions() }
        } label: {
            HStack(spacing: 4) {
                Text(L(label))
                if n > 0 { Text("\(n)").monospacedDigit().opacity(0.55) }
                if dot && !sel { Circle().fill(Mood.calm).frame(width: 6, height: 6) }
            }
            .font(.cute(12, .semibold))
            .foregroundStyle(sel ? Color(nsColor: .windowBackgroundColor) : .secondary)
            .padding(.horizontal, 11).frame(height: 26)
            .background(Capsule().fill(sel ? Color.primary : Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder var openList: some View {
        if let c = store.clientFilter {
            Button { withAnimation(.spring(response: 0.3)) { store.clientFilter = nil } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                    Text(c).font(.cute(12, .semibold))
                    Text("\(store.visible.count)").font(.cute(11, .bold)).monospacedDigit().opacity(0.5)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Voltar pra todos os clientes")
        }
        let items = store.visible
        if items.isEmpty {
            Calm(scanning: store.scanning > 0 && !store.booted)
            if store.clientFilter == nil { OthersSection(store: store); DoneSection(store: store) }
        } else if store.clientFilter == nil {
            let groups = store.groups
            FitScroll(maxHeight: 500) {
                VStack(spacing: 8) {
                    ForEach(groups) { g in ClientCard(store: store, g: g) }
                    OthersSection(store: store)
                    DoneSection(store: store)
                }
            }
        } else {
            FitScroll(maxHeight: 480) {
                VStack(spacing: 8) {
                    ForEach(items) { d in DemandCard(store: store, d: d) }
                }
            }
        }
    }
}

/// feitas hoje: discretas no fim da aba Demandas
struct DoneSection: View {
    @ObservedObject var store: Store
    var body: some View {
        if !store.doneToday.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Disclosure(open: store.showDone, text: "\(store.doneToday.count) feita\(store.doneToday.count == 1 ? "" : "s") hoje") {
                    withAnimation(.spring(response: 0.3)) { store.showDone.toggle() }
                }
                if store.showDone { ForEach(store.doneToday) { d in DoneRow(store: store, d: d) } }
            }
        }
    }
}

struct Disclosure: View {
    let open: Bool
    let text: String
    var trailing: AnyView? = nil
    let action: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                    Text(L(text)).font(.cute(11.5, .semibold))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let trailing { trailing }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6).padding(.top, 4)
    }
}

// MARK: - lista que cresce até um máximo (mede o conteúdo em vez de chutar a altura)

private struct HKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
final class Measure: ObservableObject { @Published var h: CGFloat = 0 }

struct FitScroll<Content: View>: View {
    var maxHeight: CGFloat
    @ViewBuilder var content: Content
    @StateObject private var m = Measure()
    var body: some View {
        ScrollView {
            content.background(GeometryReader { g in Color.clear.preference(key: HKey.self, value: g.size.height) })
        }
        .frame(height: min(maxHeight, max(m.h, 40)))
        .onPreferenceChange(HKey.self) { v in if abs(v - m.h) > 0.5 { m.h = v } }
    }
}

// MARK: - Zap: o que chegou e eu não li, resumido; quando precisa, a resposta já vem pronta

struct ZapList: View {
    @ObservedObject var store: Store
    var body: some View {
        let reply = store.toReply
        let know = store.toKnow
        if store.unread.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.bubble.fill").font(.system(size: 28)).foregroundStyle(Mood.calm)
                Text("Tudo lido").font(.cute(14, .semibold))
                Text("Quando chegar mensagem que tu ainda não leu, eu resumo aqui e, se precisar de ti, já deixo a resposta pronta.")
                    .font(.cute(11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 26)
        } else {
            FitScroll(maxHeight: 540) {
                VStack(alignment: .leading, spacing: 6) {
                    if !reply.isEmpty {
                        SectionTitle(text: "Esperando tua resposta", n: reply.count)
                        ForEach(reply) { c in ZapRow(store: store, c: c) }
                    }
                    if !know.isEmpty {
                        HStack {
                            SectionTitle(text: reply.isEmpty ? "Chegou" : "Só pra saber", n: know.count)
                            Spacer()
                            Button("marcar tudo como lido") { store.unreadOKAll(know.filter { !$0.pending }) }
                                .buttonStyle(.plain).font(.cute(11, .semibold)).foregroundStyle(.secondary)
                                .help("Some daqui. No celular continua como não lida.")
                        }
                        .padding(.top, reply.isEmpty ? 0 : 6)
                        ForEach(know) { c in ZapRow(store: store, c: c) }
                    }
                }
            }
        }
    }
}

/// aba Zap: não lidas resumidas pela IA ou todas as conversas privadas
struct ZapModo: View {
    @ObservedObject var store: Store
    var body: some View {
        HStack(spacing: 4) {
            botao(false, "Resumo", store.unread.count)
            botao(true, "Conversas", store.zp.chats.filter { $0.unread > 0 }.count)
            Spacer()
        }
    }
    func botao(_ todas: Bool, _ t: String, _ n: Int) -> some View {
        let sel = store.zapTodas == todas
        return Button { withAnimation(.spring(response: 0.3)) { store.zapTodas = todas } } label: {
            HStack(spacing: 4) {
                Text(L(t))
                if n > 0 { Text("\(n)").monospacedDigit().opacity(0.55) }
            }
            .font(.cute(11.5, .semibold))
            .foregroundStyle(sel ? Color.primary : Color.secondary)
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(Color.primary.opacity(sel ? 0.1 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SectionTitle: View {
    let text: String
    let n: Int
    var body: some View {
        HStack(spacing: 5) {
            Text(L(text)).font(.cute(11.5, .bold))
            Text("\(n)").font(.cute(11, .bold)).monospacedDigit().opacity(0.5)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}

struct ZapRow: View {
    @ObservedObject var store: Store
    let c: UnreadChat
    @StateObject private var h = Hover()

    var body: some View {
        let open = store.expandedChat == c.jid
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ClientAvatar(url: store.avatarURL(c.jid), name: c.name, isGroup: c.isGroup, size: c.needsReply ? 34 : 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(c.title).font(.cute(12, .semibold)).foregroundStyle(.secondary).lineLimit(1)
                        if c.count > 1 { Text("\(c.count)").font(.cute(10.5, .bold)).monospacedDigit().foregroundStyle(.tertiary) }
                        if c.urgent { Pill(text: "urgente", symbol: "bolt.fill", tint: Mood.hot) }
                        Spacer(minLength: 4)
                        if h.on && !c.needsReply {
                            Button { store.unreadOK(c) } label: {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Mood.calm)
                                    .frame(width: 24, height: 18).background(Capsule().fill(Mood.calm.opacity(0.13)))
                            }
                            .buttonStyle(.plain).help("Ok, li")
                        } else {
                            Text(c.ago).font(.cute(10.5, .medium)).foregroundStyle(.tertiary).monospacedDigit()
                        }
                    }
                    if c.summary.isEmpty {
                        HStack(spacing: 6) {
                            if c.pending { ProgressView().controlSize(.mini) }
                            Text(c.pending ? "lendo…" : (c.tail.last.map { "\($0.who): \($0.text)" } ?? ""))
                                .font(.cute(12.5)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    } else {
                        Text(c.summary).font(.cute(c.needsReply ? 13.5 : 12.5, c.needsReply ? .semibold : .regular))
                            .lineLimit(open ? nil : 3).fixedSize(horizontal: false, vertical: true)
                    }
                    if c.demands > 0 {
                        Pill(text: c.demands == 1 ? "1 demanda anotada" : "\(c.demands) demandas anotadas", symbol: "tray.full.fill", tint: Mood.calm)
                            .padding(.top, 2)
                    }
                }
            }

            if open {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(c.tail, id: \.self) { l in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(l.who).font(.cute(11, .semibold)).foregroundStyle(l.me ? Mood.calm : .secondary).frame(width: 58, alignment: .trailing).lineLimit(1)
                            Text(l.text).font(.cute(12)).foregroundStyle(l.me ? .secondary : .primary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                }
                .padding(.leading, -6)
                .transition(.opacity)
            }

            if c.needsReply { ReplyBox(store: store, c: c).padding(.leading, 44) }

            if open || (h.on && c.needsReply) {
                HStack(spacing: 6) {
                    if c.needsReply { ActionPill(text: "ok, li", symbol: "checkmark", tint: Mood.calm) { store.unreadOK(c) } }
                    ActionPill(text: "ZapFast", symbol: "arrow.up.forward.app") { openZapFast() }
                }
                .padding(.leading, 44)
                .transition(.opacity)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(h.on || open ? 0.06 : 0.035)))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onHover { on in withAnimation(.easeOut(duration: 0.15)) { h.on = on } }
        .onTapGesture {
            if c.isGroup {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { store.expandedChat = open ? nil : c.jid }
            } else {
                store.abrirConversa(c.jid)
            }
        }
        .help(c.isGroup ? (open ? "" : "Clica pra ver as mensagens") : "Clica pra abrir a conversa")
    }
}

/// resposta sugerida, editável; só sai quando eu clico em enviar
struct ReplyBox: View {
    @ObservedObject var store: Store
    let c: UnreadChat
    /// ⌘↩ envia (só na janela, onde tem uma caixa por vez)
    var atalho = false
    var linhas = 6

    var body: some View {
        let sending = store.sending.contains(c.jid)
        let redoing = store.redoing.contains(c.jid) || (c.pending && c.suggestion == nil)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 6) {
                TextField(redoing ? "pensando numa resposta…" : "tua resposta", text: Binding(
                    get: { store.draft(c) },
                    set: { store.drafts[c.jid] = ($0 == (c.suggestion ?? "")) ? nil : $0 }), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.cute(12.5))
                    .lineLimit(1...linhas)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(0.7)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                    .disabled(sending)
                Button { store.reply(c) } label: {
                    Group {
                        if sending { ProgressView().controlSize(.small) }
                        else { Image(systemName: "paperplane.fill").font(.system(size: 12, weight: .bold)) }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Mood.calm.opacity(store.draft(c).isEmpty ? 0.35 : 1)))
                }
                .buttonStyle(.plain)
                .disabled(store.draft(c).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                .keyboardShortcut(atalho ? KeyboardShortcut(.return, modifiers: .command) : nil)
                .help(atalho ? "Enviar no WhatsApp (⌘↩)" : "Enviar no WhatsApp")
            }
            HStack(spacing: 10) {
                if redoing { ProgressView().controlSize(.mini) }
                Button("outra sugestão") { store.redo(c) }.disabled(redoing)
                Button("mais curta") { store.redo(c, hint: "bem mais curta, 1 frase") }.disabled(redoing)
                Button("vou ver e respondo") { store.drafts[c.jid] = c.isGroup ? "Vou ver isso e já te falo" : "vou ver isso e ja te falo" }
                Spacer()
                if let e = store.sendError[c.jid] { Text(L(e)).foregroundStyle(Mood.hot).lineLimit(1) }
            }
            .buttonStyle(.plain)
            .font(.cute(10.5, .semibold))
            .foregroundStyle(.secondary)
        }
    }
}

/// engrenagem: ajustes que antes ficavam no rodapé
struct GearMenu: View {
    @ObservedObject var store: Store
    @StateObject private var ui = Hover(launch: SMAppService.mainApp.status == .enabled)
    @AppStorage("sound") private var sound = "b"
    var body: some View {
        Menu {
            Menu("Layout") {
                ForEach(Layout.allCases) { l in
                    Toggle(l.nome, isOn: Binding(get: { store.layout == l }, set: { _ in store.fecharConversa(); store.layout = l }))
                }
            }
            Divider()
            Button("Atualizar") { Task { await store.refresh() } }
            Toggle("Abrir quando ligar o Mac", isOn: Binding(
                get: { ui.launch },
                set: { on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
                    ui.launch = SMAppService.mainApp.status == .enabled
                }))
            Menu("Som de demanda nova") {
                ForEach(WakeSound.options, id: \.id) { o in
                    Toggle(L(o.name), isOn: Binding(get: { sound == o.id }, set: { _ in sound = o.id; WakeSound.play(o.id) }))
                }
                Divider()
                Toggle("Sem som", isOn: Binding(get: { sound == "off" }, set: { _ in sound = "off" }))
                Divider()
                Button("Testar animação") { DistributedNotificationCenter.default().postNotificationName(.init("app.sisifo.wake"), object: "Nova demanda de Teste", userInfo: nil, deliverImmediately: true) }
            }
            Divider()
            Button("Abrir janela (⌥⇧Z)") { store.onOpenWindow?() }
            Button("Abrir ZapFast") { openZapFast() }
            Divider()
            Text("⌥Z abre isto de qualquer lugar")
            Button("Fechar Sísifo") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape.fill").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .frame(width: 26, height: 24)
    }
}

// MARK: - marcações (a gestora lê o grupo por ti e deixa 1 linha)

struct MentionsList: View {
    @ObservedObject var store: Store
    var body: some View {
        let items = store.mentionsOpen
        let done = store.mentionsDone
        if items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "at").font(.system(size: 28, weight: .semibold)).foregroundStyle(Mood.calm)
                Text("Ninguém te chamando").font(.cute(14, .semibold))
                Text("Quando te marcarem num grupo, eu leio e deixo aqui só o que querem de ti, em uma linha.")
                    .font(.cute(11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 26)
        }
        ScrollView {
            VStack(spacing: 6) {
                ForEach(items) { m in MentionRow(store: store, m: m) }
                if !done.isEmpty {
                    Button { withAnimation(.spring(response: 0.3)) { store.showOkMentions.toggle() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: store.showOkMentions ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                            Text("\(done.count) já resolvidas").font(.cute(11.5, .semibold))
                            Spacer()
                        }
                        .foregroundStyle(.secondary).padding(.horizontal, 6).padding(.top, 4).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if store.showOkMentions { ForEach(done) { m in MentionRow(store: store, m: m).opacity(0.6) } }
                }
            }
        }
        .frame(height: min(470, CGFloat(items.count) * 74 + (done.isEmpty ? 0 : 30) + (store.showOkMentions ? CGFloat(done.count) * 74 : 0) + 6))
    }
}

struct MentionRow: View {
    @ObservedObject var store: Store
    let m: Mention
    @StateObject private var h = Hover()
    @StateObject private var o = Hover()

    var body: some View {
        let open = o.on
        let (label, symbol, tint) = m.kindLabel
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ClientAvatar(url: store.avatarURL(m.jid), name: m.client, isGroup: true, size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(m.client).font(.cute(11.5, .semibold)).foregroundStyle(.secondary).lineLimit(1)
                        Text("· \(m.who) \(m.how == "respondeu" ? "respondeu" : "te marcou")").font(.cute(11)).foregroundStyle(.tertiary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(m.ago).font(.cute(10.5, .medium)).foregroundStyle(.tertiary).monospacedDigit()
                    }
                    Text(m.summary).font(.cute(13.5, .semibold)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) {
                        Pill(text: label, symbol: symbol, tint: tint)
                        if m.urgent { Pill(text: "urgente", symbol: "bolt.fill", tint: Mood.hot) }
                        if m.demandId != nil { Pill(text: "já tá em Pra mim", symbol: "tray.full.fill", tint: Mood.calm) }
                        if !m.seen { Circle().fill(Color.blue).frame(width: 6, height: 6) }
                    }
                }
            }
            if open {
                Text("\u{201C}\(m.quote)\u{201D}")
                    .font(.cute(12)).foregroundStyle(.secondary)
                    .padding(.leading, 9)
                    .overlay(alignment: .leading) { Capsule().fill(Color.primary.opacity(0.15)).frame(width: 2.5) }
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 44)
                    .transition(.opacity)
            }
            if h.on || open {
                HStack(spacing: 6) {
                    if m.ok {
                        ActionPill(text: "voltar pra lista", symbol: "arrow.uturn.backward") { store.mentionOK(m, false) }
                    } else {
                        ActionPill(text: "ok, visto", symbol: "checkmark", tint: Mood.calm, filled: true) { store.mentionOK(m) }
                        ActionPill(text: "responder", symbol: "arrowshape.turn.up.left.fill", tint: .blue) { store.responderNoChat(jid: m.jid, msgId: m.id) }
                    }
                    ActionPill(text: open ? "esconder mensagem" : "ver mensagem", symbol: "text.quote") {
                        withAnimation(.spring(response: 0.3)) { o.on.toggle() }
                    }
                    ActionPill(text: "ZapFast", symbol: "arrow.up.forward.app") { openZapFast() }
                }
                .padding(.leading, 44)
                .transition(.opacity)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(h.on || open ? 0.06 : 0.035)))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onHover { on in withAnimation(.easeOut(duration: 0.15)) { h.on = on } }
    }
}

struct Calm: View {
    let scanning: Bool
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: scanning ? "text.magnifyingglass" : "leaf.fill")
                .font(.system(size: 30)).foregroundStyle(Mood.calm)
            Text(scanning ? "Lendo teu WhatsApp…" : "Nada pendente").font(.cute(14, .semibold))
            Text(scanning ? "Na primeira vez leva uns minutinhos. As demandas vão aparecendo aqui." : "Quando um cliente pedir algo, aparece aqui e eu te aviso.")
                .font(.cute(11.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 30)
    }
}

struct Banner: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(Mood.warm)
            Text(L(text)).font(.cute(11.5)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Mood.warm.opacity(0.1)))
    }
}

/// abre a janela à parte, com tudo mais detalhado
struct JanelaButton: View {
    let action: () -> Void
    @StateObject private var h = Hover()
    var body: some View {
        Button(action: action) {
            Image(systemName: "macwindow")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 24)
                .background(Capsule().fill(Color.primary.opacity(h.on ? 0.1 : 0.06)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h.on = $0 }
        .help("Abrir em janela (⌥⇧Z)")
    }
}
