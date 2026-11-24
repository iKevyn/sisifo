import AppKit
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - pedacinhos reaproveitados

/// estado local das views (evita @State: o plugin de macro do SwiftUI não carrega
/// quando se compila com Command Line Tools, e @StateObject funciona igual)
final class Local: ObservableObject {
    @Published var busca = ""
    @Published var texto = ""
    @Published var emChat = false
    @Published var showStickers = false
    @Published var hover = false
    @Published var dropping = false
    @Published var dropRow: String?
}

/// tocador de áudio compacto (baixa o m4a do servidor local e toca)
final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playing = false
    private var player: AVAudioPlayer?
    private var tmp: URL?

    func toggle(_ url: URL) async {
        if playing { stop(); return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let f = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            try data.write(to: f)
            let p = try AVAudioPlayer(contentsOf: f)
            p.delegate = self
            p.prepareToPlay()
            tmp = f
            player = p
            playing = p.play()
        } catch { stop() }
    }

    func stop() {
        player?.stop()
        player = nil
        playing = false
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        tmp = nil
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) { stop() }
}

/// gravador de áudio (m4a); o servidor converte pra mensagem de voz
@MainActor
final class Gravador: NSObject, ObservableObject {
    @Published var gravando = false
    @Published var segundos = 0
    private var rec: AVAudioRecorder?
    private var timer: Timer?
    private(set) var arquivo: URL?

    func comecar() async -> Bool {
        let ok = await AVCaptureDevice.requestAccess(for: .audio)
        guard ok else { return false }
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("audio-\(UUID().uuidString.prefix(6)).m4a")
        let cfg: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
                                  AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
        guard let r = try? AVAudioRecorder(url: f, settings: cfg), r.record() else { return false }
        rec = r; arquivo = f; segundos = 0; gravando = true
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.segundos += 1 }
        }
        return true
    }

    /// para e devolve o arquivo (nil = cancelado)
    func parar(enviar: Bool) -> URL? {
        timer?.invalidate(); timer = nil
        rec?.stop(); rec = nil
        gravando = false
        guard let f = arquivo else { return nil }
        arquivo = nil
        if enviar, segundos >= 1 { return f }
        try? FileManager.default.removeItem(at: f)
        return nil
    }
}

private func iniciais(_ name: String) -> String {
    let l = name.split(separator: " ").filter { $0.first?.isLetter == true || $0.first?.isNumber == true }.prefix(2).compactMap { $0.first }
    return l.isEmpty ? "?" : String(l).uppercased()
}

private let fHora: DateFormatter = { let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f }()
private let fDia: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd/MM"; return f }()
private let fSemana: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "EEEE"; return f }()
private let fLongo: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "d 'de' MMM"; return f }()

private func hora(_ ts: Int) -> String { fHora.string(from: Date(timeIntervalSince1970: Double(ts))) }

/// lista: hoje = hora, ontem, dia da semana, depois dd/MM (igual Mensagens)
private func quando(_ ts: Int) -> String {
    let d = Date(timeIntervalSince1970: Double(ts))
    let cal = Calendar.current
    if cal.isDateInToday(d) { return fHora.string(from: d) }
    if cal.isDateInYesterday(d) { return "Ontem" }
    if let dias = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day, dias < 7 {
        return fSemana.string(from: d).capitalized
    }
    return fDia.string(from: d)
}

/// separador de dia dentro da conversa
private func diaTitulo(_ ts: Int) -> String {
    let d = Date(timeIntervalSince1970: Double(ts))
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Hoje" }
    if cal.isDateInYesterday(d) { return "Ontem" }
    return fLongo.string(from: d)
}

private func atraso(_ date: Date) -> String {
    let s = max(0, Int(Date().timeIntervalSince(date)))
    if s < 10 { return "agora" }
    if s < 60 { return "há \(s)s" }
    if s < 3600 { return "há \(s / 60) min" }
    if s < 86400 { return "há \(s / 3600) h" }
    return "há \(s / 86400) d"
}

/// contato sem nome salvo: "5511999998888@s.whatsapp.net" vira "+55 11 99999-8888"
func nomeBonito(_ name: String) -> String {
    guard name.contains("@") || name.allSatisfy({ $0.isNumber || $0 == "+" }) else { return name }
    let d = String(name.split(separator: "@").first ?? "").filter(\.isNumber)
    guard d.count >= 12, d.hasPrefix("55") else { return d.isEmpty ? name : "+" + d }
    let ddd = d.dropFirst(2).prefix(2), num = d.dropFirst(4)
    let corte = num.count - 4
    return "+55 \(ddd) \(num.prefix(corte))-\(num.suffix(4))"
}

