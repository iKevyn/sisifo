import ServiceManagement
import AppKit
import SwiftUI
import Combine
import Carbon
import UserNotifications

@main
struct Main {
    static func main() {
        if let dir = ProcessInfo.processInfo.environment["ZAP_PREVIEW"] {
            MainActor.assumeIsolated { PreviewRender.run(dir) }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = Store()
    var item: NSStatusItem!
    let popover = NSPopover()
    var server: Process?
    /// servidor das conversas privadas (o antigo Zap Privado, :47831)
    var serverChat: Process?
    var chatTimer: Timer?
    var presenceTimer: Timer?
    var quitting = false
    var timer: Timer?
    var hotkeys: HotKeys?
    lazy var notif = NotifController(store: store)
    lazy var claude = ClaudeController(store: store)
    lazy var janela = JanelaController(store: store)
    let onboarding = OnboardingController()
    let atualizacao = Atualizacao()
    var bridge: Process?
    var unseen = false
    var animTimer: Timer?
    var animStart = Date()
    var idleTimer: Timer?
    var idleFrame: Int?
    var screenAsleep = false
    /// ícones prontos em bitmap (não redesenha o vetor a cada frame/refresh)
    var iconCache: [String: NSImage] = [:]

    /// clicar no ícone do Dock abre a janela
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { janela.show() }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// menu de app normal: Sair, Ocultar e Editar (pra ⌘C/⌘V/⌘A funcionarem nos campos)
    func montarMenuPrincipal() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Abrir janela"), action: #selector(abrirJanelaMenu), keyEquivalent: "0").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Ocultar Sísifo"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Sair do Sísifo"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let idiomaItem = NSMenuItem(title: L("Idioma"), action: nil, keyEquivalent: "")
        let idiomas = NSMenu()
        for (cod, nome) in [("pt", "Português"), ("en", "English")] {
            let it = NSMenuItem(title: nome, action: #selector(trocarIdioma(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = cod; it.state = Idioma.atual == cod ? .on : .off
            idiomas.addItem(it)
        }
        idiomaItem.submenu = idiomas
        let att = NSMenuItem(title: L("Procurar atualização"), action: #selector(Atualizacao.clicouMenu), keyEquivalent: "")
        att.target = atualizacao
        atualizacao.menuItem = att
        appMenu.insertItem(att, at: 1)
        appMenu.insertItem(idiomaItem, at: 1)
        appMenu.insertItem(.separator(), at: 1)
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: L("Editar"))
        edit.addItem(withTitle: L("Desfazer"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L("Refazer"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Recortar"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copiar"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Colar"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Selecionar tudo"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: L("Janela"))
        win.addItem(withTitle: L("Fechar"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: L("Minimizar"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }
    @objc func abrirJanelaMenu() { janela.show() }
    @objc func trocarIdioma(_ sender: NSMenuItem) {
        guard let cod = sender.representedObject as? String, cod != Idioma.atual else { return }
        quitting = true
        server?.terminate(); serverChat?.terminate(); bridge?.terminate()
        TrocaIdioma.definir(cod)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        montarMenuPrincipal()
        atualizacao.antesDeSair = { [weak self] in
            self?.quitting = true
            self?.server?.terminate(); self?.serverChat?.terminate(); self?.bridge?.terminate()
        }
        atualizacao.iniciar()
        // ponte do WhatsApp sempre; servidores e janela depois da primeira abertura
        startBridgeIfNeeded()
        if SisifoConfig.load().onboarded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.janela.show() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.onboarding.show { [weak self] in
                    self?.startServerIfNeeded(); self?.startChatServerIfNeeded()
                    self?.janela.show()
                }
            }
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        // ícone na barra de menus: a pedra com o número de abertas; clicar abre a janela (sem painel)
        item.isVisible = true
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { [weak self] _ in
            self?.store.popoverOpen = false
        }

        let host = NSHostingController(rootView: PopoverView(store: store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true

        store.onChange = { [weak self] in self?.updateIcon() }
        // clicar em Claude Code marca a demanda (ou o cliente inteiro) como "Claude fazendo"
        store.onClaude = { [weak self] d in self?.popover.performClose(nil); self?.store.fazendo(d, "claude"); self?.claude.open(d) }
        store.onClaudeClient = { [weak self] g in self?.popover.performClose(nil); self?.store.fazendoCliente(g.name, "claude"); self?.claude.open(client: g) }
        store.onOpenWindow = { [weak self] in self?.popover.performClose(nil); self?.janela.show() }
        store.onOpenChat = { [weak self] jid in self?.popover.performClose(nil); self?.janela.abrirConversa(jid) }
        store.onResponderJanela = { [weak self] jid in self?.janela.abrirConversa(jid, chat: true) }
        store.zp.onJanela = { [weak self] jid in self?.popover.performClose(nil); self?.janela.abrirConversa(jid) }
        store.ligarConversas()
        ligarNotificacoes()
        // ⌘V com imagem/arquivo no clipboard vira anexo da conversa aberta (texto segue normal)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.keyCode == 9,
                  e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  self.store.zp.chatAberto != nil else { return e }
            return self.store.zp.colar() ? nil : e
        }
        store.onNew = { [weak self] new in
            guard let self, !self.popover.isShown else { return }
            self.wake(Self.bubbleText(new))
            self.notif.show(new)
        }
        notif.onClaude = { [weak self] d in self?.store.fazendo(d, "claude"); self?.claude.open(d) }
        notif.onOpenList = { [weak self] in self?.togglePopover() }

        hotkeys = HotKeys { [weak self] key in
            guard let self else { return }
            switch key {
            case .list: self.togglePopover()
            case .window: self.popover.performClose(nil); self.janela.show()
            }
        }

        if SisifoConfig.load().onboarded { startServerIfNeeded(); startChatServerIfNeeded() }
        Task { await store.refresh() }
        Task { await store.zp.refresh() }
        chatTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.store.zp.refresh() }
        }
        // "digitando…" some em ~2 s; só pergunta com uma conversa aberta
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.store.zp.chatAberto != nil else { return }
                await self.store.zp.refreshPresence()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.store.refresh() }
        }
        updateIcon()
        scheduleIdle()
        let wsn = NSWorkspace.shared.notificationCenter
        wsn.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenAsleep = true } }
        wsn.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenAsleep = false } }

