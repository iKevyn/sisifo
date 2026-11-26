import SwiftUI

// Saúde da ponte do WhatsApp (25/11): bolinha no cabeçalho + aviso com motivo da queda e botão de reconectar.
// Os dados vêm do /status da ponte, repassados pelo servidor em /demands (campo "ponte").

struct PonteQueda: Codable, Equatable { let at: Double; let code: Int?; let motivo: String; let msg: String? }
struct PonteSono: Codable, Equatable { let de: Double; let ate: Double }
struct PonteInfo: Codable, Equatable {
    var connected: Bool? = nil
    var since: Double? = nil
    var lastRx: Double? = nil
    var heartbeat: Double? = nil
    var ultimaQueda: PonteQueda? = nil
    var ultimoSono: PonteSono? = nil
    var semResposta: Bool? = nil
}

enum PonteEstado { case ok, quieta, fora }

extension Store {
    /// quieta = conectada mas sem nenhuma mensagem há muito tempo em horário comercial (cara de ponte zumbi)
    var ponteEstado: PonteEstado {
        if !connected { return .fora }
        if let rx = ponte?.lastRx, let since = ponte?.since {
            let agora = Date().timeIntervalSince1970
            let h = Calendar.current.component(.hour, from: Date())
            let base = max(rx, since)
            if (8...21).contains(h) && agora - base > 45 * 60 { return .quieta }
        }
        return .ok
    }

    static func hora(_ t: Double) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = Calendar.current.isDateInToday(Date(timeIntervalSince1970: t)) ? "HH:mm" : "dd/MM HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }
    static func ha(_ t: Double) -> String {
        let m = Int((Date().timeIntervalSince1970 - t) / 60)
        return m < 1 ? "agora" : m < 60 ? "há \(m) min" : "há \(m / 60)h\(m % 60 > 0 ? String(format: "%02d", m % 60) : "")"
    }

    var ponteResumo: String {
        switch ponteEstado {
        case .fora:
            if ponte?.semResposta == true { return "Ponte do WhatsApp não responde" }
            if let q = ponte?.ultimaQueda { return "WhatsApp caiu às \(Self.hora(q.at)) · \(q.motivo)" }
            return "Ponte do WhatsApp fora"
        case .quieta:
            return "Conectado, mas nenhuma mensagem \(ponte?.lastRx.map { Self.ha($0) } ?? "faz tempo")"
        case .ok:
            return ponte?.since.map { "WhatsApp conectado desde \(Self.hora($0))" } ?? "WhatsApp conectado"
        }
    }

    /// derruba e sobe a ponte de novo (launchctl kickstart -k): reconecta e puxa o que ficou pra trás
    func reconectarPonte() {
        guard !ponteReconectando else { return }
        ponteReconectando = true
        Task.detached {
            let ok = AppDelegate.launchctl(["kickstart", "-k", AppDelegate.launchdBridgeJob]) == 0
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            await MainActor.run {
                self.ponteReconectando = false
                if !ok { self.ponteErro = "Não consegui reiniciar a ponte (launchd)" }
            }
            await self.refresh()
        }
    }
}

/// bolinha no cabeçalho: verde ok, amarela quieta demais, vermelha fora. Clique = detalhes + forçar resync.
final class PonteUI: ObservableObject { @Published var aberto = false }
struct PonteDot: View {
    @ObservedObject var store: Store
    @StateObject private var ui = PonteUI()
    var body: some View {
        let e = store.ponteEstado
        let cor: Color = e == .ok ? .green : e == .quieta ? .yellow : .red
        Button { ui.aberto.toggle() } label: {
            ZStack {
                if store.ponteReconectando { ProgressView().controlSize(.mini) }
                else { Circle().fill(cor).frame(width: 8, height: 8) }
            }
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L(store.ponteResumo))
        .popover(isPresented: $ui.aberto, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(cor).frame(width: 8, height: 8)
                    Text(L(store.ponteResumo)).font(.cute(12, .semibold))
                }
                if let rx = store.ponte?.lastRx { Text(L("Última mensagem recebida \(Store.ha(rx))")).font(.cute(11)).foregroundStyle(.secondary) }
                if let q = store.ponte?.ultimaQueda {
                    Text(L("Última queda: \(Store.hora(q.at)) · \(q.motivo)\(q.code.map { " (\($0))" } ?? "")"))
                        .font(.cute(11)).foregroundStyle(.secondary)
                }
                if let err = store.ponteErro { Text(err).font(.cute(11)).foregroundStyle(.red) }
                Button {
                    store.reconectarPonte()
                } label: {
                    HStack(spacing: 6) {
                        if store.ponteReconectando { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                        Text(L(store.ponteReconectando ? "Reconectando…" : "Forçar resync agora"))
                    }
                    .font(.cute(11.5, .semibold))
                    .padding(.horizontal, 12).frame(height: 26)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .disabled(store.ponteReconectando)
                .padding(.top, 4)
            }
            .padding(14)
            .frame(minWidth: 260, alignment: .leading)
        }
    }
}

/// aviso quando a ponte caiu (ou está quieta demais), com o motivo e o botão de reconectar
struct PonteAviso: View {
    @ObservedObject var store: Store
    var body: some View {
        let e = store.ponteEstado
        if e != .ok {
            HStack(spacing: 8) {
                Image(systemName: e == .fora ? "wifi.exclamationmark" : "moon.zzz").foregroundStyle(Mood.warm)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(store.ponteResumo)).font(.cute(11.5, .medium))
                    Text(L(e == .fora ? "O que chegar aparece quando ela voltar." : "Se achar estranho, força o resync."))
                        .font(.cute(10.5)).foregroundStyle(.secondary)
                    if let err = store.ponteErro { Text(err).font(.cute(10.5)).foregroundStyle(.red) }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    store.reconectarPonte()
                } label: {
                    if store.ponteReconectando { ProgressView().controlSize(.mini) }
                    else { Text(L("Reconectar")).font(.cute(11, .semibold)) }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .disabled(store.ponteReconectando)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Mood.warm.opacity(0.1)))
        }
    }
}