/// cinza das bolhas recebidas e dos campos (funciona no claro e no escuro, em cima do vidro)
private let cinza = Color.primary.opacity(0.075)

/// botão redondo de vidro (Liquid Glass) para a barra de cima
struct BotaoVidro: View {
    let icone: String
    var ativo = false
    var girando = false
    var tamanho: CGFloat = 28
    let ajuda: String
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            Image(systemName: icone)
                .font(.system(size: tamanho * 0.43, weight: .semibold))
                .symbolEffect(.rotate, isActive: girando)
                .foregroundStyle(ativo ? Color.white : Color.primary.opacity(0.8))
                .frame(width: tamanho, height: tamanho)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(ativo ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .circle)
        .help(ajuda)
    }
}

struct ChatAvatar: View {
    let store: ChatStore
    let jid: String
    let name: String
    var size: CGFloat = 38

    var body: some View {
        AsyncImage(url: store.avatarURL(jid)) { phase in
            switch phase {
            case .success(let img):
                img.resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            default:
                ZStack {
                    // cinza estilo Contatos (sem degradê)
                    Circle().fill(Color(nsColor: .systemGray).opacity(0.55))
                    Text(iniciais(name))
                        .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
            }
        }
    }
}

/// rodapé: status + botão claro de sincronizar + som
struct StatusFooter: View {
    @ObservedObject var store: ChatStore

    private var ok: Bool { store.serverUp && store.connected }
    private var titulo: String {
        if store.syncing { return "Sincronizando…" }
        if !store.serverUp { return "Ligando o motorzinho…" }
        if !store.connected { return "WhatsApp desconectado" }
        if store.lastSync != nil { return "Sincronizado" }
        return "Sincronizando conversas…"
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ok ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(titulo)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if ok, store.lastDbTs > 0 {
                    Text("\(store.lastSync.map { atraso($0) } ?? "") · msg \(quando(store.lastDbTs).lowercased())")
                        .lineLimit(1)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            Button { store.soundOn.toggle() } label: {
                Image(systemName: store.soundOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(store.soundOn ? "Silenciar sons" : "Ativar sons")
            Button { Task { await store.syncNow() } } label: {
                Label {
                    Text(store.syncing ? "Sincronizando" : "Sincronizar")
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .symbolEffect(.rotate, isActive: store.syncing)
                }
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 5)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .disabled(store.syncing)
            .help("Forçar sincronização agora (⌘R)")
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
}

/// campo de busca em cápsula (estilo macOS 26/27)
struct CampoBusca: View {
    @Binding var texto: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            TextField("Buscar", text: $texto)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !texto.isEmpty {
                Button { texto = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule().fill(cinza))
    }
}



/// até 4 contatos fixados, estilo Mensagens: avatar grande + nome curto, bolinha azul se não lida
struct Fixados: View {
    @ObservedObject var store: ChatStore
    let abrir: (String) -> Void

    var body: some View {
        let chats = store.pinned.compactMap { j in store.chats.first { $0.jid == j } }
        HStack(alignment: .top, spacing: 0) {
            ForEach(chats) { c in
                Button { abrir(c.jid) } label: {
                    VStack(spacing: 5) {
                        ChatAvatar(store: store, jid: c.jid, name: c.name, size: 50)
                            .overlay(alignment: .topTrailing) {
                                if c.unread > 0 {
                                    Circle().fill(Color.accentColor).frame(width: 12, height: 12)
                                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                                }
                            }
                        Text(nomeBonito(c.name).split(separator: " ").first.map(String.init) ?? c.name)
                            .font(.system(size: 11, weight: c.unread > 0 ? .semibold : .regular))
                            .foregroundStyle(c.unread > 0 ? Color.primary : Color.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { Button("Desafixar") { store.togglePin(c.jid) } }
            }
        }
        .padding(.vertical, 8)
    }
}

struct VazioLista: View {
    let soNaoLidas: Bool
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: soNaoLidas ? "checkmark.bubble" : "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text(soNaoLidas ? "Tudo lido" : "Nenhuma conversa privada")
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }
}

/// linha da lista no estilo Mensagens: bolinha azul de não lida, nome + hora, prévia em 2 linhas
struct ChatRow: View {
    @ObservedObject var store: ChatStore
    let chat: Chat
    var selected = false
    var onTap: (() -> Void)? = nil
    var onFiles: (([URL]) -> Void)? = nil
    @StateObject private var ui = Local()

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(chat.unread > 0 ? Color.accentColor : Color.clear)
                .frame(width: 8, height: 8)
            ChatAvatar(store: store, jid: chat.jid, name: chat.name, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(nomeBonito(chat.name))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(quando(chat.lastTs))
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                    if chat.unread > 1 {
                        Text("\(chat.unread)")
                            .font(.system(size: 10, weight: .bold)).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).frame(minWidth: 17, minHeight: 17)
                            .background(Capsule().fill(Color.accentColor))
                    }
                }
                HStack(alignment: .top, spacing: 5) {
                    Text(chat.last.isEmpty ? "Sem mensagens" : chat.last)
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !selected, let sl = store.selos[chat.jid] { SelosView(s: sl) }
                }
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.leading, 2).padding(.trailing, 10).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Color.accentColor : (ui.dropping ? Color.accentColor.opacity(0.15) : ui.hover ? cinza : Color.clear))
        )
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { ui.dropping }, set: { ui.dropping = $0 && onFiles != nil })) { ps in
            guard let onFiles else { return false }
            lerArquivos(ps) { onFiles($0) }
            return true
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { h in if onTap != nil { ui.hover = h } }
        .onTapGesture { onTap?() }
    }
}



// MARK: - conversa (popover e janela usam a mesma)

struct ChatView: View {
    @ObservedObject var store: ChatStore
    let chat: Chat
    var compact = false
    var onBack: (() -> Void)? = nil
    var onWindow: (() -> Void)? = nil
    @StateObject private var ui = Local()

