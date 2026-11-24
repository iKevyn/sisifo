import AppKit
import SwiftUI
import AVFoundation
import ServiceManagement
import UserNotifications

// MARK: - caminhos, portas e configuração

enum Sisifo {
    static let home: URL = {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Sisifo", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static let waData = home.appendingPathComponent("whatsapp", isDirectory: true)
    static let bridgePort = 47851
    static let appPort = 47852
    static let chatPort = 47853
    static let bridgeBase = "http://127.0.0.1:\(bridgePort)"
    static let appBase = "http://127.0.0.1:\(appPort)"
    static let chatBase = "http://127.0.0.1:\(chatPort)"

    /// node que vai dentro do app; se não tiver (rodando do código), usa o do sistema
    static var node: String? {
        if let b = Bundle.main.resourceURL?.appendingPathComponent("node/bin/node").path,
           FileManager.default.isExecutableFile(atPath: b) { return b }
        return ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var claude: String? {
        let h = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(h)/.local/bin/claude", "\(h)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var bridgeToken: String? {
        (try? String(contentsOf: waData.appendingPathComponent("token"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var env: [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["SISIFO_HOME"] = home.path
        e["SISIFO_WA_DATA"] = waData.path
        e["SISIFO_BRIDGE_PORT"] = "\(bridgePort)"
        e["SISIFO_PORT"] = "\(appPort)"
        e["SISIFO_CHAT_PORT"] = "\(chatPort)"
        e["WA_BRIDGE_PORT"] = "\(bridgePort)"
        if let c = claude { e["SISIFO_CLAUDE"] = c }
        e["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (e["PATH"] ?? "")
        return e
    }

    /// roda um script node do bundle com as variáveis do Sísifo; se cair, chama `restart` depois de 3 s
    @MainActor
    static func spawn(_ rel: String, log name: String, quitting: @escaping @MainActor () -> Bool,
                      restart: @escaping @MainActor () -> Void) -> Process? {
        guard let script = Bundle.main.resourceURL?.appendingPathComponent(rel),
              FileManager.default.fileExists(atPath: script.path), let node else { return nil }
        let logs = home.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let logURL = logs.appendingPathComponent("\(name).log")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        let fh = try? FileHandle(forWritingTo: logURL)
        fh?.seekToEndOfFile()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = ["--no-warnings", script.path]
        p.currentDirectoryURL = script.deletingLastPathComponent()
        p.environment = env
        p.standardOutput = fh
        p.standardError = fh
        p.terminationHandler = { _ in
            Task { @MainActor in
                guard !quitting() else { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                restart()
            }
        }
        try? p.run()
        return p
    }

    static func get(_ url: String, token: Bool = false) async -> Data? {
        guard let u = URL(string: url) else { return nil }
        var r = URLRequest(url: u)
        r.timeoutInterval = 3
        if token, let t = bridgeToken { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return d
    }
}

struct Pessoa: Codable, Hashable, Identifiable {
    var nome: String
    var numero: String
    var id: String { numero }
}

struct SisifoConfig: Codable {
    var nome: String = ""
    var papel: String = ""
    var equipe: [Pessoa] = []
    var onboarded: Bool = false

    static var url: URL { Sisifo.home.appendingPathComponent("config.json") }
    static func load() -> SisifoConfig {
        guard let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(SisifoConfig.self, from: d) else { return SisifoConfig() }
        return c
    }
    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(self) { try? d.write(to: Self.url, options: .atomic) }
    }
}

// MARK: - primeira abertura

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var passo = 0
    // Claude
    @Published var claudePath: String? = Sisifo.claude
    @Published var claudeEmail: String?
    @Published var claudeEntrando = false
    // WhatsApp
    @Published var qr: NSImage?
    @Published var zapConectado: String?
    // equipe e perfil
    @Published var nome = ""
    @Published var papel = ""
    @Published var contatos: [Pessoa] = []
    @Published var escolhidos: Set<String> = []
    @Published var busca = ""
    // permissões
    @Published var notificacoes = true
    @Published var microfone = false
    @Published var iniciarComMac = true

    var timer: Timer?
    var concluir: (() -> Void)?

    init() {
        let c = SisifoConfig.load()
        nome = c.nome
        papel = c.papel
        escolhidos = Set(c.equipe.map(\.numero))
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.atualizar() }
        }
        Task { await checarClaude() }
    }

    func atualizar() async {
        if passo == 1 && claudeEmail == nil { await checarClaude() }
        if passo == 2 {
            if let d = await Sisifo.get("\(Sisifo.bridgeBase)/status", token: true),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                if (j["connected"] as? Bool) == true {
                    let me = (j["me"] as? String ?? "").split(separator: "@").first.map { String($0.split(separator: ":").first ?? "") } ?? ""
                    zapConectado = me.isEmpty ? "conectado" : "+\(me)"
                    qr = nil
                } else if let png = await Sisifo.get("\(Sisifo.bridgeBase)/qr?t=\(Date().timeIntervalSince1970)", token: true) {
                    qr = NSImage(data: png)
                    zapConectado = nil
                }
            }
        }
        if passo == 3 && contatos.isEmpty {
            if let d = await Sisifo.get("\(Sisifo.bridgeBase)/contacts", token: true),
               let arr = try? JSONDecoder().decode([Pessoa].self, from: d) { contatos = arr }
        }
    }

    func checarClaude() async {
        claudePath = Sisifo.claude
        guard let c = claudePath else { return }
        let out = await Self.rodar(c, ["auth", "status", "--json"])
        if let d = out.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           (j["loggedIn"] as? Bool) == true {
            claudeEmail = (j["email"] as? String) ?? "conectado"
            claudeEntrando = false
        }
    }

    func entrarClaude() {
        guard let c = claudePath else { return }
        claudeEntrando = true
        // abre o login oficial no navegador; a tela fica conferindo o status sozinha
        Task.detached { _ = await Self.rodar(c, ["auth", "login", "--claudeai"], espera: 300) }
    }

    nonisolated static func rodar(_ cmd: String, _ args: [String], espera: TimeInterval = 15) async -> String {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cmd)
            p.arguments = args
            p.environment = Sisifo.env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            p.terminationHandler = { _ in
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: String(data: d, encoding: .utf8) ?? "")
            }
            do { try p.run() } catch { cont.resume(returning: ""); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + espera) { if p.isRunning { p.terminate() } }
        }
    }

    var podeSeguir: Bool {
        switch passo {
        case 1: return claudeEmail != nil
        case 2: return zapConectado != nil
        case 3: return !nome.trimmingCharacters(in: .whitespaces).isEmpty
        default: return true
        }
    }

    func seguir() {
        if passo == 4 { aplicarPermissoes() }
        if passo == 5 { salvar(); concluir?(); return }
        withAnimation(.snappy(duration: 0.3)) { passo += 1 }
    }
    func voltar() { withAnimation(.snappy(duration: 0.3)) { passo = max(0, passo - 1) } }

    func aplicarPermissoes() {
        if notificacoes { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in } }
        if microfone { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
        if iniciarComMac { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
    }

    func salvar() {
        var c = SisifoConfig.load()
        c.nome = nome.trimmingCharacters(in: .whitespaces)
        c.papel = papel.trimmingCharacters(in: .whitespaces)
        c.equipe = contatos.filter { escolhidos.contains($0.numero) }
        c.onboarded = true
        c.save()
        timer?.invalidate()
    }
}

@MainActor
final class OnboardingController {
    private var window: NSWindow?
    let model = OnboardingModel()

    func show(concluir: @escaping () -> Void) {
        model.concluir = { [weak self] in self?.window?.close(); self?.window = nil; concluir() }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: OnboardingView(m: model))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct Pedra: View {
    var size: CGFloat = 112
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
            .frame(width: size, height: size)
    }
}

struct OnboardingView: View {
    @ObservedObject var m: OnboardingModel
    let rotulos = ["Começar", "Continuar", "Continuar", "Continuar", "Continuar", "Abrir o Sísifo"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<6, id: \.self) { i in
                    Capsule().fill(i == m.passo ? Color.primary : Color.secondary.opacity(0.3))
                        .frame(width: i == m.passo ? 20 : 7, height: 7)
                }
            }
            .padding(.top, 16).frame(height: 40)
            ZStack {
                switch m.passo {
                case 0: boasVindas
                case 1: claude
                case 2: whatsapp
                case 3: equipe
                case 4: permissoes
                default: pronto
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 56)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            Divider()
            HStack {
                if m.passo > 0 { Button("Voltar") { m.voltar() }.controlSize(.large) }
                Spacer()
                Button(rotulos[m.passo]) { m.seguir() }
                    .keyboardShortcut(.defaultAction).controlSize(.large).buttonStyle(.borderedProminent)
                    .disabled(!m.podeSeguir)
            }
            .padding(.horizontal, 20).frame(height: 64)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        }
        .frame(width: 720, height: 540)
    }

    // 1
    var boasVindas: some View {
        VStack(spacing: 0) {
            Pedra().padding(.top, 18)
            Text("Boas-vindas ao Sísifo").font(.system(size: 26, weight: .bold)).padding(.top, 14)
            Text("Teus grupos de trabalho do WhatsApp, lidos e resumidos. O que pedem pra ti vira demanda, o resto tu só fica sabendo.")
                .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 470).padding(.top, 8)
            HStack(spacing: 12) {
                cartao("text.alignleft", .blue, "Resumo", "Cada conversa em uma linha.")
                cartao("checkmark", .green, "Demandas", "O que é pra ti, separado.")
                cartao("lock", .gray, "Tudo local", "Nada sai do teu Mac.")
            }
            .padding(.top, 24)
        }
    }
    func cartao(_ icone: String, _ cor: Color, _ t: String, _ s: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icone).font(.system(size: 17, weight: .semibold)).foregroundStyle(cor)
            Text(t).font(.system(size: 13, weight: .semibold)).padding(.top, 6)
            Text(s).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.08)))
    }

    // 2
    var claude: some View {
        VStack(spacing: 0) {
            Image(systemName: "asterisk").font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                .frame(width: 64, height: 64).background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color(red: 0.85, green: 0.47, blue: 0.34)))
                .padding(.top, 14)
            Text("Conectar o Claude").font(.system(size: 26, weight: .bold)).padding(.top, 14)
            Text("O Sísifo usa o Claude da tua assinatura pra ler e resumir. Ele roda pelo Claude Code, direto no teu Mac.")
                .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 470).padding(.top, 8)
            VStack(spacing: 0) {
                linha(icone: m.claudePath == nil ? "xmark" : "checkmark", cor: m.claudePath == nil ? .red : .green,
                      titulo: m.claudePath == nil ? "Claude Code não encontrado" : "Claude Code encontrado",
                      sub: m.claudePath ?? "Instala e volta aqui. A tela confere sozinha.") {
                    if m.claudePath == nil { Link("Como instalar", destination: URL(string: "https://claude.com/claude-code")!) }
                    else { Text("Instalado").font(.system(size: 12, weight: .semibold)).foregroundStyle(.green) }
                }
                Divider().padding(.leading, 56)
                linha(icone: "person", cor: .orange, titulo: "Tua conta",
                      sub: m.claudeEmail ?? (m.claudeEntrando ? "Termina o login no navegador…" : "Abre o login do Claude no navegador.")) {
                    if m.claudeEmail != nil { Text("Conectado").font(.system(size: 12, weight: .semibold)).foregroundStyle(.green) }
                    else if m.claudeEntrando { ProgressView().controlSize(.small) }
                    else { Button("Entrar com Claude") { m.entrarClaude() }.disabled(m.claudePath == nil) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.08)))
            .frame(maxWidth: 500).padding(.top, 22)
        }
    }
    func linha<T: View>(icone: String, cor: Color, titulo: String, sub: String, @ViewBuilder fim: () -> T) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icone).font(.system(size: 14, weight: .semibold)).foregroundStyle(cor)
                .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 8).fill(cor.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(titulo).font(.system(size: 13, weight: .semibold))
                Text(sub).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            fim()
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    // 3
    var whatsapp: some View {
        VStack(spacing: 0) {
            Text("Conectar o WhatsApp").font(.system(size: 26, weight: .bold)).padding(.top, 18)
            Text("Igual ao WhatsApp Web: o Sísifo vira um aparelho conectado na tua conta.")
                .font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 8)
            HStack(alignment: .center, spacing: 26) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white)
                        .shadow(color: .black.opacity(0.08), radius: 9, y: 4)
                    if let qr = m.qr {
                        Image(nsImage: qr).resizable().interpolation(.none).padding(8)
                    } else if m.zapConectado != nil {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(.green)
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 190, height: 190)
                VStack(alignment: .leading, spacing: 9) {
                    Text("1. Abre o WhatsApp no celular")
                    Text("2. Toca em **Configurações** e depois em **Aparelhos conectados**")
                    Text("3. Toca em **Conectar um aparelho**")
                    Text("4. Aponta a câmera pra este código")
                    Group {
                        if let z = m.zapConectado {
                            Label("Conectado como \(z)", systemImage: "circle.fill").foregroundStyle(.green)
                        } else {
                            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Esperando o celular…").foregroundStyle(.secondary) }
                        }
                    }
                    .font(.system(size: 12, weight: .semibold)).padding(.top, 6)
                }
                .font(.system(size: 13)).frame(maxWidth: 300, alignment: .leading)
            }
            .padding(.top, 20)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Essa conexão não é oficial do WhatsApp. Funciona como o WhatsApp Web, mas o WhatsApp pode limitar contas que usam apps assim. As mensagens ficam só no teu Mac.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12)).foregroundStyle(Color(red: 0.54, green: 0.33, blue: 0))
            .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
            .frame(maxWidth: 540).padding(.top, 18)
        }
    }

    // 4
    var equipe: some View {
        VStack(spacing: 0) {
            Text("Sobre ti e tua equipe").font(.system(size: 26, weight: .bold)).padding(.top, 14)
            Text("O Claude usa isso pra saber o que é contigo. Grupos onde a tua equipe fala viram **Trabalho**.")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 6)
            HStack(spacing: 10) {
                TextField("Teu nome", text: $m.nome).textFieldStyle(.roundedBorder).frame(width: 150)
                TextField("O que é contigo (ex: dev das lojas, design, tráfego)", text: $m.papel).textFieldStyle(.roundedBorder)
            }
            .frame(maxWidth: 520).padding(.top, 14)
            TextField("Buscar contato", text: $m.busca).textFieldStyle(.roundedBorder).frame(maxWidth: 520).padding(.top, 12)
            List {
                ForEach(m.contatos.filter { m.busca.isEmpty || $0.nome.localizedCaseInsensitiveContains(m.busca) }) { p in
                    Toggle(isOn: Binding(get: { m.escolhidos.contains(p.numero) },
                                         set: { v in if v { m.escolhidos.insert(p.numero) } else { m.escolhidos.remove(p.numero) } })) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(p.nome)
                            Text("+\(p.numero)").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .overlay { if m.contatos.isEmpty { Text("Carregando contatos dos teus grupos…").foregroundStyle(.secondary) } }
            .frame(maxWidth: 520, maxHeight: 190).clipShape(RoundedRectangle(cornerRadius: 10)).padding(.top, 8)
            Text("\(m.escolhidos.count) na equipe").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 6)
        }
    }

    // 5
    var permissoes: some View {
        VStack(spacing: 0) {
            Text("Só mais umas coisas").font(.system(size: 26, weight: .bold)).padding(.top, 22)
            Text("Pra avisar quando chega demanda e pra mandar áudio pelo app.")
                .font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 8)
            VStack(spacing: 0) {
                linha(icone: "bell", cor: .red, titulo: "Notificações", sub: "Avisa quando alguém te pede algo.") { Toggle("", isOn: $m.notificacoes).toggleStyle(.switch) }
                Divider().padding(.leading, 56)
                linha(icone: "mic", cor: .orange, titulo: "Microfone", sub: "Só quando tu grava um áudio.") { Toggle("", isOn: $m.microfone).toggleStyle(.switch) }
                Divider().padding(.leading, 56)
                linha(icone: "macwindow", cor: .blue, titulo: "Abrir ao iniciar o Mac", sub: "Pra não perder nada.") { Toggle("", isOn: $m.iniciarComMac).toggleStyle(.switch) }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.08)))
            .frame(maxWidth: 500).padding(.top, 22)
        }
    }

    // 6
    var pronto: some View {
        VStack(spacing: 0) {
            Pedra().padding(.top, 18)
            Text("Tudo certo").font(.system(size: 26, weight: .bold)).padding(.top, 14)
            Text("O Sísifo já está lendo as conversas. As primeiras demandas aparecem em alguns minutos.")
                .font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 470).padding(.top, 8)
            HStack(spacing: 10) {
                pilula("Claude conectado")
                pilula("WhatsApp conectado")
                pilula("\(m.escolhidos.count) na equipe")
            }
            .padding(.top, 22)
            Text("Abre o Sísifo de qualquer lugar com ⌥Z").font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 20)
        }
    }
    func pilula(_ t: String) -> some View {
        HStack(spacing: 6) { Circle().fill(.green).frame(width: 7, height: 7); Text(t).font(.system(size: 12, weight: .medium)) }
            .padding(.horizontal, 12).padding(.vertical, 7).background(Capsule().fill(Color.secondary.opacity(0.1)))
    }
}
