import AppKit

/// Atualização pelo GitHub Releases: confere 1x por dia, mostra no menu e, com um clique,
/// baixa o Sisifo.dmg, troca o app no mesmo lugar e reabre. Os dados ficam em Application Support.
@MainActor
final class Atualizacao {
    static let repo = "iKevyn/sisifo"
    var nova: (versao: String, dmg: URL)?
    var menuItem: NSMenuItem?
    var antesDeSair: (() -> Void)?
    private var timer: Timer?

    var versaoAtual: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    func iniciar() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in Task { await self?.conferir(avisar: false) } }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.conferir(avisar: false) }
        }
    }

    /// avisar = true quando a pessoa clicou em "Procurar atualização" (mostra "está atualizado" também)
    func conferir(avisar: Bool) async {
        var r = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        r.setValue("Sisifo/\(versaoAtual)", forHTTPHeaderField: "User-Agent")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.timeoutInterval = 15
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let tag = j["tag_name"] as? String else {
            if avisar { alerta(L("Não consegui atualizar"), "GitHub") }
            return
        }
        let versao = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = j["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }?["browser_download_url"] as? String
        if Self.maior(versao, que: versaoAtual), let dmg, let u = URL(string: dmg) {
            nova = (versao, u)
            menuItem?.title = L("Atualização disponível") + " (\(versao))"
            perguntar()
        } else if avisar {
            alerta(L("O Sísifo está atualizado"), "\(versaoAtual)")
        }
    }

    static func maior(_ a: String, que b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    func perguntar() {
        guard let nova else { return }
        let a = NSAlert()
        a.messageText = String(format: L("Sísifo %@ disponível"), nova.versao)
        a.informativeText = String(format: L("Tu tem a %@. Quer atualizar agora? Teus dados continuam onde estão."), versaoAtual)
        a.addButton(withTitle: L("Atualizar agora"))
        a.addButton(withTitle: L("Agora não"))
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { Task { await instalar() } }
    }

    @objc func clicouMenu() {
        if nova != nil { perguntar() } else { Task { await conferir(avisar: true) } }
    }

    func instalar() async {
        guard let nova else { return }
        menuItem?.title = L("Baixando atualização…")
        guard let (tmp, _) = try? await URLSession.shared.download(from: nova.dmg) else {
            alerta(L("Não consegui atualizar"), nova.dmg.absoluteString); return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sisifo-update-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dmg = dir.appendingPathComponent("Sisifo.dmg")
        try? FileManager.default.moveItem(at: tmp, to: dmg)
        let destino = Bundle.main.bundlePath
        let mnt = dir.appendingPathComponent("mnt").path
        // roda depois que o app fechar: monta o dmg, troca o app, desmonta e reabre
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
        mkdir -p '\(mnt)'
        hdiutil attach -nobrowse -readonly -mountpoint '\(mnt)' '\(dmg.path)' >/dev/null || exit 1
        NOVO=$(ls -d '\(mnt)'/*.app | head -1)
        if [ -n "$NOVO" ]; then
          rm -rf '\(destino).old'
          mv '\(destino)' '\(destino).old' && ditto "$NOVO" '\(destino)' && rm -rf '\(destino).old' || { rm -rf '\(destino)'; mv '\(destino).old' '\(destino)'; }
          xattr -cr '\(destino)' 2>/dev/null
        fi
        hdiutil detach '\(mnt)' -quiet
        open '\(destino)'
        """
        let sh = dir.appendingPathComponent("atualizar.sh")
        try? script.write(to: sh, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "nohup /bin/sh '\(sh.path)' >/dev/null 2>&1 &"]
        try? p.run()
        antesDeSair?()
        NSApp.terminate(nil)
    }

    private func alerta(_ t: String, _ s: String) {
        let a = NSAlert()
        a.messageText = t
        a.informativeText = s
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