    /// "Responder" de demanda/marcação: rola até a mensagem do pedido (se ela já está carregada)
    func irParaPedido(_ proxy: ScrollViewProxy) -> Bool {
        guard let id = store.irPara, store.selected == chat.jid, store.messages.contains(where: { $0.id == id }) else { return false }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
        DispatchQueue.main.async { store.irPara = nil }
        return true
    }

    private var subtitulo: String {
        if chat.isGroup { return store.trabalho.contains(chat.jid) ? "grupo de trabalho" : "grupo" }
        if store.presence.recording { return "gravando áudio…" }
        if store.presence.typing { return "digitando…" }
        return store.connected ? "WhatsApp" : "desconectado"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let ms = store.messages
                        ForEach(Array(ms.enumerated()), id: \.element.id) { i, m in
                            let prev = i > 0 ? ms[i - 1] : nil
                            let next = i + 1 < ms.count ? ms[i + 1] : nil
                            let novoDia = prev.map { !Calendar.current.isDate(Date(timeIntervalSince1970: Double($0.ts)), inSameDayAs: Date(timeIntervalSince1970: Double(m.ts))) } ?? true
                            let juntaCima = !novoDia && prev?.me == m.me && prev?.who == m.who && m.ts - (prev?.ts ?? 0) < 180
                            let juntaBaixo = next?.me == m.me && (next?.ts ?? 0) - m.ts < 180
                                && Calendar.current.isDate(Date(timeIntervalSince1970: Double(next?.ts ?? 0)), inSameDayAs: Date(timeIntervalSince1970: Double(m.ts)))
                            if novoDia {
                                Text(diaTitulo(m.ts))
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, i == 0 ? 4 : 14).padding(.bottom, 8)
                            }
                            MessageBubble(store: store, msg: m, compact: compact, cauda: !juntaBaixo, mostraHora: !juntaBaixo,
                                          mostraNome: m.who != nil && (!juntaCima || prev?.who != m.who))
                                .padding(.top, juntaCima ? 2 : 6)
                                .id(m.id)
                        }
                        PresenceBubble(store: store).id("presenca")
                    }
                    .padding(.horizontal, compact ? 12 : 20)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(.bottom)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .safeAreaBar(edge: .top) {
                    VStack(spacing: 6) {
                        cabecalho
                        resumoIA
                    }
                }
                .onChange(of: store.messages.count) { _, _ in
                    if !irParaPedido(proxy) {
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(store.messages.last?.id, anchor: .bottom) }
                    }
                }
                .onChange(of: store.selected) { _, _ in
                    if !irParaPedido(proxy) { proxy.scrollTo(store.messages.last?.id, anchor: .bottom) }
                }
                .onChange(of: store.irPara) { _, _ in _ = irParaPedido(proxy) }
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { _ = irParaPedido(proxy) } }
            }

            Composer(store: store, jid: chat.jid, compact: compact)
        }
        .overlay { if ui.dropping { SoltarAqui(compact: compact) } }
        .onDrop(of: [.fileURL, .image], isTargeted: Binding(get: { ui.dropping }, set: { ui.dropping = $0 })) { providers in
            receber(providers)
            return true
        }
        .onAppear { store.chatAberto = chat.jid }
        .onDisappear { if store.chatAberto == chat.jid { store.chatAberto = nil } }
        .onChange(of: chat.jid) { _, j in store.chatAberto = j; store.limparAnexos() }
    }

    /// o que a IA entendeu da conversa (só quando tem não lida resumida)
    @ViewBuilder private var resumoIA: some View {
        if let ia = store.ia[chat.jid], !ia.resumo.isEmpty {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ia.precisaResposta ? Color.accentColor : Color.secondary)
                Text(ia.resumo)
                    .font(.system(size: compact ? 11.5 : 12, weight: .medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { store.onIAOk?(chat.jid) } label: {
                    Text("ok, li")
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help("Tira das não lidas (no celular continua como não lida)")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .padding(.horizontal, compact ? 10 : 16)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// barra flutuante de vidro em cima da conversa
    private var cabecalho: some View {
        HStack(spacing: 10) {
            if let onBack {
                BotaoVidro(icone: "chevron.left", ajuda: "Voltar às conversas", acao: onBack)
            }
            HStack(spacing: 8) {
                ChatAvatar(store: store, jid: chat.jid, name: chat.name, size: compact ? 28 : 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text(nomeBonito(chat.name)).font(.system(size: compact ? 12.5 : 13.5, weight: .semibold)).lineLimit(1)
                    Text(subtitulo)
                        .font(.system(size: 10.5))
                        .foregroundStyle(store.presence.typing || store.presence.recording ? Color.accentColor : Color.secondary)
                }
            }
            .padding(.leading, 5).padding(.trailing, 14).padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
            Spacer(minLength: 4)
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    BotaoVidro(icone: "arrow.triangle.2.circlepath", girando: store.syncing,
                               ajuda: "Sincronizar esta conversa (⌘R)") { Task { await store.syncNow() } }
                    if let onWindow {
                        BotaoVidro(icone: "macwindow", ajuda: "Abrir na janela (⌥⇧Z)", acao: onWindow)
                    }
                }
            }
        }
        .padding(.horizontal, compact ? 10 : 16).padding(.top, compact ? 10 : 2).padding(.bottom, 6)
    }

    private func receber(_ providers: [NSItemProvider]) {
        for p in providers.prefix(10) {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                lerArquivos([p]) { store.anexar($0) }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                // imagem arrastada do navegador (sem arquivo): vira png temporário
                _ = p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let img = NSImage(data: data), let tiff = img.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                    let f = FileManager.default.temporaryDirectory.appendingPathComponent("imagem-\(UUID().uuidString.prefix(6)).png")
                    try? png.write(to: f)
                    Task { @MainActor in
                        store.anexar([f], nomes: ["Imagem"])
                        try? FileManager.default.removeItem(at: f)
                    }
                }
            }
        }
    }
}