        // teste: distnoti app.sisifo.wake (ou ZAP_WAKE_TEST=1) dispara a animação
        DistributedNotificationCenter.default().addObserver(forName: .init("app.sisifo.wake"), object: nil, queue: .main) { [weak self] n in
            let text = (n.object as? String) ?? "Nova demanda"
            Task { @MainActor in self?.wake(text) }
        }
        // comandos locais (debug)
        DistributedNotificationCenter.default().addObserver(forName: .init("app.sisifo.cmd"), object: nil, queue: .main) { [weak self] n in
            let cmd = (n.object as? String) ?? ""
            Task { @MainActor in
                guard let self else { return }
                if cmd.hasPrefix("claude:") {
                    let id = String(cmd.dropFirst(7))
                    await self.store.refresh()
                    if let d = self.store.open.first(where: { $0.id == id }) { NSApp.activate(ignoringOtherApps: true); self.claude.open(d) }
                } else if cmd.hasPrefix("claudeClient:") {
                    let name = String(cmd.dropFirst(13))
                    await self.store.refresh()
                    if let g = self.store.groups.first(where: { $0.name == name }) { NSApp.activate(ignoringOtherApps: true); self.claude.open(client: g) }
                } else if cmd.hasPrefix("sound:") {
                    let v = String(cmd.dropFirst(6))
                    UserDefaults.standard.set(v, forKey: "sound")
                    WakeSound.play(v)
                } else if cmd == "test" {
                    self.wake("Nova demanda de Teste")
                } else if cmd.hasPrefix("janelaPrint:") {
                    self.janela.snapshot(String(cmd.dropFirst(12)))
                } else if cmd == "janela" {
                    self.janela.show()
                } else if cmd.hasPrefix("janela:") {
                    // janela:zap | janela:mentions | janela:mine → abre já na seção
                    switch cmd.dropFirst(7) {
                    case "zap": self.janela.model.secao = .zap
                    case "mentions": self.janela.model.secao = .mentions
                    default: self.janela.model.secao = .mine
                    }
                    self.janela.show()
                } else if cmd.hasPrefix("responder:") {
                    // debug: responder:<jid>|<msgId> = botão Responder de demanda/marcação (popover se estiver aberto, senão janela)
                    let p = String(cmd.dropFirst(10)).split(separator: "|", maxSplits: 1).map(String.init)
                    self.store.responderNoChat(jid: p[0], msgId: p.count > 1 ? p[1] : nil)
                } else if cmd.hasPrefix("abrir:") {
                    self.janela.abrirConversa(String(cmd.dropFirst(6)))
                } else if cmd.hasPrefix("popChat:") {
                    if !self.popover.isShown { self.togglePopover() }
                    self.store.abrirConversa(String(cmd.dropFirst(8)))
                } else if cmd.hasPrefix("popPrint:") {
                    // debug: PNG do popover aberto
                    if let v = self.popover.contentViewController?.view, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(cmd.dropFirst(9))))
                    }
                } else if cmd == "popZap" {
                    if !self.popover.isShown { self.togglePopover() }
                    self.store.fecharConversa(); self.store.tab = .zap
                } else if cmd == "popTodas" {
                    if !self.popover.isShown { self.togglePopover() }
                    self.store.fecharConversa(); self.store.tab = .zap; self.store.zapTodas = true
                } else if cmd.hasPrefix("layout:") {
                    self.store.fecharConversa()
                    self.store.layout = Layout(rawValue: String(cmd.dropFirst(7))) ?? .classico
                } else if cmd.hasPrefix("filtro:") {
                    self.store.zp.filtro = Filtro(rawValue: String(cmd.dropFirst(7))) ?? .tudo
                } else if cmd == "notif" {
                    self.store.zp.testarNotificacao()
                } else if cmd == "refresh" {
                    await self.store.refresh()
                }
            }
        }
        // Vorssaint (notch): clique no aviso de demanda abre a lista
        DistributedNotificationCenter.default().addObserver(forName: .init("app.sisifo.open"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.popover.isShown else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.togglePopover()
            }
        }
    }

    static func bubbleText(_ new: [Demand]) -> String {
        var names: [String] = []
        for d in new where !names.contains(d.client) { names.append(d.client) }
        if new.count == 1 { return "Nova demanda de \(names[0])" }
        let who = names.count <= 2 ? names.joined(separator: " e ") : "\(names[0]) e +\(names.count - 1)"
        return "\(new.count) novas · \(who)"
    }

    /// daemon acorda: pulinhos verdes + cápsula com o texto saindo do lado, depois fica a bolinha até abrir a lista
    func wake(_ text: String) {
        unseen = true
        WakeSound.play()
        NSApp.requestUserAttention(.informationalRequest)
        updateIcon()
        animTimer?.invalidate()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // sem movimento: só mostra a cápsula parada por uns segundos
            item.button?.title = ""
            item.button?.image = WakeAnim.frame(t: WakeAnim.bubbleIn + 0.5, text: text)
            animTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.animTimer = nil; self?.updateIcon() }
            }
            return
        }
        animStart = Date()
        item.button?.title = ""
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { t.invalidate(); return }
                let el = Date().timeIntervalSince(self.animStart)
                if el >= WakeAnim.total { t.invalidate(); self.animTimer = nil; self.updateIcon(); return }
                self.item.button?.image = WakeAnim.frame(t: el, text: text)
            }
        }
    }

    /// capetinha faz uma travessura a cada 30–60 s (sem movimento reduzido)
    func scheduleIdle() {
        Timer.scheduledTimer(withTimeInterval: .random(in: 30...60), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.mischief(); self?.scheduleIdle() }
        }
    }

    func mischief() {
        guard animTimer == nil, idleTimer == nil, !popover.isShown, !screenAsleep,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let start = Date()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { t.invalidate(); return }
                let el = Date().timeIntervalSince(start)
                if el >= IdleAnim.duration || self.animTimer != nil {
                    t.invalidate(); self.idleTimer = nil; self.idleFrame = nil; self.updateIcon(); return
                }
                self.idleFrame = Int(el * 24)
                self.updateIcon()
            }
        }
    }

    /// rasteriza em @2x uma vez só
    static func bake(_ vec: NSImage, appearance: NSAppearance) -> NSImage {
        let size = vec.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance { vec.draw(in: NSRect(origin: .zero, size: size)) }
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: size)
        out.addRepresentation(rep)
        out.isTemplate = vec.isTemplate
        return out
    }

    func applicationWillTerminate(_ n: Notification) {
        quitting = true
        server?.terminate()
        serverChat?.terminate()
        bridge?.terminate()
    }

    // MARK: notificação de mensagem nova (conversas privadas)

    func ligarNotificacoes() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        // responder direto no banner, sem abrir nada
        let responder = UNTextInputNotificationAction(identifier: "zp.responder", title: "Responder",
                                                      options: [], textInputButtonTitle: "Enviar", textInputPlaceholder: "Mensagem")
        center.setNotificationCategories([UNNotificationCategory(identifier: "zp.msg", actions: [responder], intentIdentifiers: [])])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        completion([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completion: @escaping () -> Void) {
        let jid = response.notification.request.content.userInfo["jid"] as? String
        let texto = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in
            guard let jid else { return }
            if let texto {
                _ = await self.store.zp.send(texto, to: jid)
            } else {
                if !self.popover.isShown { self.togglePopover() }
                self.store.abrirConversa(jid)
            }
        }
        completion()
    }

    /// Clique direito (ou ⌃clique) no ícone = menu com Sair; clique normal = popover.
    /// clique na pedra da barra de menus: menu de Mac com os números e os ajustes (sem painel)
    @objc func statusClicked() {
        unseen = false; updateIcon()
        let menu = NSMenu()
        func item(_ t: String, _ sel: Selector?, _ key: String = "", alvo: AnyObject? = nil, obj: Any? = nil, on: Bool = false) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
            i.target = alvo ?? self; i.representedObject = obj; i.state = on ? .on : .off
            return i
        }
        let abrir = item(L("Abrir o Sísifo"), #selector(abrirJanelaMenu), "z")
        abrir.keyEquivalentModifierMask = [.option]
        menu.addItem(abrir)
        menu.addItem(.separator())
        // números (clicar abre a janela)
        let en = Idioma.ingles
        let dem = store.mine.count, rp = store.toReply.count, at = store.mentionsUnseen
        let linhas: [(String, String)] = [
            ("tray.full", dem == 0 ? (en ? "No open tasks" : "Nenhuma demanda aberta") : (en ? "\(dem) open tasks" : "\(dem) demandas abertas")),
            ("bubble.left", rp == 0 ? (en ? "Nobody waiting for you" : "Ninguém esperando tua resposta") : (en ? "\(rp) waiting for your reply" : "\(rp) esperando tua resposta")),
            ("at", at == 0 ? (en ? "No new mentions" : "Nenhuma marcação nova") : (en ? "\(at) new mentions" : "\(at) marcações novas")),
        ]
        for (icone, texto) in linhas {
            let i = item(texto, #selector(abrirJanelaMenu))
            i.image = NSImage(systemSymbolName: icone, accessibilityDescription: nil)
            menu.addItem(i)
        }
        menu.addItem(.separator())
        // som (um só: eco do morro)
        menu.addItem(item(L("Som de demanda nova"), #selector(alternarSom), on: WakeSound.current != "off"))
        // aparência
        let apItem = NSMenuItem(title: L("Aparência"), action: nil, keyEquivalent: "")
        let ap = NSMenu()
        for (cod, nome) in [("auto", "Automático"), ("claro", "Claro"), ("escuro", "Escuro")] {
            ap.addItem(item(L(nome), #selector(escolherTema(_:)), obj: cod, on: janela.model.tema == cod))
        }
        apItem.submenu = ap
        menu.addItem(apItem)
        // idioma
        let idItem = NSMenuItem(title: L("Idioma"), action: nil, keyEquivalent: "")
        let id = NSMenu()
        for (cod, nome) in [("pt", "Português"), ("en", "English")] { id.addItem(item(nome, #selector(trocarIdioma(_:)), obj: cod, on: Idioma.atual == cod)) }
        idItem.submenu = id
        menu.addItem(idItem)
        menu.addItem(item(L("Abrir quando ligar o Mac"), #selector(alternarLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(item(atualizacao.menuItem?.title ?? L("Procurar atualização"), #selector(Atualizacao.clicouMenu), alvo: atualizacao))
        menu.addItem(.separator())
        let sair = NSMenuItem(title: L("Sair do Sísifo"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        sair.target = NSApp
        menu.addItem(sair)
        self.item.menu = menu
        self.item.button?.performClick(nil)
        self.item.menu = nil
    }
    @objc func alternarSom() {
        let ligar = WakeSound.current == "off"
        UserDefaults.standard.set(ligar ? WakeSound.padrao : "off", forKey: "sound")
        if ligar { WakeSound.play(WakeSound.padrao) }
    }
    @objc func escolherSom(_ s: NSMenuItem) {
        guard let v = s.representedObject as? String else { return }
        UserDefaults.standard.set(v, forKey: "sound"); WakeSound.play(v)
    }
    @objc func escolherTema(_ s: NSMenuItem) {
        guard let v = s.representedObject as? String else { return }
        janela.model.tema = v
    }
    @objc func alternarLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
    }

    @objc func togglePopover() {
        janela.show()
    }
    @objc func togglePopoverAntigo() {
        // garante o ícone visível enquanto o popover está aberto
        if !item.isVisible {
            item.isVisible = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.togglePopover() }
            return
        }
        guard let b = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        if unseen { unseen = false; updateIcon() }
        Task { await store.refresh() }
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        store.popoverOpen = true
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateIcon() {
        let abertas = store.mine.count
        NSApp.dockTile.badgeLabel = abertas > 0 ? "\(abertas)" : nil
        guard let b = item?.button, animTimer == nil else { return }
        let n = store.mine.count
        if unseen && n == 0 { unseen = false }
        let key = "\(unseen ? "u" : n > 0 ? "f" : "e")\(idleFrame ?? -1)\(unseen ? b.effectiveAppearance.name.rawValue : "")"
        let img: NSImage
        if let c = iconCache[key] { img = c } else {
            let pose = idleFrame.map { IdleAnim.pose(Double($0) / 24) } ?? Daemon.Pose()
            let vec = unseen
                ? Daemon.image(filled: true, size: 22, color: .labelColor, template: false, pose: pose, dot: NSColor(Mood.calm))
                : Daemon.image(filled: n > 0, size: 22, pose: pose)
            img = Self.bake(vec, appearance: b.effectiveAppearance)
            iconCache[key] = img
        }
        if b.image !== img { b.image = img }
        // texto/estado só quando muda (evita relayout da menu bar a cada frame)
        let dis = !store.serverUp || !store.connected
        if b.appearsDisabled != dis { b.appearsDisabled = dis }
        // marcações: só um "@N" discreto do lado, nunca pula nada na tela
        let at = store.mentionsUnseen
        let rp = store.toReply.count
        if n != lastCount || at != lastAt || rp != lastReply || b.title.isEmpty != (n == 0 && at == 0 && rp == 0) {
            lastCount = n
            lastAt = at
            lastReply = rp
            let t = NSMutableAttributedString()
            if n > 0 {
                t.append(NSAttributedString(string: " \(n)", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
                    .baselineOffset: 0.5,
                ]))
            }
            // conversas esperando resposta minha: balãozinho + número, discreto
            if rp > 0, let sym = NSImage(systemSymbolName: "bubble.left.fill", accessibilityDescription: "esperando resposta")?
                .withSymbolConfiguration(.init(pointSize: 9.5, weight: .semibold).applying(.init(paletteColors: [.secondaryLabelColor]))) {
                let att = NSTextAttachment(); att.image = sym
                att.bounds = NSRect(x: 0, y: -0.5, width: sym.size.width, height: sym.size.height)
                t.append(NSAttributedString(string: " "))
                t.append(NSAttributedString(attachment: att))
                t.append(NSAttributedString(string: "\(rp)", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .baselineOffset: 0.5,
                ]))
            }
            if at > 0 {
                t.append(NSAttributedString(string: " @\(at)", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .baselineOffset: 0.5,
                ]))
            }
            if t.length > 0 { b.attributedTitle = t } else { b.title = "" }
            var tip = n == 0 ? "Sísifo · nada pendente" : "Sísifo · \(n) abertas (⌥Z)"
            if rp > 0 { tip += " · \(rp) esperando tua resposta" }
            if at > 0 { tip += " · \(at) \(at == 1 ? "marcação nova" : "marcações novas")" }
            b.toolTip = tip
        }
    }
    var lastCount = -1
    var lastAt = -1
    var lastReply = -1

    // MARK: servidor Node

    func startBridgeIfNeeded() {
        Task {
            var r = URLRequest(url: URL(string: "\(Sisifo.bridgeBase)/status")!)
            r.timeoutInterval = 2
            if let (_, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse) != nil { return }
            bridge = Sisifo.spawn("bridge/src/bridge.js", log: "whatsapp", quitting: { [weak self] in self?.quitting ?? true }) { [weak self] in self?.startBridgeIfNeeded() }
        }
    }

    func startServerIfNeeded() {
        Task {
            var r = URLRequest(url: URL(string: "\(Sisifo.appBase)/pending")!)
            r.timeoutInterval = 2
            if (try? await URLSession.shared.data(for: r)) != nil { return }
            server = Sisifo.spawn("server/server.mjs", log: "demandas", quitting: { [weak self] in self?.quitting ?? true }) { [weak self] in self?.startServerIfNeeded() }
        }
    }

    func startChatServerIfNeeded() {
        Task {
            var r = URLRequest(url: URL(string: "\(Sisifo.chatBase)/health")!)
            r.timeoutInterval = 2
            if (try? await URLSession.shared.data(for: r)) != nil { return }
            serverChat = Sisifo.spawn("server-privado/server.mjs", log: "conversas", quitting: { [weak self] in self?.quitting ?? true }) { [weak self] in self?.startChatServerIfNeeded() }
        }
    }
}

// MARK: - atalhos globais

final class HotKeys {
    enum Key: UInt32 { case list = 2, window = 3 }
    nonisolated(unsafe) static var handler: ((Key) -> Void)?
    private var refs: [EventHotKeyRef?] = []

    init(_ h: @escaping (Key) -> Void) {
        HotKeys.handler = h
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if let k = HotKeys.Key(rawValue: id.id) { DispatchQueue.main.async { HotKeys.handler?(k) } }
            return noErr
        }, 1, &spec, nil, nil)
        let keys: [(Key, Int, Int)] = [(.list, kVK_ANSI_Z, optionKey), (.window, kVK_ANSI_Z, optionKey | shiftKey)]
        for (k, code, mods) in keys {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(code), UInt32(mods), EventHotKeyID(signature: OSType(0x5A415050), id: k.rawValue),
                                GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }
}
