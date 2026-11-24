import ServiceManagement
import SwiftUI
import AppKit

// Três layouts escolhíveis em ⚙︎ › Layout (o "Clássico" continua sendo o de abas):
//  A · Caixa única       tudo numa lista só, ação no próprio cartão; janela = lista + detalhe
//  B · Conversa no centro estilo Mensagens; janela = conversas · chat · painel daquela conversa
//  C · Hoje              popover = um item por vez; janela = raias Responder/Fazer/Só saber
// O filtro Tudo · Privado · Trabalho mora no ChatStore e vale pros três.

// MARK: - peças

extension ItemFeed.Tipo {
    var rotulo: String { L(rotuloPT) }
    var rotuloPT: String {
        switch self { case .responder: return "Responder"; case .marcacao: return "@ marcou"; case .demanda: return "Demanda"; case .saber: return "Só saber"; case .aguardando: return "Aguardando" }
    }
    var chip: String { L(chipPT) }
    var chipPT: String {
        switch self { case .responder: return "Responder"; case .marcacao: return "@"; case .demanda: return "Demandas"; case .saber: return "Lidas"; case .aguardando: return "Aguardando" }
    }
    var icone: String {
        switch self { case .responder: return "sparkles"; case .marcacao: return "at"; case .demanda: return "tray.full.fill"; case .saber: return "eye"; case .aguardando: return "hourglass" }
    }
    var cor: Color {
        switch self { case .responder: return .blue; case .marcacao: return .purple; case .demanda: return Mood.warm; case .saber: return .secondary; case .aguardando: return .teal }
    }
}