/// lê as URLs de arquivo soltas (cada provider responde em outra thread)
func lerArquivos(_ ps: [NSItemProvider], _ fim: @escaping @MainActor ([URL]) -> Void) {
    for p in ps where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        _ = p.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in fim([url]) }
        }
    }
}

/// aviso que aparece enquanto arrasta um arquivo por cima da conversa
struct SoltarAqui: View {
    let compact: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.accentColor.opacity(0.08)))
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc.fill").font(.system(size: compact ? 26 : 34))
                Text("Solte pra anexar").font(.system(size: compact ? 13 : 15, weight: .semibold))
                Text("foto, áudio, vídeo ou arquivo").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 22).padding(.vertical, 16)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
        .padding(8)
        .allowsHitTesting(false)
    }
}

struct MessageBubble: View {
    @ObservedObject var store: ChatStore
    let msg: Msg
    var compact = false
    var cauda = true
    var mostraHora = true
    /// grupo: nome de quem mandou em cima do primeiro balão da sequência
    var mostraNome = false
    @StateObject private var player = Player()

    private var shown: String { msg.media ? msg.caption : msg.text }
    private var isSticker: Bool { msg.type == "stickerMessage" }
    private var isAudio: Bool { msg.type == "audioMessage" }
    private var bubbleText: String {
        if isSticker || isAudio { return "" }
        return shown
    }
    private var incoming: Bool { !msg.me }
    private var forma: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 18,
            bottomLeadingRadius: incoming && cauda ? 6 : 18,
            bottomTrailingRadius: !incoming && cauda ? 6 : 18,
            topTrailingRadius: 18, style: .continuous)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if msg.me { Spacer(minLength: compact ? 40 : 90) }
            VStack(alignment: incoming ? .leading : .trailing, spacing: 3) {
                if mostraNome, let w = msg.who, !w.isEmpty {
                    Text(w)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(corNome(w))
                        .padding(.horizontal, 6)
                }
                if isSticker {
                    AsyncImage(url: store.thumbURL(msg.jid, msg.id)) { phase in
                        if case .success(let img) = phase {
                            img.resizable().scaledToFit()
                        } else {
                            RoundedRectangle(cornerRadius: 14).fill(cinza)
                        }
                    }
                    .frame(width: compact ? 104 : 140, height: compact ? 104 : 140)
                } else if isAudio {
                    AudioBubble(store: store, player: player, msg: msg, compact: compact)
                } else if msg.media {
                    Group {
                        if msg.type == "videoMessage" {
                            ZStack {
                                Rectangle().fill(cinza)
                                Image(systemName: "play.circle.fill").font(.system(size: 30)).foregroundStyle(.secondary)
                            }
                        } else if msg.type == "documentMessage" {
                            ZStack {
                                Rectangle().fill(cinza)
                                Image(systemName: "doc.fill").font(.system(size: 26)).foregroundStyle(.secondary)
                            }
                        } else {
                            AsyncImage(url: store.thumbURL(msg.jid, msg.id)) { phase in
                                if case .success(let img) = phase {
                                    img.resizable().scaledToFill()
                                } else {
                                    Rectangle().fill(cinza)
                                }
                            }
                        }
                    }
                    .frame(width: compact ? 170 : 240, height: compact ? 124 : 170)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                if !bubbleText.isEmpty {
                    Text(bubbleText)
                        .font(.system(size: compact ? 13 : 13.5))
                        .foregroundStyle(incoming ? Color.primary : Color.white)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(forma.fill(incoming ? cinza : Color.accentColor))
                        .textSelection(.enabled)
                }

                if mostraHora {
                    Text(hora(msg.ts))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(store.replyTo?.id == msg.id ? Color.accentColor : Color.clear, lineWidth: 1.5)
                    .padding(-3)
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { store.setReply(msg) }
            .contextMenu {
                Button("Responder") { store.setReply(msg) }
                if !shown.isEmpty {
                    Button("Copiar") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(shown, forType: .string)
                    }
                }
            }
            .help("Dois cliques: responder citando")
            if incoming { Spacer(minLength: compact ? 40 : 90) }
        }
    }
}

