import SwiftUI

// Insights da semana (25/11): pílula ao lado do "Hoje" + popover com entregas por dia, quem mais pediu,
// tempo até entregar e o que está parado. Dados do GET /semana do servidor (só as minhas demandas, 7 dias).

struct SemanaDia: Codable, Equatable { let dia: String; let feitas: Int; let chegaram: Int }
struct SemanaCliente: Codable, Equatable { let client: String; let n: Int; let jid: String?; let isGroup: Bool }
struct SemanaParada: Codable, Equatable { let id: String; let title: String; let client: String; let ts: Double?; let jid: String?; let isGroup: Bool }
struct SemanaInfo: Codable, Equatable {
    let porDia: [SemanaDia]
    let entregues: Int
    let chegaram: Int
    let autoFeitas: Int
    let medianaSeg: Double?
    let clientes: [SemanaCliente]
    let paradas: [SemanaParada]
}

final class SemanaModel: ObservableObject {
    @Published var info: SemanaInfo?
    @Published var aberto = false
    func carregar(_ store: Store) async {
        var r = URLRequest(url: URL(string: "/semana", relativeTo: store.base)!)
        r.timeoutInterval = 5
        guard let (d, _) = try? await URLSession.shared.data(for: r), let x = try? JSONDecoder().decode(SemanaInfo.self, from: d) else { return }
        await MainActor.run { if info != x { info = x } }
    }
}

struct ResumoSemana: View {
    @ObservedObject var store: Store
    @StateObject private var sm = SemanaModel()

    var body: some View {
        Button { sm.aberto.toggle() } label: { rotulo }
            .buttonStyle(.plain)
            .popover(isPresented: $sm.aberto, arrowEdge: .bottom) { InsightsSemana(store: store, info: sm.info) }
            // recarrega junto com o resto (lista muda = alguma coisa foi entregue ou chegou)
            .task(id: chave) { await sm.carregar(store) }
            .onChange(of: sm.aberto) { _, a in if a { Task { await sm.carregar(store) } } }
    }

    var chave: Int { let a: Int = store.doneToday.count; let b: Int = store.mine.count; return a + b * 1000 }

    var rotulo: some View {
        let dias = sm.info?.porDia ?? []
        let maxv = max(1, dias.map(\.feitas).max() ?? 1)
        return HStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(dias.enumerated()), id: \.offset) { k, d in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(k == dias.count - 1 ? Color.green : Color.green.opacity(0.45))
                        .frame(width: 3, height: max(2, 14 * CGFloat(d.feitas) / CGFloat(maxv)))
                }
            }
            .frame(height: 16, alignment: .bottom)
            (Text("\(sm.info?.entregues ?? 0)").fontWeight(.semibold) + Text(L(" na semana")).foregroundStyle(.secondary))
                .font(.system(size: 12)).monospacedDigit()
        }
        .padding(.horizontal, 11).frame(height: 30)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .contentShape(Capsule())
        .help(L("Insights da semana"))
        .fixedSize()
    }
}

struct InsightsSemana: View {
    @ObservedObject var store: Store
    let info: SemanaInfo?

    static func diaCurto(_ iso: String) -> String {
        let p = DateFormatter(); p.locale = Locale(identifier: "en_US_POSIX"); p.dateFormat = "yyyy-MM-dd"
        guard let d = p.date(from: iso) else { return "" }
        let f = DateFormatter(); f.locale = Locale(identifier: Idioma.ingles ? "en_US" : "pt_BR"); f.dateFormat = "EEEEE"
        return f.string(from: d).uppercased()
    }
    static func duracao(_ s: Double) -> String {
        let m = Int(s / 60)
        if m < 60 { return "\(max(1, m)) min" }
        let h = m / 60
        if h < 24 { return m % 60 >= 10 ? "\(h)h\(String(format: "%02d", m % 60))" : "\(h) h" }
        return "\(h / 24) d \(h % 24 > 0 ? "\(h % 24) h" : "")".trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Semana").font(.system(size: 15, weight: .bold))
            if let i = info {
                numeros(i)
                barras(i)
                if !i.clientes.isEmpty { clientes(i) }
                if !i.paradas.isEmpty { paradas(i) }
                BotaoRelatorio(store: store)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 24)
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }

    func numeros(_ i: SemanaInfo) -> some View {
        HStack(spacing: 8) {
            bloco("\(i.entregues)", L("entregues"), .green)
            bloco("\(i.chegaram)", L("chegaram"), .blue)
            bloco(i.medianaSeg.map { Self.duracao($0) } ?? "—", L("até entregar"), Mood.warm)
        }
    }
    func bloco(_ v: String, _ r: String, _ cor: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.system(size: 18, weight: .bold)).monospacedDigit().foregroundStyle(cor).lineLimit(1).minimumScaleFactor(0.7)
            Text(r).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    func barras(_ i: SemanaInfo) -> some View {
        let maxv = max(1, i.porDia.map { max($0.feitas, $0.chegaram) }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(i.porDia.enumerated()), id: \.offset) { k, d in
                    VStack(spacing: 4) {
                        HStack(alignment: .bottom, spacing: 2) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.blue.opacity(0.35))
                                .frame(width: 8, height: max(2, 60 * CGFloat(d.chegaram) / CGFloat(maxv)))
                            RoundedRectangle(cornerRadius: 2).fill(Color.green)
                                .frame(width: 8, height: max(2, 60 * CGFloat(d.feitas) / CGFloat(maxv)))
                        }
                        .frame(height: 60, alignment: .bottom)
                        .help("\(d.feitas) " + L("entregues") + " · \(d.chegaram) " + L("chegaram"))
                        Text(Self.diaCurto(d.dia)).font(.system(size: 10, weight: k == i.porDia.count - 1 ? .bold : .regular))
                            .foregroundStyle(k == i.porDia.count - 1 ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 12) {
                legenda(.green, L("entregues")); legenda(.blue.opacity(0.35), L("chegaram"))
                if i.autoFeitas > 0 { Text(L("\(i.autoFeitas) resolvidas sozinhas")).font(.system(size: 10.5)).foregroundStyle(.secondary) }
            }
        }
    }
    func legenda(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 6, height: 6); Text(t).font(.system(size: 10.5)).foregroundStyle(.secondary) }
    }

    func clientes(_ i: SemanaInfo) -> some View {
        let top = max(1, i.clientes.first?.n ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Quem mais pediu").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(i.clientes, id: \.client) { c in
                HStack(spacing: 8) {
                    ClientAvatar(url: store.avatarURL(c.jid ?? ""), name: c.client, isGroup: c.isGroup, size: 22)
                    Text(c.client).font(.system(size: 12.5)).lineLimit(1)
                    Spacer(minLength: 6)
                    Capsule().fill(Color.blue.opacity(0.35)).frame(width: 60 * CGFloat(c.n) / CGFloat(top), height: 5)
                    Text("\(c.n)").font(.system(size: 12, weight: .semibold)).monospacedDigit().frame(minWidth: 18, alignment: .trailing)
                }
            }
        }
    }

    func paradas(_ i: SemanaInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Parado há mais tempo").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(i.paradas, id: \.id) { p in
                HStack(spacing: 8) {
                    ClientAvatar(url: store.avatarURL(p.jid ?? ""), name: p.client, isGroup: p.isGroup, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.title).font(.system(size: 12.5)).lineLimit(1)
                        Text(p.client).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if let ts = p.ts { Text(Self.duracao(Date().timeIntervalSince1970 - ts)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Mood.warm).monospacedDigit() }
                }
            }
        }
    }
}

final class SaudacaoUI: ObservableObject { @Published var k = 0 }

// Saudação do topo (25/11): "Bom dia, Kevyn" pelo horário, trocando de idioma a cada 8 s.
struct Saudacao: View {
    static let nome: String = {
        let n = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return n.isEmpty ? NSUserName().capitalized : n
    }()
    // (manhã, tarde, noite)
    static let idiomas: [(String, String, String)] = [
        ("Bom dia", "Boa tarde", "Boa noite"),
        ("Good morning", "Good afternoon", "Good evening"),
        ("Buenos días", "Buenas tardes", "Buenas noches"),
        ("Bonjour", "Bon après-midi", "Bonsoir"),
        ("Buongiorno", "Buon pomeriggio", "Buonasera"),
        ("Guten Morgen", "Guten Tag", "Guten Abend"),
        ("Goedemorgen", "Goedemiddag", "Goedenavond"),
        ("Доброе утро", "Добрый день", "Добрый вечер"),
        ("おはよう", "こんにちは", "こんばんは"),
        ("좋은 아침", "안녕하세요", "좋은 저녁"),
        ("早上好", "下午好", "晚上好"),
        ("Καλημέρα", "Καλό απόγευμα", "Καλησπέρα"),
        ("Günaydın", "Tünaydın", "İyi akşamlar"),
        ("Dzień dobry", "Dzień dobry", "Dobry wieczór"),
        ("God morgon", "God eftermiddag", "God kväll"),
    ]
    @StateObject private var ui = SaudacaoUI()
    let timer = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    var body: some View {
        let h = Calendar.current.component(.hour, from: Date())
        let (m, t, n) = Self.idiomas[ui.k % Self.idiomas.count]
        let s = (5..<12).contains(h) ? m : (12..<18).contains(h) ? t : n
        Text("\(s), \(Self.nome)")
            .font(.system(size: 17, weight: .bold))
            .lineLimit(1)
            .id(ui.k)
            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .move(edge: .top).combined(with: .opacity)))
            .clipped()
            .onReceive(timer) { _ in withAnimation(.snappy(duration: 0.45)) { ui.k += 1 } }
            .onTapGesture { withAnimation(.snappy(duration: 0.45)) { ui.k += 1 } }
    }
}

final class RelatorioUI: ObservableObject { @Published var gerando = false }

/// "Gerar relatório em PDF" no fim do popover da semana
struct BotaoRelatorio: View {
    @ObservedObject var store: Store
    @StateObject private var ui = RelatorioUI()
    var body: some View {
        Button {
            guard !ui.gerando else { return }
            ui.gerando = true
            Task { @MainActor in await Relatorio.gerar(store); ui.gerando = false }
        } label: {
            HStack(spacing: 6) {
                if ui.gerando { ProgressView().controlSize(.mini) } else { Image(systemName: "doc.richtext") }
                Text(Idioma.ingles ? "Weekly report (PDF)" : "Gerar relatório em PDF").font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(Idioma.ingles ? "Saves a PDF of this week to Downloads" : "Salva um PDF da semana em Downloads, pra mandar pro gestor")
    }
}