/// chips que filtram a caixa única por tipo (um toque liga, outro desliga)
struct ChipsFeed: View {
    @ObservedObject var store: Store
    @ObservedObject var zp: ChatStore
    var tipos: [ItemFeed.Tipo] = [.responder, .demanda, .marcacao, .aguardando, .saber]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(tipos, id: \.self) { t in
                let n = store.conta(t), sel = store.chip == t
                Button { withAnimation(.snappy(duration: 0.2)) { store.chip = sel ? nil : t } } label: {
                    HStack(spacing: 5) {
                        Text(L(t.chip))
                        if n > 0 { Text("\(n)").monospacedDigit().fontWeight(.bold).opacity(sel ? 1 : 0.85) }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(sel ? Color(nsColor: .windowBackgroundColor) : (n > 0 ? Color.primary : Color.secondary))
                    .padding(.horizontal, 11).frame(height: 28)
                    .background(Capsule().fill(sel ? Color.primary : Color.primary.opacity(0.07)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize()
    }
}

/// botão em cápsula das ações dos cartões
struct Acao: View {
    let texto: String
    let icone: String
    var cor: Color = .primary
    var cheio = false
    let acao: () -> Void
    var body: some View {
        Button(action: acao) {
            HStack(spacing: 5) {
                Image(systemName: icone).font(.system(size: 10.5, weight: .bold))
                if !texto.isEmpty { Text(L(texto)).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize() }
            }
            .foregroundStyle(cheio ? Color.white : cor)
            .padding(.horizontal, 11).frame(height: 28)
            .background(Capsule().fill(cheio ? cor : cor.opacity(cor == .primary ? 0.07 : 0.13)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// resposta pronta como pílula: toque no texto edita (abre a conversa), seta envia
struct SugestaoPilula: View {
    @ObservedObject var store: Store
    let c: UnreadChat
    var abrir: () -> Void
    var body: some View {
        let enviando = store.sending.contains(c.jid)
        let pensando = store.redoing.contains(c.jid) || (c.pending && c.suggestion == nil)
        HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.blue)
            if pensando {
                Text("pensando numa resposta…").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                ProgressView().controlSize(.mini)
            } else {
                Text(store.draft(c)).font(.system(size: 12.5)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle()).onTapGesture(perform: abrir)
                    .help("Abrir a conversa pra editar")
                Menu {
                    Button("Outra sugestão") { store.redo(c) }
                    Button("Mais curta") { store.redo(c, hint: "bem mais curta, 1 frase") }
                    Button("Vou ver e respondo") { store.drafts[c.jid] = c.isGroup ? "Vou ver isso e já te falo" : "vou ver isso e ja te falo" }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                Button { store.reply(c) } label: {
                    Group {
                        if enviando { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)) }
                    }
                    .foregroundStyle(.white).frame(width: 26, height: 26)
                    .background(Circle().fill(Color.blue))
                }
                .buttonStyle(.plain).disabled(enviando || store.draft(c).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Enviar no WhatsApp")
            }
        }
        .padding(.leading, 11).padding(.trailing, 5).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.blue.opacity(0.1)))
    }
}

/// cartão da caixa única (popover e janela)
struct CartaoFeed: View {
    @ObservedObject var store: Store
    let i: ItemFeed
    var compacto = false
    var selecionado = false
    /// lista estreita da janela: rótulos curtos nos botões
    var curto = false
    /// false na coluna Fazendo do layout Hoje: a coluna já diz, fica só o ícone de quem
    var mostraFazendo = true
    var abrir: () -> Void
    @StateObject private var h = Hover()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ClientAvatar(url: store.avatarURL(i.jid), name: i.nome, isGroup: i.grupo, size: compacto ? 28 : 34)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(i.nome).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if i.urgente { Pill(text: "urgente", symbol: "bolt.fill", tint: Mood.hot) }
                        Spacer(minLength: 4)
                        if !mostraFazendo, let d = i.demand, d.doing != nil {
                            Image(systemName: d.doing == "claude" ? "sparkle" : "hammer.fill").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(d.doing == "claude" ? Color.purple : Color.indigo)
                                .help(d.fazendoTexto ?? "")
                        }
                        Text(i.ago).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                    }
                    if !compacto {
                        HStack(spacing: 4) {
                            Pill(text: i.tipo.rotulo, tint: i.tipo.cor)
                            if let d = i.demand { Pill(text: d.client) ; if !d.who.isEmpty && d.isGroup { Pill(text: d.who) } }
                            if let m = i.mention, !m.who.isEmpty { Pill(text: m.who) }
                            if let c = i.unread, c.count > 1 { Pill(text: "\(c.count) msgs") }
                        }
                    }
                    if mostraFazendo, let d = i.demand, let f = d.fazendoTexto {
                        PilulaFazendo(texto: f, claude: d.doing == "claude")
                    }
                    if let d = i.demand, let h = d.doneHint {
                        PareceProto(store: store, d: d, porClaude: h == "claude")
                    }
                    if let e = i.esperaTexto {
                        PilulaEspera(texto: e, respondida: (i.demand?.espera ?? i.unread?.espera ?? i.mention?.espera) == "respondida")
                    }
                    Text(i.resumo).font(.system(size: compacto ? 12 : 12.5)).foregroundStyle(i.tipo == .saber || i.tipo == .aguardando ? Color.secondary : Color.primary)
                        .lineLimit(compacto ? 3 : 4).fixedSize(horizontal: false, vertical: true)
                }
            }
            acoes.padding(.leading, compacto ? 38 : 44)
        }
        .padding(compacto ? 10 : 11)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.primary.opacity(selecionado ? 0.09 : (h.on ? 0.065 : 0.045))))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(selecionado ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onHover { on in withAnimation(.easeOut(duration: 0.12)) { h.on = on } }
        .onTapGesture(perform: abrir)
    }

    @ViewBuilder var acoes: some View {
        switch i.tipo {
        case .responder:
            if let c = i.unread {
                SugestaoPilula(store: store, c: c, abrir: abrir)
                HStack(spacing: 6) {
                    Acao(texto: "Já li", icone: "eye", cor: .secondary) { store.unreadOK(c) }
                    Acao(texto: c.isGroup ? "Alguém respondeu" : "Já respondi", icone: "checkmark.bubble", cor: Mood.calm) {
                        store.unreadOK(c, motivo: "respondido")
                    }
                }
            }
            if let e = i.unread.flatMap({ store.sendError[$0.jid] }) { Text(L(e)).font(.system(size: 11)).foregroundStyle(Mood.hot) }
        case .saber:
            if h.on || selecionado, let c = i.unread {
                HStack(spacing: 6) { Acao(texto: "ok, li", icone: "checkmark", cor: Mood.calm) { store.unreadOK(c) } }
            }
        case .demanda:
            if let d = i.demand {
                HStack(spacing: 6) {
                    Acao(texto: "Feito", icone: "checkmark", cor: Mood.calm) { store.done(d) }
                    Acao(texto: compacto ? "" : (curto ? "Claude" : "Claude Code"), icone: "sparkle", cor: Mood.claude) { store.onClaude?(d) }
                        .help("Claude Code")
                    Acao(texto: compacto || curto ? "" : "Responder", icone: "arrowshape.turn.up.left.fill", cor: .blue) { store.responderNoChat(jid: d.jid, msgId: d.msgId) }
                        .help("Abrir o chat dessa conversa, na mensagem do pedido")
                    if !compacto {
                        Menu { PassarMenu(store: store, d: d) } label: {
                            Text(curto ? "Passar…" : "Passar pra…").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 11).frame(height: 28)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    } else {
                        // ⋯ do cartão compacto: Tô fazendo / Parar / passar pra
                        Menu { PassarMenu(store: store, d: d) } label: {
                            Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                                .frame(width: 28, height: 28).background(Circle().fill(Color.primary.opacity(0.07)))
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    }
                }
            }
        case .marcacao:
            if let m = i.mention {
                HStack(spacing: 6) {
                    Acao(texto: "Visto", icone: "checkmark", cor: Mood.calm) { store.mentionOK(m) }
                    Acao(texto: "Responder", icone: "arrowshape.turn.up.left.fill", cor: .blue) { store.responderNoChat(jid: m.jid, msgId: m.id) }
                }
            }
        case .aguardando:
            if h.on || selecionado {
                HStack(spacing: 6) {
                    if let d = i.demand {
                        Acao(texto: "Feito", icone: "checkmark", cor: Mood.calm) { store.done(d) }
                        Acao(texto: curto || compacto ? "Pra mim" : "Voltar pra mim", icone: "arrow.uturn.left", cor: .secondary) { store.voltarPraMim(d) }
                    } else if let c = i.unread {
                        Acao(texto: "ok, li", icone: "checkmark", cor: Mood.calm) { store.unreadOK(c) }
                    } else if let m = i.mention {
                        Acao(texto: "Visto", icone: "checkmark", cor: Mood.calm) { store.mentionOK(m) }
                    }
                    Acao(texto: curto || compacto ? "" : "Responder", icone: "arrowshape.turn.up.left.fill", cor: .blue) {
                        store.responderNoChat(jid: i.jid, msgId: i.demand?.msgId ?? i.mention?.id)
                    }
                }
            }
        }
    }
}