/// cor estável por pessoa (sem degradê), como no WhatsApp
func corNome(_ s: String) -> Color {
    let cores: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]
    return cores[abs(s.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % cores.count]
}

/// "digitando…" como um balãozinho cinza com três pontinhos (igual Mensagens)
struct PresenceBubble: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        Group {
            if store.presence.typing || store.presence.recording {
                HStack(spacing: 5) {
                    Image(systemName: store.presence.recording ? "waveform" : "ellipsis")
                        .font(.system(size: 14, weight: .bold))
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                }
                .foregroundStyle(.secondary)
                .frame(width: 46, height: 30)
                .background(Capsule().fill(cinza))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: store.presence)
    }
}

struct AudioBubble: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var player: Player
    let msg: Msg
    var compact = false

    private var incoming: Bool { !msg.me }
    private var key: String { msg.jid + "|" + msg.id }
    private var transcribing: Bool { store.transcribing == key }
    private var text: String { msg.transcript ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button { Task { await player.toggle(store.audioURL(msg.jid, msg.id)) } } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(incoming ? Color.primary.opacity(0.1) : Color.white.opacity(0.22)))
                }
                .buttonStyle(.plain)

                // ondinha fixa (desenho leve, sem análise do áudio)
                HStack(spacing: 2) {
                    ForEach(0..<18, id: \.self) { i in
                        Capsule()
                            .frame(width: 2.5, height: [6, 10, 14, 9, 16, 12, 7, 13, 18, 11, 8, 14, 10, 6, 12, 9, 7, 5][i])
                    }
                }
                .opacity(player.playing ? 1 : 0.55)
                .symbolEffect(.pulse, isActive: player.playing)

                Spacer(minLength: 2)
                if text.isEmpty {
                    Button { Task { await store.transcribe(msg.jid, msg.id) } } label: {
                        if transcribing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "text.quote").font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(transcribing)
                    .help("Transcrever áudio")
                }
            }
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: compact ? 11.5 : 12))
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .opacity(0.9)
            }
        }
        .foregroundStyle(incoming ? Color.primary : Color.white)
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(incoming ? cinza : Color.accentColor))
        .frame(width: compact ? 220 : 270)
    }
}

struct Composer: View {
    @ObservedObject var store: ChatStore
    let jid: String
    var compact = false
    @StateObject private var ui = Local()
    @FocusState private var foco: Bool
    @StateObject private var rec = Gravador()

