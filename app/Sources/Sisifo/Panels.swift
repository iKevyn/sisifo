import SwiftUI
import AppKit

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private func makePanel(key: Bool) -> NSPanel {
    let p: NSPanel = key
        ? KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        : NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = true
    p.level = .statusBar
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    p.hidesOnDeactivate = false
    return p
}

// MARK: - aviso de demanda nova (canto superior direito)

final class NotifModel: ObservableObject {
    @Published var demands: [Demand] = []
    @Published var hovering = false
}

struct NotifView: View {
    @ObservedObject var store: Store
    @ObservedObject var model: NotifModel
    var claude: (Demand) -> Void
    var later: () -> Void
    var notDemand: (Demand) -> Void
    var openList: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.demands.count == 1, let d = model.demands.first {
                HStack(alignment: .top, spacing: 11) {
                    ClientAvatar(url: store.avatarURL(d.jid), name: d.client, isGroup: d.isGroup, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(d.client)\(d.who.isEmpty ? "" : " · \(d.who) pediu")").font(.cute(11, .semibold)).foregroundStyle(.secondary).lineLimit(1)
                        Text(d.title).font(.cute(14, .bold)).fixedSize(horizontal: false, vertical: true)
                        if !d.detail.isEmpty { Text(d.detail).font(.cute(12)).foregroundStyle(.secondary).lineLimit(2) }
                        HStack(spacing: 5) {
                            DuePill(d: d)
                            if d.urgent { Pill(text: "urgente", symbol: "bolt.fill", tint: Mood.hot) }
                        }
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    ActionPill(text: "Claude Code", symbol: "sparkle", tint: Mood.claude, filled: true) { claude(d) }
                    ActionPill(text: "depois", symbol: "clock", action: later)
                    ActionPill(text: "não é demanda", symbol: "xmark", action: { notDemand(d) })
                }
            } else {
                HStack(spacing: 10) {
                    DaemonLogo(size: 34)
                    Text("\(model.demands.count) demandas novas").font(.cute(14, .bold))
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.demands.prefix(4)) { d in
                        HStack(spacing: 8) {
                            ClientAvatar(url: store.avatarURL(d.jid), name: d.client, isGroup: d.isGroup, size: 22)
                            Text(d.client).font(.cute(12, .semibold))
                            Text(d.title).font(.cute(12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                HStack(spacing: 6) {
                    ActionPill(text: "ver demandas", symbol: "tray.full", tint: Mood.calm, filled: true, action: openList)
                    ActionPill(text: "depois", symbol: "clock", action: later)
                }
            }
        }
        .padding(14)
        .frame(width: 370)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .onHover { model.hovering = $0 }
    }
}

@MainActor
final class NotifController {
    let store: Store
    let model = NotifModel()
    private var panel: NSPanel?
    private var hideAt = Date.distantFuture
    private var timer: Timer?
    var onClaude: ((Demand) -> Void)?
    var onOpenList: (() -> Void)?

    init(store: Store) { self.store = store }

    func show(_ new: [Demand]) {
        var list = model.demands
        for d in new where !list.contains(where: { $0.id == d.id }) { list.append(d) }
        model.demands = list
        let p = panel ?? build()
        layout(p)
        if !p.isVisible {
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.22; p.animator().alphaValue = 1 }
        }
        hideAt = Date().addingTimeInterval(14)
        NSSound(named: "Pop")?.play()
    }

    func hide() {
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 }, completionHandler: { [weak self] in
            p.orderOut(nil)
            MainActor.assumeIsolated { self?.model.demands = [] }
        })
    }

    private func layout(_ p: NSPanel) {
        guard let v = p.contentView, let s = NSScreen.main else { return }
        let size = v.fittingSize
        p.setContentSize(size)
        p.setFrameOrigin(NSPoint(x: s.visibleFrame.maxX - size.width - 12, y: s.visibleFrame.maxY - size.height - 10))
    }

    private func build() -> NSPanel {
        let p = makePanel(key: false)
        let view = NotifView(store: store, model: model,
            claude: { [weak self] d in self?.hide(); self?.onClaude?(d) },
            later: { [weak self] in self?.hide() },
            notDemand: { [weak self] d in self?.store.ignore(d); self?.hide() },
            openList: { [weak self] in self?.hide(); self?.onOpenList?() })
        let host = NSHostingView(rootView: view)
        p.contentView = host
        panel = p
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.panel, p.isVisible else { return }
                if self.model.hovering { self.hideAt = Date().addingTimeInterval(4) }
                else if Date() > self.hideAt { self.hide() }
                self.layout(p)
            }
        }
        return p
    }
}

// MARK: - prévia do que vai pro Claude Code