/// "✦ Claude fazendo · 12 min" / "fazendo (tu)"
struct PilulaFazendo: View {
    let texto: String
    var claude = false
    var body: some View {
        let cor = claude ? Color.purple : Color.indigo
        HStack(spacing: 4) {
            Image(systemName: claude ? "sparkle" : "hammer.fill").font(.system(size: 9.5, weight: .bold))
            Text(L(texto)).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.tail)
        }
        .foregroundStyle(cor)
        .padding(.horizontal, 8).frame(height: 20)
        .background(Capsule().fill(cor.opacity(0.13)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "parece pronto": sugestão com confirmar (nunca fecha sozinho)
struct PareceProto: View {
    @ObservedObject var store: Store
    let d: Demand
    var porClaude = false
    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 9.5, weight: .bold))
                Text(porClaude ? "Claude terminou · feito?" : "parece pronto").font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(Mood.calm)
            .padding(.horizontal, 8).frame(height: 20)
            .background(Capsule().fill(Mood.calm.opacity(0.14)))
            .help(d.doneHintQuote.map { "Tu mandou: \"\($0)\"" } ?? "A sessão do Claude parou de mexer há alguns minutos")
            Button { store.done(d) } label: {
                Text("confirmar").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 9).frame(height: 20).background(Capsule().fill(Mood.calm))
            }
            .buttonStyle(.plain).help("Marcar como feito")
            Button { store.descartarPronto(d) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 20, height: 20).background(Circle().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain).help("Ainda não")
        }
    }
}

/// "respondida por X" / "esperando cliente · o que falta" (corta com … pra não estourar o cartão)
struct PilulaEspera: View {
    let texto: String
    var respondida = false
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: respondida ? "checkmark.bubble.fill" : "hourglass").font(.system(size: 9.5, weight: .bold))
            Text(L(texto)).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.tail)
        }
        .foregroundStyle(Color.teal)
        .padding(.horizontal, 8).frame(height: 20)
        .background(Capsule().fill(Color.teal.opacity(0.13)))
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(texto)
    }
}

struct VazioFeed: View {
    var filtro: Filtro
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.bubble.fill").font(.system(size: 30)).foregroundStyle(Mood.calm)
            Text("Tudo em dia").font(.system(size: 14, weight: .semibold))
            Text(filtro == .tudo ? "Nada pedindo tua atenção agora." : "Nada em \(filtro.nome) agora.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, 40)
    }
}

/// filtro por texto da janela
func bateBusca(_ i: ItemFeed, _ q: String) -> Bool {
    let q = q.trimmingCharacters(in: .whitespaces).lowercased()
    return q.isEmpty || "\(i.nome) \(i.resumo) \(i.demand?.client ?? "")".lowercased().contains(q)
}

/// cabeçalho do popover dos layouts novos
struct TopoPop<Meio: View>: View {
    @ObservedObject var store: Store
    @ViewBuilder var meio: Meio
    var body: some View {
        HStack(spacing: 8) {
            meio
            Spacer(minLength: 4)
            if store.scanning > 0 || store.unreadBusy > 0 { ProgressView().controlSize(.mini) }
            JanelaButton { store.onOpenWindow?() }
            GearMenu(store: store)
        }
    }
}

// MARK: - A · Caixa única