    private var temTexto: Bool { !ui.texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var podeEnviar: Bool { temTexto || !store.anexos.isEmpty }

    var body: some View {
        VStack(spacing: 6) {
            if ui.showStickers {
                StickerPicker(store: store, jid: jid, compact: compact, showing: $ui.showStickers)
            }

            if let f = store.fileSending {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Enviando \(f)…").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
            }

            if let e = store.erro {
                Text(e).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.red.opacity(0.12)))
                    .onTapGesture { store.erro = nil }
            }

            if let q = store.replyTo, q.jid == jid {
                HStack(alignment: .center, spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(q.me ? "Respondendo você" : "Respondendo \(store.selectedChat.map { nomeBonito($0.name) } ?? "contato")")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(q.text.isEmpty ? "Mensagem" : q.text)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    Button { store.replyTo = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Cancelar")
                }
                .frame(height: 32)
                .padding(.horizontal, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
            }

            if !store.anexos.isEmpty {
                AnexosFila(store: store)
            } else if !temTexto && !rec.gravando {
                if let ia = store.ia[jid], ia.precisaResposta, ia.sugestao != nil || ia.pensando {
                    SugestaoIA(store: store, jid: jid, ia: ia, compact: compact) { ui.texto = $0 }
                } else {
                    QuickReplies(store: store, compact: compact) { text in await enviar(text) }
                }
            }

            HStack(alignment: .center, spacing: 8) {
                if rec.gravando {
                    gravandoBarra
                } else {
                    BotaoVidro(icone: "plus", tamanho: compact ? 30 : 32, ajuda: "Anexar foto, áudio ou arquivo (ou arraste / ⌘V)") {
                        escolherArquivo()
                    }
                    campo
                }
            }
        }
        .padding(.horizontal, compact ? 10 : 16)
        .padding(.top, 4)
        .padding(.bottom, compact ? 10 : 14)
        .task { await store.loadSuggestions(jid) }
        .onChange(of: jid) { _, _ in
            ui.texto = ""
            ui.showStickers = false
            store.replyTo = nil
            _ = rec.parar(enviar: false)
            Task { await store.loadSuggestions(jid) }
        }
    }

    /// cápsula do campo: texto + figurinha + (enviar | microfone)
    private var campo: some View {
        HStack(spacing: 4) {
            TextField(store.anexos.isEmpty ? "Mensagem" : "Legenda (opcional)", text: $ui.texto)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($foco)
                .onAppear { if store.focar == jid { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { foco = true; store.focar = nil } } }
                .onChange(of: store.focar) { _, j in if j == jid { foco = true; store.focar = nil } }
                .onSubmit { Task { await enviar() } }
            Button { ui.showStickers.toggle() } label: {
                Image(systemName: ui.showStickers ? "face.smiling.inverse" : "face.smiling")
                    .font(.system(size: 14))
                    .foregroundStyle(ui.showStickers ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Figurinhas")
            if podeEnviar {
                Button { Task { await enviar() } } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .disabled(store.sending || store.fileSending != nil)
                .help("Enviar (↵)")
                .transition(.scale.combined(with: .opacity))
            } else {
                Button { Task { if !(await rec.comecar()) { store.erro = "Sem acesso ao microfone (Ajustes › Privacidade)" } } } label: {
                    Image(systemName: "mic")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Gravar áudio")
                .transition(.opacity)
            }
        }
        .padding(.leading, 13).padding(.trailing, 4)
        .frame(height: compact ? 32 : 34)
        .glassEffect(.regular, in: .capsule)
        .animation(.snappy(duration: 0.18), value: podeEnviar)
    }

    /// gravando: cancelar · bolinha vermelha + tempo · enviar
    private var gravandoBarra: some View {
        HStack(spacing: 10) {
            BotaoVidro(icone: "xmark", tamanho: compact ? 30 : 32, ajuda: "Descartar áudio") {
                _ = rec.parar(enviar: false)
            }
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                    .symbolEffect(.pulse, options: .repeating)
                Text(String(format: "%d:%02d", rec.segundos / 60, rec.segundos % 60))
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                Text("gravando").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button { enviarAudio() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                .help("Enviar áudio (↵)")
            }
            .padding(.leading, 13).padding(.trailing, 4)
            .frame(height: compact ? 32 : 34)
            .glassEffect(.regular, in: .capsule)
        }
    }

    private func enviarAudio() {
        guard let f = rec.parar(enviar: true) else { return }
        store.limparAnexos()
        store.anexar([f], nomes: ["Áudio"])
        try? FileManager.default.removeItem(at: f)
        let alvo = jid
        Task { _ = await store.enviarAnexos(to: alvo, legenda: "") }
    }

    private func escolherArquivo() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.prompt = "Anexar"
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK else { return }
        store.anexar(p.urls)
    }

    private func enviar() async {
        let t = ui.texto.trimmingCharacters(in: .whitespacesAndNewlines)
        if !store.anexos.isEmpty {
            ui.texto = ""
            let usouLegenda = await store.enviarAnexos(to: jid, legenda: t)
            if !usouLegenda, !t.isEmpty { await enviar(t) }
            return
        }
        guard !t.isEmpty else { return }
        ui.texto = ""
        await enviar(t)
    }

    private func enviar(_ texto: String) async {
        let t = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let quote = store.replyTo?.jid == jid ? store.replyTo?.id : nil
        let ok = await store.send(t, to: jid, quoteId: quote)
        if !ok { ui.texto = t }
    }
}

/// anexos esperando o enviar: miniatura (foto) ou ícone + nome, × pra tirar
struct AnexosFila: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.anexos) { a in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if a.imagem, let img = NSImage(contentsOf: a.url) {
                                Image(nsImage: img).resizable().scaledToFill()
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            } else {
                                VStack(spacing: 4) {
                                    Image(systemName: a.icone).font(.system(size: 16))
                                    Text(a.nome).font(.system(size: 9)).lineLimit(1).truncationMode(.middle)
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .frame(width: 76, height: 56)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(cinza))
                            }
                        }
                        Button { store.tirarAnexo(a) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(Color.black.opacity(0.55)))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .help("Tirar")
                    }
                }
            }
            .padding(.top, 6).padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Frases que eu mais escrevo, vindas do histórico local. Um clique envia.