final class SheetModel: ObservableObject {
    @Published var face: Demand?
    @Published var title = ""
    @Published var subtitle = ""
    @Published var text = ""
}

struct ClaudeSheet: View {
    @ObservedObject var store: Store
    @ObservedObject var model: SheetModel
    var go: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let d = model.face {
                HStack(spacing: 10) {
                    ClientAvatar(url: store.avatarURL(d.jid), name: d.client, isGroup: d.isGroup, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L(model.title)).font(.cute(14, .bold))
                        Text(L(model.subtitle)).font(.cute(11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                }
            }
            TextEditor(text: $model.text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(height: 210)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
            Text("Dá pra editar antes. Vou abrir o Claude Code no Terminal já com esse pedido.")
                .font(.cute(11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancelar", action: cancel).keyboardShortcut(.cancelAction).controlSize(.large)
                Button(action: go) {
                    Label("Abrir no Claude Code", systemImage: "sparkle")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent).tint(Mood.claude).controlSize(.large)
            }
        }
        .padding(16)
        .frame(width: 540)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

@MainActor
final class ClaudeController {
    let store: Store
    let model = SheetModel()
    private var panel: NSPanel?
    let toast = Toast()

    init(store: Store) { self.store = store }

    func open(_ d: Demand) {
        present(face: d, title: "Mandar pro Claude Code", subtitle: "\(d.client) · \(d.title)") { await self.store.prompt(for: d) }
    }

    func open(client g: ClientGroup) {
        let n = g.demands.count
        present(face: g.face, title: "Mandar tudo do \(g.name) pro Claude Code",
                subtitle: n == 1 ? "1 demanda" : "\(n) demandas num pedido só") { await self.store.prompt(forClient: g.name) }
    }

    private func present(face: Demand, title: String, subtitle: String, text: @escaping () async -> String) {
        model.face = face
        model.title = title
        model.subtitle = subtitle
        model.text = ""
        Task {
            model.text = await text()
            let p = panel ?? build()
            if let v = p.contentView, let s = NSScreen.main {
                p.setContentSize(v.fittingSize)
                p.setFrameOrigin(NSPoint(x: s.frame.midX - p.frame.width / 2, y: s.visibleFrame.midY - p.frame.height / 2 + 80))
            }
            p.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func build() -> NSPanel {
        let p = makePanel(key: true)
        p.contentView = NSHostingView(rootView: ClaudeSheet(store: store, model: model,
            go: { [weak self] in self?.go() },
            cancel: { [weak self] in self?.panel?.orderOut(nil) }))
        panel = p
        return p
    }

    private func go() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(model.text, forType: .string)
        panel?.orderOut(nil)
        // abre o Terminal já rodando o Claude Code com o pedido (arquivo .command temporário)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sisifo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let prompt = dir.appendingPathComponent("pedido-\(Int(Date().timeIntervalSince1970)).txt")
        let cmd = dir.appendingPathComponent("claude-\(Int(Date().timeIntervalSince1970)).command")
        try? model.text.write(to: prompt, atomically: true, encoding: .utf8)
        let script = """
        #!/bin/zsh -l
        cd ~
        CLAUDE=$(command -v claude || ls ~/.local/bin/claude ~/.claude/local/claude /opt/homebrew/bin/claude /usr/local/bin/claude 2>/dev/null | head -1)
        if [ -z "$CLAUDE" ]; then echo "Claude Code não encontrado. Instala em https://claude.com/claude-code"; exit 1; fi
        "$CLAUDE" "$(cat '\(prompt.path)')"
        """
        try? script.write(to: cmd, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cmd.path)
        NSWorkspace.shared.open(cmd)
        toast.show(L("Abrindo o Claude Code no Terminal"))
    }
}

// MARK: - toast

@MainActor
final class Toast {
    private var panel: NSPanel?
    private var work: DispatchWorkItem?

    func show(_ text: String) {
        let view = HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Mood.calm)
            Text(L(text)).font(.cute(13, .semibold))
        }
        .padding(.horizontal, 16).frame(height: 40)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .fixedSize()
        let p = panel ?? { let x = makePanel(key: false); x.ignoresMouseEvents = true; panel = x; return x }()
        let host = NSHostingView(rootView: view)
        p.contentView = host
        p.setContentSize(host.fittingSize)
        if let s = NSScreen.main {
            p.setFrameOrigin(NSPoint(x: s.frame.midX - p.frame.width / 2, y: s.visibleFrame.minY + 90))
        }
        p.alphaValue = 1
        p.orderFrontRegardless()
        work?.cancel()
        let w = DispatchWorkItem { [weak p] in
            guard let p else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
        }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: w)
    }
}