struct PopCaixa: View {
    @ObservedObject var store: Store
    @ObservedObject var zp: ChatStore
    var body: some View {
        let itens = store.feed.filter { store.chip == nil || $0.tipo == store.chip }
        VStack(alignment: .leading, spacing: 10) {
            TopoPop(store: store) { FiltroSeg(store: zp) }
            ChipsFeed(store: store, zp: zp)
            AvisoPonte(store: store)
            if itens.isEmpty {
                VazioFeed(filtro: zp.filtro).frame(height: 160)
            } else {
                FitScroll(maxHeight: 520) {
                    LazyVStack(spacing: 8) {
                        ForEach(itens) { i in CartaoFeed(store: store, i: i) { store.abrirConversa(i.jid) } }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(12)
        .frame(width: 420)
    }
}

// MARK: - B · Conversa no centro

struct PopConversa: View {
    @ObservedObject var store: Store
    @ObservedObject var zp: ChatStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TopoPop(store: store) {
                Text("Conversas").font(.system(size: 18, weight: .bold))
                let n = store.mine.count
                if n > 0 { Pill(text: "\(n) demandas", symbol: "tray.full.fill", tint: Mood.warm) }
                if !store.mentionsOpen.isEmpty { Pill(text: "@\(store.mentionsOpen.count)", tint: .purple) }
            }
            AvisoPonte(store: store)
            ConversasLista(store: zp, compact: true) { store.abrirConversa($0) }
        }
        .padding(12)
        .frame(width: 420, height: 600)
    }
}

// MARK: - C · Hoje (um de cada vez)

struct PopHoje: View {
    @ObservedObject var store: Store
    @ObservedObject var zp: ChatStore
    var body: some View {
        let fila = store.fila
        VStack(alignment: .leading, spacing: 12) {
            TopoPop(store: store) {
                Text("Hoje").font(.system(size: 18, weight: .bold))
                ForEach([ItemFeed.Tipo.responder, .demanda, .marcacao], id: \.self) { t in
                    let n = store.conta(t)
                    if n > 0 { Pill(text: "\(t.chip) \(n)", tint: t.cor) }
                }
            }
            HStack {
                Text(fila.isEmpty ? "fila vazia" : "1 de \(fila.count)").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                FiltroSeg(store: zp).frame(width: 240)
            }
            AvisoPonte(store: store)
            if let i = fila.first {
                CartaoHoje(store: store, i: i).id(i.id)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                HStack(spacing: 8) {
                    BotaoGrande(texto: "Depois", icone: "clock") { withAnimation(.snappy) { _ = store.depois.insert(i.id) } }
                    BotaoGrande(texto: "Abrir", icone: "arrow.up.forward.app") { store.abrirConversa(i.jid) }
                    BotaoGrande(texto: principal(i), icone: i.tipo == .responder ? "arrow.up" : "checkmark", cheio: true) {
                        withAnimation(.snappy) { store.agir(i) }
                    }
                    .disabled(i.tipo == .responder && (i.unread.map { store.draft($0).isEmpty } ?? true))
                }
                if fila.count > 1 {
                    Text("depois: \(fila.dropFirst().prefix(3).map(\.nome).joined(separator: " · "))")
                        .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                }
            } else {
                VazioFeed(filtro: zp.filtro)
            }
            let parados = store.feed.filter { $0.tipo == .aguardando }
            if !parados.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "hourglass").font(.system(size: 10, weight: .semibold)).foregroundStyle(.teal)
                    Text("\(parados.count) aguardando: " + parados.prefix(3).map { "\($0.nome) (\($0.esperaTexto ?? ""))" }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(2)
                }
                .help("Já respondidas por alguém da equipe ou esperando o cliente mandar algo. Ficam na janela, raia Aguardando.")
            }
        }
        .padding(14)
        .frame(width: 420, alignment: .top)
    }
    func principal(_ i: ItemFeed) -> String {
        switch i.tipo { case .responder: return "Enviar resposta"; case .demanda: return "Feito"; case .marcacao: return "Visto"; case .saber: return "ok, li"; case .aguardando: return "ok" }
    }
}