struct QuickReplies: View {
    @ObservedObject var store: ChatStore
    var compact = false
    let send: (String) async -> Void

    var body: some View {
        if !store.suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.suggestions, id: \.self) { s in
                        Button { Task { await send(s) } } label: {
                            Text(s)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(cinza))
                        }
                        .buttonStyle(.plain)
                        .disabled(store.sending || store.stickerSending)
                        .help("Enviar: \(s)")
                    }
                }
            }
            .frame(height: 26)
        }
    }
}

/// Grade de figurinhas locais (WebP). Clique envia direto na conversa atual.
struct StickerPicker: View {
    @ObservedObject var store: ChatStore
    let jid: String
    var compact = false
    @Binding var showing: Bool

    private let cols = [GridItem(.adaptive(minimum: 58), spacing: 8)]

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("Figurinhas").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { showing = false } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Fechar")
            }
            .padding(.horizontal, 12).padding(.top, 10)

            Group {
                if store.stickers.isEmpty {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: compact ? 100 : 140)
                } else {
                    ScrollView {
                        LazyVGrid(columns: cols, spacing: 8) {
                            ForEach(store.stickers) { s in
                                Button {
                                    Task { await enviar(s) }
                                } label: {
                                    AsyncImage(url: store.stickerURL(s.id)) { phase in
                                        if case .success(let img) = phase {
                                            img.resizable().scaledToFit()
                                        } else {
                                            RoundedRectangle(cornerRadius: 10).fill(cinza)
                                        }
                                    }
                                    .frame(width: 54, height: 54)
                                    .contentShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                                .disabled(store.stickerSending)
                                .help(s.name + (s.mine ? " (sua)" : ""))
                            }
                        }
                        .padding(.horizontal, 10).padding(.bottom, 10)
                    }
                    .scrollIndicators(.never)
                    .frame(height: compact ? 130 : 190)
                }
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .task { await store.loadStickers() }
    }

    private func enviar(_ s: Sticker) async {
        let ok = await store.sendSticker(s.id, to: jid)
        if ok { showing = false }
    }
}


// MARK: - resposta pronta da IA dentro da conversa

/// a sugestão vira um balãozinho: um clique põe no campo (dá pra editar antes de enviar)
struct SugestaoIA: View {
    @ObservedObject var store: ChatStore
    let jid: String
    let ia: IAInfo
    var compact = false
    let usar: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if ia.pensando || ia.sugestao == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("pensando numa resposta…").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).frame(height: 28)
                Spacer(minLength: 0)
            } else if let s = ia.sugestao {
                Button { usar(s) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.accentColor)
                        Text(s).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.12)))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .help("Usar essa resposta (dá pra editar antes de enviar)")
                Menu {
                    Button("Outra sugestão") { store.onIARedo?(jid, "") }
                    Button("Mais curta") { store.onIARedo?(jid, "bem mais curta, 1 frase") }
                    Button("Vou ver e respondo") { usar("vou ver isso e ja te falo") }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 28, height: 28)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .glassEffect(.regular.interactive(), in: .circle)
                .help("Outra sugestão")
            }
        }
    }
}

