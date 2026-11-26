import SwiftUI
import AppKit

// ZAP_PREVIEW=/pasta → renderiza telas com dados de exemplo em PNG e sai
@MainActor
enum PreviewRender {
    /// dados de exemplo no idioma do app (prints da LP em inglês)
    static func t(_ pt: String, _ en: String) -> String { Idioma.atual == "en" ? en : pt }

    static func run(_ dir: String) {
        let now = Int(Date().timeIntervalSince1970)
        let today = Demand.ymd.string(from: Date())
        func dm(_ id: String, _ client: String, _ title: String, _ who: String, _ mins: Int, group: Bool = true, due: String? = nil, urgent: Bool = false) -> Demand {
            Demand(id: id, jid: id + "@g.us", title: title, detail: t("Banner novo da home com a arte que ele mandou, e mandar print quando subir.", "New home page banner with the art he sent, and send a screenshot once it's live."),
                   client: client, who: who, chatName: t("Projeto - \(client)", "Project · \(client)"), isGroup: group, ts: now - mins * 60,
                   quote: t("@Ana sobe esse banner novo da black e manda print qndo tiver no ar", "@Ana can you push the new black friday banner and send a screenshot when it's live"), due: due, urgent: urgent,
                   status: "open", autoDone: false, doneAt: nil, isNew: false, mine: true, area: "dev")
        }
        let s = Store()
        s.serverUp = true; s.connected = true; s.scanning = 3
        s.open = [
            dm("a", "Studio Norte", t("Trocar banner da Black na home", "Swap the Black Friday banner on the home page"), "Paula", 50, due: today),
            dm("b", "Loja Aurora", t("Esconder pop-up VIP pra quem vem do anúncio", "Hide the VIP pop-up for visitors from ads"), "Bruno", 190, group: false, urgent: true),
            dm("c", "Loja Aurora", t("Trocar popup para copy de lançamento", "Change the pop-up to the launch copy"), "Bruno", 420),
            dm("d", "Café Grão", t("Liberar checkout da loja pra teste", "Open the store checkout for testing"), "Lucas", 12, group: false),
        ]
        s.expanded = "a"
        s.tab = .open
        save(VStack(spacing: 8) { ForEach(s.groups) { ClientCard(store: s, g: $0) } }.padding(14).frame(width: 420), "\(dir)/dem-clients.png")
        save(VStack(spacing: 8) { ForEach(s.visible) { DemandCard(store: s, d: $0) } }.padding(14).frame(width: 420), "\(dir)/dem-cards.png")
        saveWin(PopoverView(store: s), "\(dir)/dem-pop.png")
        // ponte: caída (Mac dormiu) e conectada
        let agoraP = Date().timeIntervalSince1970
        s.connected = false
        s.ponte = PonteInfo(connected: false, ultimaQueda: PonteQueda(at: agoraP - 180, code: 428, motivo: "Mac dormiu", msg: nil))
        saveWin(PopoverView(store: s), "\(dir)/ponte-fora.png")
        s.connected = true
        s.ponte = PonteInfo(connected: true, since: agoraP - 3600, lastRx: agoraP - 60)
        saveWin(PopoverView(store: s), "\(dir)/ponte-ok.png")
        typealias L = UnreadChat.Line
        s.unread = [
            UnreadChat(jid: "x@g.us", name: t("Projeto - Studio Norte", "Project · Studio Norte"), isGroup: true, client: "Studio Norte", count: 3, lastTs: now - 900,
                       summary: t("Paula perguntou se o banner novo da Black já pode subir hoje à tarde.", "Paula asked if the new Black Friday banner can go live this afternoon."), needsReply: true, urgent: false, kind: "pergunta",
                       suggestion: t("Pode sim, subo agora à tarde e te mando o print", "Sure, I'll push it this afternoon and send you a screenshot"), pending: false, failed: false, demands: 1,
                       tail: [L(me: false, who: "Paula", text: t("@Ana o banner novo da black ja pode subir?", "@Ana can the new black friday banner go live?"), ts: now - 900)]),
            UnreadChat(jid: "y@s.whatsapp.net", name: "Lucas Café Grão", isGroup: false, client: "Café Grão", count: 1, lastTs: now - 3000,
                       summary: t("Lucas mandou o acesso da da loja e perguntou se tu consegue testar o checkout amanhã.", "Lucas sent the store login and asked if you can test the checkout tomorrow."), needsReply: true, urgent: true, kind: "pedido",
                       suggestion: t("consigo sim, amanha cedo testo e te falo", "sure, i'll test it first thing tomorrow"), pending: false, failed: false, demands: 0, tail: []),
            UnreadChat(jid: "z@g.us", name: t("Equipe", "Team"), isGroup: true, client: t("Equipe", "Team"), count: 12, lastTs: now - 400,
                       summary: t("Bruno e Diego combinando horário da call de sexta, nada pra ti.", "Bruno and Diego picking a time for Friday's call, nothing for you."), needsReply: false, urgent: false, kind: "papo",
                       suggestion: nil, pending: false, failed: false, demands: 0, tail: []),
            UnreadChat(jid: "w@g.us", name: t("Projeto - Casa Brisa", "Project · Casa Brisa"), isGroup: true, client: "Casa Brisa", count: 2, lastTs: now - 60,
                       summary: "", needsReply: false, urgent: false, kind: "papo", suggestion: nil, pending: true, failed: false, demands: 0, tail: []),
        ]
        s.tab = .zap
        saveWin(PopoverView(store: s), "\(dir)/dem-zap.png")
        s.expandedChat = "x@g.us"
        saveWin(PopoverView(store: s), "\(dir)/dem-zap-open.png")
        saveWin(PopoverView(store: s), "\(dir)/dem-zap-dark.png", dark: true)
        // merge: conversa privada de verdade + IA dentro dela
        s.zp.serverUp = true; s.zp.connected = true; s.zp.lastSync = Date(); s.zp.lastDbTs = now - 120
        s.zp.chats = [
            Chat(jid: "y@s.whatsapp.net", name: "Lucas Café Grão", last: t("consegue testar o checkout amanhã?", "can you test the checkout tomorrow?"), lastTs: now - 3000, unread: 2),
            Chat(jid: "t@s.whatsapp.net", name: "Bruno", last: t("Tu: subi o banner", "You: banner is live"), lastTs: now - 5000, unread: 0),
            Chat(jid: "j@s.whatsapp.net", name: "Carla", last: t("mandei as artes no drive", "sent the artwork to the drive"), lastTs: now - 9000, unread: 1),
        ]
        s.zp.messages = [
            Msg(id: "1", jid: "y@s.whatsapp.net", me: true, ts: now - 7200, type: "conversation", text: t("fala lucas, ja subi a home nova", "hey lucas, new home page is live"), caption: "", media: false, transcript: nil),
            Msg(id: "2", jid: "y@s.whatsapp.net", me: false, ts: now - 3100, type: "conversation", text: t("Show! Te mandei o acesso da da loja no email", "Nice! Sent you the store login by email"), caption: "", media: false, transcript: nil),
            Msg(id: "3", jid: "y@s.whatsapp.net", me: false, ts: now - 3000, type: "conversation", text: t("consegue testar o checkout amanhã?", "can you test the checkout tomorrow?"), caption: "", media: false, transcript: nil),
        ]
        s.zp.selected = "y@s.whatsapp.net"
        s.syncIA()
        s.tab = .zap
        s.zapChat = "y@s.whatsapp.net"
        saveWin(PopoverView(store: s), "\(dir)/merge-pop-chat.png")
        saveWin(PopoverView(store: s), "\(dir)/merge-pop-chat-dark.png", dark: true)
        s.zapChat = nil; s.zapTodas = true
        saveWin(PopoverView(store: s), "\(dir)/merge-pop-todas.png")
        s.zapTodas = false; s.expandedChat = nil
        saveWin(PopoverView(store: s), "\(dir)/merge-pop-resumo.png")
        // layouts novos (A/B/C) com grupos de trabalho e marcação
        s.zp.chats += [
            Chat(jid: "w1@g.us", name: t("Loja Aurora / Equipe", "Loja Aurora / Team"), last: t("Bruno: o fix do pop-up já subiu?", "Bruno: is the pop-up fix live?"), lastTs: now - 900, unread: 3, group: true, work: true),
            Chat(jid: "w2@g.us", name: t("Equipe - Studio", "Studio · Team"), last: t("Bruno: banner novo de 30% chegou", "Bruno: new 30% banner just came in"), lastTs: now - 2500, unread: 0, group: true, work: true),
        ]
        s.mentions = [Mention(id: "m1", jid: "w1@g.us", ts: now - 900, how: "mention", chatName: t("Loja Aurora / Equipe", "Loja Aurora / Team"), client: "Loja Aurora", who: "Bruno",
                              quote: t("@Ana o fix do pop-up já tá no ar?", "@Ana is the pop-up fix live yet?"), summary: t("Bruno quer saber se o fix do pop-up já está no ar.", "Bruno wants to know if the pop-up fix is live."), kind: "responder",
                              urgent: false, seen: false, ok: false, demandId: nil)]
        s.zapChat = nil; s.zapTodas = false; s.syncIA()
        let jm = JanelaModel()
        for (nome, l) in [("caixa", Layout.caixa), ("conversa", Layout.conversa), ("hoje", Layout.hoje)] {
            s.layout = l
            saveWin(PopoverView(store: s), "\(dir)/lay-\(nome)-pop.png")
            saveWin(PopoverView(store: s), "\(dir)/lay-\(nome)-pop-dark.png", dark: true)
            jm.sel = nil
            if l == .hoje { jm.sel = s.feed.first?.id }
            saveWin(JanelaView(store: s, m: jm).frame(width: 1120, height: 680), "\(dir)/lay-\(nome)-win.png")
        }
        // balanço da pedra (chegou demanda): quadros de -16° a 16°
        save(HStack(spacing: 6) {
            ForEach([-16.0, -10, -4, 0, 6, 12, 16, 8], id: \.self) { g in
                Image(nsImage: { var p = Daemon.Pose(); p.tilt = CGFloat(g); p.sx = 0.9; p.sy = 0.9
                    return Daemon.image(filled: true, size: 66, color: .black, template: false, pose: p) }())
                    .frame(width: 66, height: 66).background(Color.gray.opacity(0.12))
            }
        }.padding(10), "\(dir)/balanco.png")
        // redimensionar: a janela Hoje em vários tamanhos, com e sem detalhe aberto
        s.layout = .hoje
        for (w, h) in [(720, 500), (860, 560), (1000, 620), (1120, 680), (1300, 760), (1600, 900), (1920, 1080)] {
            jm.sel = nil
            saveWin(JanelaView(store: s, m: jm).frame(width: CGFloat(w), height: CGFloat(h)), "\(dir)/tam-\(w)x\(h).png")
            jm.sel = s.feed.first?.id
            saveWin(JanelaView(store: s, m: jm).frame(width: CGFloat(w), height: CGFloat(h)), "\(dir)/tam-\(w)x\(h)-det.png")
        }
        // colunas automáticas: busca sem resultado = nenhuma coluna (estado vazio)
        jm.sel = nil; jm.busca = "zzzz"
        saveWin(JanelaView(store: s, m: jm).frame(width: 1120, height: 680), "\(dir)/tam-vazio.png")
        jm.busca = ""
        s.zp.filtro = .trabalho
        s.layout = .caixa
        saveWin(PopoverView(store: s), "\(dir)/lay-caixa-trabalho.png")
        s.zp.filtro = .tudo
        s.layout = .classico
        s.tab = .open
        for (name, filled) in [("dem-icon-full", true), ("dem-icon-empty", false)] {
            let img = Daemon.image(filled: filled, size: 96, color: .black, template: false)
            if let t = img.tiffRepresentation { try? NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png")) }
        }
        // tira de frames da animação "acordou" + estado com bolinha
        let frames = stride(from: 0.0, through: WakeAnim.duration, by: WakeAnim.duration / 11).map { t in
            Image(nsImage: Daemon.image(filled: true, size: 72, color: NSColor(Mood.calm), template: false, pose: WakeAnim.pose(t)))
        }
        save(HStack(spacing: 6) { ForEach(0..<frames.count, id: \.self) { frames[$0] }
            Image(nsImage: Daemon.image(filled: true, size: 72, color: .black, template: false, dot: NSColor(Mood.calm))) }.padding(10),
             "\(dir)/dem-wake.png")
        let idle = stride(from: 0.0, through: IdleAnim.duration, by: IdleAnim.duration / 11).map { t in
            Image(nsImage: Daemon.image(filled: true, size: 72, color: .black, template: false, pose: IdleAnim.pose(t)))
        }
        save(HStack(spacing: 6) { ForEach(0..<idle.count, id: \.self) { idle[$0] }
            Image(nsImage: Daemon.image(filled: false, size: 72, color: .black, template: false)) }.padding(10),
             "\(dir)/dem-idle.png")
        let bubbleTimes: [Double] = [0.3, 1.0, 1.1, 1.2, 1.4, 2.5, WakeAnim.total - 0.25, WakeAnim.total - 0.1]
        save(VStack(alignment: .leading, spacing: 6) { ForEach(bubbleTimes, id: \.self) { t in
            Image(nsImage: WakeAnim.frame(t: t, text: PreviewRender.t("Nova demanda de Studio Norte", "New task from Studio Norte"))) } }
            .padding(10).scaleEffect(3, anchor: .topLeading).frame(width: 600, height: 560, alignment: .topLeading),
             "\(dir)/dem-bubble.png")
        save(DaemonLogo(size: 80).padding(10), "\(dir)/dem-logo.png")
        let n = NotifModel(); n.demands = [s.open[0]]
        save(NotifView(store: s, model: n, claude: { _ in }, later: {}, notDemand: { _ in }, openList: {}).padding(10), "\(dir)/dem-notif.png")
    }

    /// com TextField/Menu (AppKit por baixo) o ImageRenderer falha: desenha numa janela fora da tela
    static func saveWin<V: View>(_ v: V, _ path: String, dark: Bool = false) {
        let host = NSHostingView(rootView: v.background(Color(nsColor: .windowBackgroundColor)))
        let size = host.fittingSize
        let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = host
        w.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        w.orderOut(nil)
    }

    static func save<V: View>(_ v: V, _ path: String) {
        let r = ImageRenderer(content: v.background(Color(nsColor: .windowBackgroundColor)))
        r.scale = 2
        if let img = r.nsImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t),
           let png = b.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}