struct BotaoGrande: View {
    let texto: String
    let icone: String
    var cheio = false
    let acao: () -> Void
    var body: some View {
        Button(action: acao) {
            HStack(spacing: 6) {
                Image(systemName: icone).font(.system(size: 12, weight: .bold))
                Text(L(texto)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(cheio ? Color.white : Color.primary)
            .frame(maxWidth: .infinity).frame(height: 38)
            .background(Capsule().fill(cheio ? Color.blue : Color.primary.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// cartão grande do modo Hoje
struct CartaoHoje: View {
    @ObservedObject var store: Store
    let i: ItemFeed
    var citacao: String {
        if let c = i.unread, let l = c.tail.last(where: { !$0.me }) { return l.text }
        if let d = i.demand { return d.quote }
        if let m = i.mention { return m.quote }
        return ""
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ClientAvatar(url: store.avatarURL(i.jid), name: i.nome, isGroup: i.grupo, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(i.nome).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text("\(i.grupo ? "grupo" : "conversa privada") · \(i.ago)").font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                if i.urgente { Pill(text: "urgente", symbol: "bolt.fill", tint: Mood.hot) }
                Pill(text: i.tipo.rotulo, tint: i.tipo.cor)
            }
            Text(i.resumo).font(.system(size: 16, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if !citacao.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(i.tipo.cor.opacity(0.5)).frame(width: 3)
                    Text(citacao).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(4)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if i.tipo == .responder, let c = i.unread {
                ReplyBox(store: store, c: c, atalho: true, linhas: 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.primary.opacity(0.06)))
    }
}

/// ponte/servidor fora: um aviso só, discreto
struct AvisoPonte: View {
    @ObservedObject var store: Store
    var body: some View {
        if !store.serverUp {
            Banner(symbol: "hourglass", text: "Ligando o motorzinho…")
        } else if !store.connected {
            Banner(symbol: "wifi.exclamationmark", text: "Ponte do WhatsApp fora do ar. O que chegar aparece quando ela voltar.")
        }
    }
}

// MARK: - janela dos layouts novos

/// barra de cima da janela (o título nativo fica escondido; os semáforos ficam à esquerda)
struct TopoJanela<Meio: View, Centro: View>: View {
    @ObservedObject var store: Store
    @ObservedObject var m: JanelaModel
    @ViewBuilder var meio: Meio
    /// fica no centro da janela de verdade (não empurrado pelo título nem pela busca)
    @ViewBuilder var centro: Centro
    var body: some View {
        // 3 partes: esquerda e direita com a mesma largura, então o centro fica no meio de verdade e nada se sobrepõe
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Color.clear.frame(width: 70, height: 1)
                meio
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            centro
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                if store.scanning > 0 || store.unreadBusy > 0 { ProgressView().controlSize(.small) }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                    TextField("Buscar", text: $m.busca).textFieldStyle(.plain).font(.system(size: 12.5))
                }
                .padding(.horizontal, 12).frame(minWidth: 110, idealWidth: 200, maxWidth: 200).frame(height: 30)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                MenuJanela(store: store, m: m)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14).padding(.top, 4).frame(height: 40)
        .padding(.bottom, 6)
    }
}
extension TopoJanela where Centro == EmptyView {
    init(store: Store, m: JanelaModel, @ViewBuilder meio: () -> Meio) {
        self.init(store: store, m: m, meio: meio, centro: { EmptyView() })
    }
}

/// insight rápido do dia: quanto já foi entregue do que é meu (anel + números)
struct ResumoDia: View {
    @ObservedObject var store: Store
    @ObservedObject var m: JanelaModel
    var body: some View {
        Button { m.entregues.toggle() } label: { rotulo }
            .buttonStyle(.plain)
            .popover(isPresented: $m.entregues, arrowEdge: .bottom) { ListaEntregues(store: store) }
    }
    @ViewBuilder var rotulo: some View {
        let feitas = store.doneToday.filter { $0.mine }.count
        let abertas = store.mine.count + store.aguardando.count
        let total = feitas + abertas
        let p = total == 0 ? 0 : Double(feitas) / Double(total)
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 3)
                Circle().trim(from: 0, to: p).stroke(Color.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90)).animation(.snappy, value: p)
            }
            .frame(width: 16, height: 16)
            (Text("\(feitas)").fontWeight(.semibold) + Text(" de ").foregroundStyle(.secondary)
             + Text("\(total)").fontWeight(.semibold) + Text(" entregues").foregroundStyle(.secondary))
                .font(.system(size: 12)).monospacedDigit()
        }
        .padding(.horizontal, 11).frame(height: 30)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .contentShape(Capsule())
        .help("Ver o que foi entregue hoje (\(feitas) de \(total))")
        .fixedSize()
    }
}

/// o que eu entreguei hoje: mais recente primeiro, com desfazer
struct ListaEntregues: View {
    @ObservedObject var store: Store
    var body: some View {
        let feitas = store.doneToday.filter { $0.mine }.sorted { ($0.doneAt ?? 0) > ($1.doneAt ?? 0) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Entregues hoje").font(.system(size: 15, weight: .bold))
                Text("\(feitas.count)").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            if feitas.isEmpty {
                Text("Nada entregue ainda hoje").font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(feitas) { d in
                            HStack(spacing: 10) {
                                ClientAvatar(url: store.avatarURL(d.jid), name: d.client, isGroup: d.isGroup, size: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(d.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                    Text(d.client + (d.doneAt.map { " · " + Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .omitted, time: .shortened) } ?? ""))
                                        .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                Button("Desfazer") { store.reopen(d) }
                                    .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 9).frame(height: 24)
                                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                                    .help("Voltar pra Fazer")
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 10)
                }
                .frame(maxHeight: 420)
            }
        }
        .frame(width: 380)
    }
}

/// layout + aparência + atualizar, num botão só
struct MenuJanela: View {
    @ObservedObject var store: Store
    @ObservedObject var m: JanelaModel
    @AppStorage("sound") var som = WakeSound.padrao
    var body: some View {
        Menu {
            Picker("Aparência", selection: $m.tema) {
                Text("Automático").tag("auto"); Text("Claro").tag("claro"); Text("Escuro").tag("escuro")
            }
            Divider()
            Toggle("Som de demanda nova", isOn: Binding(get: { som != "off" },
                set: { on in som = on ? WakeSound.padrao : "off"; if on { WakeSound.play(WakeSound.padrao) } }))
            Toggle("Abrir quando ligar o Mac", isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { on in if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() } }))
            Divider()
            Button("Atualizar") { Task { await store.refresh(); await store.zp.refresh() } }
        } label: {
            Image(systemName: "slider.horizontal.3").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 30, height: 30).background(Circle().fill(Color.primary.opacity(0.07)))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Ajustes")
    }
}

/// conversa (privada ou grupo) pelo chat de verdade
struct ChatDoItem: View {
    @ObservedObject var store: Store
    @ObservedObject var zp: ChatStore
    let jid: String
    var nome: String? = nil
    var compacto = false
    var fechar: (() -> Void)? = nil
    var body: some View {
        let chat = zp.chats.first { $0.jid == jid }
            ?? Chat(jid: jid, name: nome ?? store.unread.first { $0.jid == jid }?.name ?? jid, last: "", lastTs: 0, unread: 0,
                    group: jid.hasSuffix("@g.us"), work: nil)
        ChatView(store: zp, chat: chat, compact: compacto, onBack: fechar, onWindow: nil)
            .task(id: jid) { if zp.selected != jid { await zp.select(jid) } }
    }
}

/// detalhe de um item da caixa única
struct DetalheItem: View {
    @ObservedObject var store: Store
    let i: ItemFeed
    var fechar: (() -> Void)? = nil
    var body: some View {
        switch i.tipo {
        case .demanda:
            if let d = i.demand { DetalheJanela(store: store, d: d, feito: { store.done(d) }) } else { EmptyView() }
        case .marcacao:
            if let m = i.mention { DetalheMarcacao(store: store, m: m) } else { EmptyView() }
        default:
            ChatDoItem(store: store, zp: store.zp, jid: i.jid, nome: i.nome, fechar: fechar)
        }
    }
}

struct EscolhaAlgo: View {
    var texto = "Escolhe um item"
    var body: some View {
        VStack(spacing: 10) {
            DaemonLogo(size: 40).opacity(0.45)
            Text(L(texto)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct JanelaCaixa: View {
    @ObservedObject var store: Store
    @ObservedObject var zp: ChatStore
    @ObservedObject var m: JanelaModel
    var body: some View {
        let itens = store.feed.filter { (store.chip == nil || $0.tipo == store.chip) && bateBusca($0, m.busca) }
        let sel = itens.first { $0.id == m.sel }
        VStack(spacing: 0) {
            TopoJanela(store: store, m: m) {
                FiltroSeg(store: zp).frame(width: 270)
                ChipsFeed(store: store, zp: zp)
            }
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        AvisoPonte(store: store)
                        if itens.isEmpty { VazioFeed(filtro: zp.filtro) }
                        ForEach(itens) { i in
                            CartaoFeed(store: store, i: i, selecionado: m.sel == i.id, curto: true) { m.sel = i.id }
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 14)
                }
                .scrollIndicators(.never)
                .frame(width: 380)
                Divider().opacity(0.6)
                Group {
                    if let i = sel { DetalheItem(store: store, i: i).id(i.id) }
                    else if let s = m.sel, s.hasPrefix("c:") { ChatDoItem(store: store, zp: zp, jid: String(s.dropFirst(2))).id(s) }
                    else { EscolhaAlgo() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { if sel == nil { m.sel = itens.first?.id } }
        .onChange(of: itens.map(\.id)) { _, ids in m.sel = manterConversa(m.sel, ids: ids, store: store, senao: ids.first) }
    }
}

struct JanelaConversa: View {
    @ObservedObject var store: Store
    @ObservedObject var zp: ChatStore
    @ObservedObject var m: JanelaModel
    var body: some View {
        VStack(spacing: 0) {
            TopoJanela(store: store, m: m) { FiltroSeg(store: zp).frame(width: 270) }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    AvisoPonte(store: store).padding(.horizontal, 10)
                    ConversasLista(store: zp, selecionado: m.sel, buscaExterna: m.busca, mostraFiltro: false) { m.sel = $0 }
                }
                .frame(width: 300)
                Divider().opacity(0.6)
                Group {
                    if let j = m.sel, !j.contains(":") { ChatDoItem(store: store, zp: zp, jid: j) } else { EscolhaAlgo(texto: "Escolhe uma conversa") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().opacity(0.6)
                if let j = m.sel, !j.contains(":") {
                    PainelConversa(store: store, zp: zp, jid: j).frame(width: 260)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { if m.sel == nil || m.sel!.contains(":") { m.sel = zp.chats.first { zp.passa($0.jid, grupo: $0.isGroup) }?.jid } }
    }
}

/// painel da direita do layout B: tudo daquela conversa
struct PainelConversa: View {
    @ObservedObject var store: Store
    @ObservedObject var zp: ChatStore
    let jid: String
    var body: some View {
        let dem = store.mine.filter { $0.jid == jid }
        let mar = store.mentionsOpen.filter { $0.jid == jid }
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Titulo(texto: "Resumo", icone: "sparkles")
                if let u = store.unread.first(where: { $0.jid == jid }), !u.summary.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(u.summary).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                        Acao(texto: "ok, li", icone: "checkmark", cor: Mood.calm) { store.unreadOK(u) }
                    }
                    .padding(11).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
                } else {
                    Text("Nada novo aqui.").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.horizontal, 4)
                }
                Titulo(texto: "Demandas · \(dem.count)", icone: "tray.full")
                if dem.isEmpty { Text("Nenhuma aberta.").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.horizontal, 4) }
                ForEach(dem) { d in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(d.title).font(.system(size: 12.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        Text("\(d.client) · \(d.who)").font(.system(size: 11)).foregroundStyle(.tertiary)
                        HStack(spacing: 6) {
                            Acao(texto: "Feito", icone: "checkmark", cor: Mood.calm) { store.done(d) }
                            Acao(texto: "Claude", icone: "sparkle", cor: Mood.claude) { store.onClaude?(d) }
                        }
                    }
                    .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
                }
                Titulo(texto: "Marcações · \(mar.count)", icone: "at")
                if mar.isEmpty { Text("Ninguém te marcou aqui.").font(.system(size: 12)).foregroundStyle(.tertiary).padding(.horizontal, 4) }
                ForEach(mar) { x in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(x.summary).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                        Text("\(x.who) · \(x.ago)").font(.system(size: 11)).foregroundStyle(.tertiary)
                        Acao(texto: "Visto", icone: "checkmark", cor: Mood.calm) { store.mentionOK(x) }
                    }
                    .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
                }
            }
            .padding(12)
        }
        .scrollIndicators(.never)
    }
    struct Titulo: View {
        let texto: String
        let icone: String
        var body: some View {
            Label(texto, systemImage: icone).font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
                .textCase(.uppercase).padding(.top, 6).padding(.horizontal, 4)
        }
    }
}

struct JanelaHoje: View {
    @ObservedObject var store: Store
    @ObservedObject var zp: ChatStore
    @ObservedObject var m: JanelaModel

    struct RaiaInfo: Identifiable { let titulo: String; let cor: Color; let itens: [ItemFeed]; var mostraFazendo = true; var id: String { titulo } }

    // medidas (pt): raia confortável entre 300 e 460, detalhe entre 380 e 460
    static let raiaMin: CGFloat = 300, raiaMax: CGFloat = 460, gap: CGFloat = 12

    var body: some View {
        let todos = store.feed.filter { bateBusca($0, m.busca) }
        let sel = todos.first { $0.id == m.sel }
        // conversa que segue aberta depois de eu responder (o item saiu das não lidas)
        let chatJid: String? = m.sel.flatMap { $0.hasPrefix("c:") ? String($0.dropFirst(2)) : nil }
        let detalhe = sel != nil || chatJid != nil
        var raias = [
            RaiaInfo(titulo: "Responder", cor: .blue, itens: todos.filter { $0.tipo == .responder || $0.tipo == .marcacao }),
            RaiaInfo(titulo: "Fazer", cor: Mood.warm, itens: todos.filter { $0.tipo == .demanda && $0.demand?.doing == nil }),
        ]
        let fazendo = todos.filter { $0.tipo == .demanda && $0.demand?.doing != nil }
        if !fazendo.isEmpty { raias.append(RaiaInfo(titulo: "Fazendo", cor: .indigo, itens: fazendo, mostraFazendo: false)) }
        let parados = todos.filter { $0.tipo == .aguardando }
        if !parados.isEmpty { raias.append(RaiaInfo(titulo: "Aguardando", cor: .teal, itens: parados)) }
        raias.append(RaiaInfo(titulo: "Só saber", cor: .secondary, itens: todos.filter { $0.tipo == .saber }))

        return GeometryReader { geo in
            let W = geo.size.width
            let largura = W - 28
            let detW: CGFloat = detalhe ? min(460, max(380, largura * 0.42)) : 0
            let livre = largura - (detalhe ? detW + Self.gap : 0)
            // quantas raias cabem sem espremer
            let cabem = max(0, Int((livre + Self.gap) / (Self.raiaMin + Self.gap)))
            let soDetalhe = detalhe && cabem == 0
            let mostrar = max(1, min(raias.count, cabem))
            let abas = !soDetalhe && mostrar < raias.count
            let inicio = min(m.raiaInicio, raias.count - mostrar)
            let visiveis = soDetalhe ? [] : Array(raias[inicio..<(inicio + mostrar)])
            // raias ocupam toda a largura (sem faixa vazia nas telas grandes)
            let raiaW = visiveis.isEmpty ? 0 : (livre - Self.gap * CGFloat(visiveis.count - 1)) / CGFloat(visiveis.count)
            let total = visiveis.isEmpty ? detW : raiaW * CGFloat(visiveis.count) + Self.gap * CGFloat(visiveis.count - 1) + (detalhe ? detW + Self.gap : 0)

            VStack(spacing: 0) {
                TopoJanela(store: store, m: m) {
                    Text("Hoje").font(.system(size: 17, weight: .bold))
                        .help(Date().formatted(Date.FormatStyle(locale: Locale(identifier: Idioma.ingles ? "en_US" : "pt_BR")).weekday(.wide).day().month(.wide)))
                    if W >= 1060 { ResumoDia(store: store, m: m) }
                } centro: {
                    FiltroSeg(store: zp).frame(width: W < 980 ? 250 : 270)
                }
                AvisoPonte(store: store).padding(.horizontal, 14)
                if abas {
                    // janela estreita: abinhas das raias, as visíveis ficam acesas
                    HStack(spacing: 6) {
                        ForEach(Array(raias.enumerated()), id: \.element.id) { k, r in
                            let acesa = k >= inicio && k < inicio + mostrar
                            Button { withAnimation(.snappy(duration: 0.25)) { m.raiaInicio = min(k, raias.count - mostrar) } } label: {
                                HStack(spacing: 5) {
                                    Text(L(r.titulo)).font(.system(size: 12, weight: .semibold))
                                    Text("\(r.itens.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 11).frame(height: 26)
                                .foregroundStyle(acesa ? r.cor : .secondary)
                                .background(Capsule().fill(acesa ? r.cor.opacity(0.14) : Color.primary.opacity(0.05)))
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).padding(.bottom, 8)
                }
                HStack(alignment: .top, spacing: Self.gap) {
                    ForEach(visiveis) { r in
                        Raia(store: store, m: m, titulo: r.titulo, cor: r.cor, itens: r.itens, mostraFazendo: r.mostraFazendo)
                            .frame(width: raiaW)
                            .transition(.opacity)
                    }
                    if let jid = chatJid {
                        painel(largura: soDetalhe ? largura : detW) {
                            Pill(text: "Conversa", tint: .blue)
                        } fechar: { m.sel = nil; store.segurar.remove(jid) } conteudo: {
                            ChatDoItem(store: store, zp: zp, jid: jid).id("c:" + jid)
                        }
                    }
                    if let i = sel {
                        painel(largura: soDetalhe ? largura : detW) {
                            Pill(text: i.tipo.rotulo, tint: i.tipo.cor)
                        } fechar: { m.sel = nil } conteudo: {
                            DetalheItem(store: store, i: i).id(i.id)
                        }
                    }
                }
                .frame(width: min(total, largura))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 14).padding(.bottom, 14)
                .animation(.snappy(duration: 0.28), value: m.sel)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: todos.map(\.id)) { _, ids in m.sel = manterConversa(m.sel, ids: ids, store: store, senao: nil) }
    }

    /// painel de detalhe (item ou conversa) à direita
    func painel<Cab: View, Con: View>(largura: CGFloat, @ViewBuilder cabecalho: () -> Cab, fechar: @escaping () -> Void,
                                      @ViewBuilder conteudo: () -> Con) -> some View {
        VStack(spacing: 0) {
            HStack {
                cabecalho()
                Spacer()
                Button { withAnimation(.snappy) { fechar() } } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 28).background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain).keyboardShortcut(.escape, modifiers: []).help("Fechar (esc)")
            }
            .padding(.leading, 28).padding(.trailing, 14).padding(.top, 14)
            conteudo().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: largura)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}

/// o item selecionado sumiu da lista: se foi porque eu acabei de responder, troca pela conversa (fica aberta);
/// senão segue o comportamento antigo (`senao`)
@MainActor func manterConversa(_ sel: String?, ids: [String], store: Store, senao: String?) -> String? {
    guard let s = sel, !ids.contains(s), !s.hasPrefix("c:") else { return sel }
    if s.hasPrefix("u:") {
        let jid = String(s.dropFirst(2))
        if store.segurar.contains(jid) { return "c:" + jid }
    }
    return senao
}

struct Raia: View {
    @ObservedObject var store: Store
    @ObservedObject var m: JanelaModel
    let titulo: String
    let cor: Color
    let itens: [ItemFeed]
    var mostraFazendo = true
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Pill(text: titulo, tint: cor)
                Text("\(itens.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4).padding(.top, 2)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if itens.isEmpty {
                        Text("nada aqui").font(.system(size: 12)).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.vertical, 24)
                    }
                    ForEach(itens) { i in
                        CartaoFeed(store: store, i: i, compacto: true, selecionado: m.sel == i.id, mostraFazendo: mostraFazendo) { withAnimation(.snappy) { m.sel = i.id } }
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}