// MARK: - lista de conversas (popover e janela usam a mesma)

struct ConversasLista: View {
    @ObservedObject var store: ChatStore
    var selecionado: String? = nil
    var compact = false
    /// busca vem de fora (janela usa o campo da toolbar)
    var buscaExterna: String? = nil
    /// a janela B mostra o filtro na barra de cima
    var mostraFiltro = true
    let abrir: (String) -> Void
    @StateObject private var ui = Local()

    private var q: String { (buscaExterna ?? ui.busca).trimmingCharacters(in: .whitespaces).lowercased() }
    private var filtradas: [Chat] {
        var base = store.chats.filter { store.passa($0.jid, grupo: $0.isGroup) }.sorted { $0.lastTs > $1.lastTs }
        if store.onlyUnread { base = base.filter { $0.unread > 0 } }
        guard !q.isEmpty else { return base }
        return base.filter { "\($0.name) \($0.last)".lowercased().contains(q) }
    }
    private var mostraFixados: Bool { q.isEmpty && !store.onlyUnread && store.chats.contains { store.pinned.contains($0.jid) } }
    private var visiveis: [Chat] { mostraFixados ? filtradas.filter { !store.pinned.contains($0.jid) } : filtradas }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                if buscaExterna == nil { CampoBusca(texto: $ui.busca) }
                HStack(spacing: 8) {
                    if mostraFiltro { FiltroSeg(store: store) }
                    Button { withAnimation(.snappy(duration: 0.2)) { store.onlyUnread.toggle() } } label: {
                        Text("Não lidas")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(store.onlyUnread ? Color(nsColor: .windowBackgroundColor) : Color.secondary)
                            .padding(.horizontal, 12).frame(height: 32)
                            .background(Capsule().fill(store.onlyUnread ? Color.primary : Color.primary.opacity(0.07)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    if !mostraFiltro { Spacer(minLength: 0) }
                }
            }
            .padding(.horizontal, compact ? 4 : 12).padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 1) {
                    if mostraFixados { Fixados(store: store) { abrir($0) } }
                    if visiveis.isEmpty {
                        VazioLista(soNaoLidas: store.onlyUnread)
                    } else {
                        ForEach(visiveis) { c in
                            ChatRow(store: store, chat: c, selected: selecionado == c.jid, onTap: { abrir(c.jid) }, onFiles: { urls in
                                store.anexar(urls); abrir(c.jid)
                            })
                            .contextMenu {
                                if compact { Button("Abrir na janela") { store.onJanela?(c.jid) } }
                                Button(store.pinned.contains(c.jid) ? "Desafixar" : "Fixar no topo") { store.togglePin(c.jid) }
                            }
                        }
                    }
                }
                .padding(.horizontal, compact ? 0 : 8).padding(.vertical, 2)
            }
            .scrollIndicators(.never)

            StatusFooter(store: store)
        }
    }
}


/// pílulas de status na linha da conversa: responder · demandas · @
struct SelosView: View {
    let s: Selos
    var body: some View {
        HStack(spacing: 4) {
            if s.responder { SeloPilula(texto: "responder", icone: nil, cor: .blue) }
            if s.demandas > 0 { SeloPilula(texto: "\(s.demandas)", icone: "tray.full.fill", cor: .orange) }
            if s.marcacoes > 0 { SeloPilula(texto: "\(s.marcacoes)", icone: "at", cor: .purple) }
        }
        .fixedSize()
    }
}

struct SeloPilula: View {
    let texto: String
    let icone: String?
    let cor: Color
    var body: some View {
        HStack(spacing: 3) {
            if let icone { Image(systemName: icone).font(.system(size: 8.5, weight: .bold)) }
            Text(texto).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(cor)
        .padding(.horizontal, 7).frame(height: 18)
        .background(Capsule().fill(cor.opacity(0.14)))
    }
}

/// Tudo · Privado · Trabalho em cápsula (estilo macOS 27)
struct FiltroSeg: View {
    @ObservedObject var store: ChatStore
    var opcoes: [Filtro] = Filtro.allCases
    var body: some View {
        HStack(spacing: 2) {
            ForEach(opcoes) { f in
                let sel = store.filtro == f
                Button { withAnimation(.snappy(duration: 0.22)) { store.filtro = f } } label: {
                    Text(f.nome)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(sel ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12).frame(height: 26)
                        .frame(maxWidth: .infinity)
                        .background(Capsule().fill(sel ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                            .shadow(color: .black.opacity(sel ? 0.15 : 0), radius: 2, y: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}
