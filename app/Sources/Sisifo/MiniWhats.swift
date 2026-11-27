import AppKit
import SwiftUI

// Mini WhatsApp: janelinha opcional (Ajustes › Mini WhatsApp) com TODAS as conversas,
// privadas e grupos, no visual do antigo Zap Privado. Lista estilo Mensagens → conversa com voltar.

final class MiniModel: ObservableObject {
    enum Aba: String, CaseIterable, Identifiable { case tudo, privado, grupos; var id: String { rawValue } }
    @Published var aba: Aba = Aba(rawValue: UserDefaults.standard.string(forKey: "mini.aba") ?? "") ?? .tudo {
        didSet { UserDefaults.standard.set(aba.rawValue, forKey: "mini.aba") }
    }
    @Published var sel: String?
    @Published var busca = ""
    @Published var soNaoLidas = false
}

@MainActor
final class MiniWhatsController: NSObject, NSWindowDelegate {
    let zp: ChatStore
    let model = MiniModel()
    private var window: NSWindow?

    init(zp: ChatStore) { self.zp = zp }

    var aberta: Bool { window?.isVisible == true }

    func toggle() { aberta ? window?.performClose(nil) : show() }

    func show(_ jid: String? = nil) {
        zp.incluirTodos = true
        if window == nil { window = build() }
        if let jid { abrir(jid) }
        Task { await zp.refresh() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func abrir(_ jid: String) {
        model.sel = jid
        Task { await zp.select(jid) }
    }

    func fechar() {
        window?.performClose(nil)
    }

    /// debug: PNG da janelinha (app.sisifo.cmd "miniPrint:/caminho.png")
    func snapshot(_ path: String) {
        guard let v = window?.contentView?.superview, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    func windowWillClose(_ n: Notification) {
        zp.incluirTodos = false
        if model.sel != nil, zp.selected == model.sel { zp.fechar() }
        model.sel = nil
    }

    private func build() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 660),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "WhatsApp"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 340, height: 460)
        w.contentViewController = NSHostingController(rootView: MiniWhatsView(zp: zp, m: model, ctl: self))
        w.delegate = self
        w.setContentSize(NSSize(width: 400, height: 660))
        w.center()
        w.setFrameAutosaveName("SisifoMiniWhats")
        return w
    }
}

struct MiniWhatsView: View {
    @ObservedObject var zp: ChatStore
    @ObservedObject var m: MiniModel
    let ctl: MiniWhatsController

    private var q: String { m.busca.trimmingCharacters(in: .whitespaces).lowercased() }
    private var fonte: [Chat] { zp.todas.isEmpty ? zp.chats : zp.todas }
    private var lista: [Chat] {
        var b = fonte.sorted { $0.lastTs > $1.lastTs }
        switch m.aba {
        case .tudo: break
        case .privado: b = b.filter { !$0.isGroup }
        case .grupos: b = b.filter { $0.isGroup }
        }
        if m.soNaoLidas { b = b.filter { $0.unread > 0 } }
        if !q.isEmpty { b = b.filter { "\($0.name) \($0.last)".lowercased().contains(q) } }
        return b
    }
    private var mostraFixados: Bool { q.isEmpty && !m.soNaoLidas && m.aba == .tudo && fonte.contains { zp.pinned.contains($0.jid) } }

    var body: some View {
        ZStack {
            Vidro(material: .sidebar).ignoresSafeArea()
            if let jid = m.sel {
                conversa(jid)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                listaView
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: m.sel)
        .frame(minWidth: 340, minHeight: 460)
    }

    @ViewBuilder func conversa(_ jid: String) -> some View {
        let chat = fonte.first { $0.jid == jid }
            ?? Chat(jid: jid, name: jid, last: "", lastTs: 0, unread: 0, group: jid.hasSuffix("@g.us"), work: nil)
        ChatView(store: zp, chat: chat, compact: true, onBack: { m.sel = nil; zp.fechar() }, onWindow: nil)
            .task(id: jid) { if zp.selected != jid { await zp.select(jid) } }
    }

    private var naoLidasTotal: Int { fonte.filter { m.aba == .grupos ? $0.isGroup : m.aba == .privado ? !$0.isGroup : true }.filter { $0.unread > 0 }.count }

    var listaView: some View {
        VStack(spacing: 0) {
            // título na mesma linha dos semáforos (sem faixa vazia em cima)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Color.clear.frame(width: 62, height: 1)
                Text("WhatsApp").font(.system(size: 15, weight: .bold))
                if naoLidasTotal > 0 {
                    Text("\(naoLidasTotal)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 7).frame(height: 30).padding(.bottom, 8)

            VStack(spacing: 8) {
                CampoBusca(texto: $m.busca)
                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        ForEach(MiniModel.Aba.allCases) { a in
                            let sel = m.aba == a
                            Button { withAnimation(.snappy(duration: 0.22)) { m.aba = a } } label: {
                                Text(L(a == .tudo ? "Tudo" : a == .privado ? "Privado" : "Grupos"))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(sel ? Color.primary : Color.secondary)
                                    .padding(.horizontal, 8).frame(height: 26).lineLimit(1).fixedSize()
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
                    Button { withAnimation(.snappy(duration: 0.2)) { m.soNaoLidas.toggle() } } label: {
                        Text("Não lidas")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(m.soNaoLidas ? Color(nsColor: .windowBackgroundColor) : Color.secondary)
                            .padding(.horizontal, 12).frame(height: 32)
                            .background(Capsule().fill(m.soNaoLidas ? Color.primary : Color.primary.opacity(0.07)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 1) {
                    if mostraFixados { Fixados(store: zp, fonte: fonte) { ctl.abrir($0) } }
                    let itens = lista
                    if itens.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: m.soNaoLidas ? "checkmark.bubble" : "bubble.left.and.bubble.right")
                                .font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                            Text(L(m.soNaoLidas ? "Tudo lido" : !q.isEmpty ? "Nada encontrado" : "Nenhuma conversa"))
                                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 60)
                    } else {
                        ForEach(itens) { c in
                            ChatRow(store: zp, chat: c, onTap: { ctl.abrir(c.jid) }, onFiles: { urls in
                                zp.anexar(urls); ctl.abrir(c.jid)
                            })
                            .contextMenu {
                                Button(zp.pinned.contains(c.jid) ? "Desafixar" : "Fixar no topo") { zp.togglePin(c.jid) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 2)
            }
            .scrollIndicators(.never)

            StatusFooter(store: zp)
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// botão da barra de cima da janela grande (só aparece com o Mini WhatsApp ligado)
struct BotaoMiniWhats: View {
    @ObservedObject var zp: ChatStore
    let acao: () -> Void
    var body: some View {
        let n = zp.totalUnread
        Button(action: acao) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 30, height: 30).background(Circle().fill(Color.primary.opacity(0.07)))
                .overlay(alignment: .topTrailing) {
                    if n > 0 {
                        Text(n > 99 ? "99+" : "\(n)")
                            .font(.system(size: 9, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                            .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                            .background(Capsule().fill(Color.accentColor))
                            .offset(x: 4, y: -3)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(L("Mini WhatsApp"))
    }
}
