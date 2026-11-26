import SwiftUI
import AppKit

// Relatório semanal em PDF (26/11): os números da semana pra mostrar pro gestor, na cara do Sísifo.
// Dados do GET /relatorio do servidor; páginas A4 desenhadas em SwiftUI e gravadas como PDF vetorial
// (ImageRenderer → CGContext de PDF). Salva em ~/Downloads e abre no Preview.

struct RelDia: Codable { let dia: String; let chegaram: Int; let feitas: Int; let foraHorario: Int
    let jornadaIni: String?; let jornadaFim: String?; let jornadaSeg: Double?; let ativoSeg: Double?; let enviadas: Int }
struct RelCliente: Codable { let client: String; let pedidos: Int; let entregues: Int; let abertas: Int; let urgentes: Int
    let foraHorario: Int; let medianaSeg: Double?; let grandes: Int?; let jid: String?; let isGroup: Bool }
struct RelItem: Codable, Identifiable { let id: String; let title: String; let client: String; let who: String?; let ts: Double
    let doneAt: Double?; let urgent: Bool; let autoDone: Bool; let size: String?; let jid: String?; let isGroup: Bool; let espera: String?; let doing: String? }
struct RelMsgs: Codable { let recebidas: Int; let enviadas: Int; let enviadasFora: Int; let conversas: Int }
struct RelAnterior: Codable { let entregues: Int; let chegaram: Int; let medianaSeg: Double? }
struct RelOutras: Codable { let total: Int; let porArea: [String: Int] }
struct RelInfo: Codable {
    let nome: String; let geradoEm: Double; let ini: String; let fim: String
    let entregues: Int; let chegaram: Int; let autoFeitas: Int; let medianaSeg: Double?
    let urgentes: Int; let comPrazo: Int; let foraHorario: Int; let entreguesFora: Int
    let porTamanho: [String: Int]?; let tempoPorTamanho: [String: Double?]?; let ativoTotalSeg: Double?
    let pico: Int; let picoEm: Double?; let clientesAtendidos: Int
    let mensagens: RelMsgs; let anterior: RelAnterior
    let abertasAgora: Int; let aguardandoCliente: Int; let outrasAreas: RelOutras
    let porDia: [RelDia]; let porHora: [Int]; let clientes: [RelCliente]
    let entregas: [RelItem]; let abertas: [RelItem]
}

private func tr(_ pt: String, _ en: String) -> String { Idioma.ingles ? en : pt }

enum Relatorio {
    static let A4 = CGSize(width: 595, height: 842)

    /// busca os dados, desenha e abre o PDF. Devolve o caminho (ou nil se o servidor não respondeu).
    @MainActor @discardableResult
    static func gerar(_ store: Store, dias: Int = 7) async -> URL? {
        var r = URLRequest(url: URL(string: "/relatorio?dias=\(dias)", relativeTo: store.base)!)
        r.timeoutInterval = 20
        guard let (d, _) = try? await URLSession.shared.data(for: r),
              let info = try? JSONDecoder().decode(RelInfo.self, from: d) else {
            let a = NSAlert(); a.messageText = tr("Não consegui gerar o relatório", "Couldn't build the report")
            a.informativeText = tr("O servidor de demandas não respondeu. Tenta de novo em alguns segundos.", "The tasks server didn't answer. Try again in a few seconds.")
            a.runModal(); return nil
        }
        // fotos dos clientes antes de desenhar (ImageRenderer não espera AsyncImage)
        var jids = Set(info.clientes.compactMap(\.jid))
        for i in info.entregas + info.abertas { if let j = i.jid { jids.insert(j) } }
        var fotos: [String: NSImage] = [:]
        let urls = Dictionary(uniqueKeysWithValues: jids.map { ($0, store.avatarURL($0)) })
        await withTaskGroup(of: (String, NSImage?).self) { g in
            for (j, u) in urls {
                g.addTask {
                    var q = URLRequest(url: u); q.timeoutInterval = 4
                    guard let (b, resp) = try? await URLSession.shared.data(for: q), (resp as? HTTPURLResponse)?.statusCode == 200 else { return (j, nil) }
                    return (j, NSImage(data: b))
                }
            }
            for await (j, img) in g { if let img { fotos[j] = img } }
        }
        let ctx = RelCtx(info: info, fotos: fotos, icone: NSApp.applicationIconImage)
        let paginas = ctx.paginas()
        let pasta = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let nomeArq = tr("Sísifo - Relatório semanal \(ctx.periodoCurto).pdf", "Sisifo - Weekly report \(ctx.periodoCurto).pdf")
            .replacingOccurrences(of: "/", with: "-")
        let url = pasta.appendingPathComponent(nomeArq)
        var caixa = CGRect(origin: .zero, size: A4)
        guard let pdf = CGContext(url as CFURL, mediaBox: &caixa, [kCGPDFContextTitle as String: nomeArq, kCGPDFContextCreator as String: "Sísifo"] as CFDictionary) else { return nil }
        for (n, p) in paginas.enumerated() {
            let pag = RelPagina(ctx: ctx, n: n + 1, total: paginas.count) { p }
                .frame(width: A4.width, height: A4.height)
                .environment(\.colorScheme, .light)
            let rr = ImageRenderer(content: pag)
            rr.proposedSize = ProposedViewSize(A4)
            rr.render { _, desenha in
                pdf.beginPDFPage(nil)
                desenha(pdf)
                pdf.endPDFPage()
            }
        }
        pdf.closePDF()
        NSWorkspace.shared.open(url)
        return url
    }
}

// MARK: - contexto (formatação + paginação)

struct RelCtx {
    let info: RelInfo
    let fotos: [String: NSImage]
    let icone: NSImage

    static let paper = Color.white
    static let card = Color(white: 0.955)
    static let tinta = Color(white: 0.10)
    static let cinza = Color(white: 0.45)
    static let linha = Color(white: 0.88)
    static let azul = Color(red: 0.22, green: 0.48, blue: 0.95)
    static let roxo = Color(red: 0.40, green: 0.36, blue: 0.90)

    var loc: Locale { Locale(identifier: Idioma.ingles ? "en_US" : "pt_BR") }
    func data(_ iso: String) -> Date? {
        let p = DateFormatter(); p.locale = Locale(identifier: "en_US_POSIX"); p.dateFormat = "yyyy-MM-dd"
        p.timeZone = TimeZone(identifier: "America/Sao_Paulo"); return p.date(from: iso)
    }
    func fmt(_ d: Date, _ f: String) -> String {
        let x = DateFormatter(); x.locale = loc; x.timeZone = TimeZone(identifier: "America/Sao_Paulo"); x.setLocalizedDateFormatFromTemplate(f); return x.string(from: d)
    }
    func fmtFixo(_ d: Date, _ f: String) -> String {
        let x = DateFormatter(); x.locale = loc; x.timeZone = TimeZone(identifier: "America/Sao_Paulo"); x.dateFormat = f; return x.string(from: d)
    }
    var periodo: String {
        guard let a = data(info.ini), let b = data(info.fim) else { return "\(info.ini) – \(info.fim)" }
        let mesA = fmtFixo(a, "MMMM"), mesB = fmtFixo(b, "MMMM"), ano = fmtFixo(b, "yyyy")
        let da = fmtFixo(a, "d"), db = fmtFixo(b, "d")
        if Idioma.ingles { return mesA == mesB ? "\(mesA.capitalized) \(da) – \(db), \(ano)" : "\(mesA.capitalized) \(da) – \(mesB.capitalized) \(db), \(ano)" }
        return mesA == mesB ? "\(da) a \(db) de \(mesA) de \(ano)" : "\(da) de \(mesA) a \(db) de \(mesB) de \(ano)"
    }
    var periodoCurto: String {
        guard let a = data(info.ini), let b = data(info.fim) else { return info.fim }
        return "\(fmtFixo(a, "dd.MM")) a \(fmtFixo(b, "dd.MM"))".replacingOccurrences(of: " a ", with: Idioma.ingles ? " to " : " a ")
    }
    func diaSemana(_ iso: String) -> String { data(iso).map { fmtFixo($0, "EEE").replacingOccurrences(of: ".", with: "").capitalized } ?? "" }
    func diaMes(_ iso: String) -> String { data(iso).map { fmtFixo($0, "dd/MM") } ?? "" }
    func hora(_ ts: Double) -> String { fmtFixo(Date(timeIntervalSince1970: ts), "HH:mm") }
    func diaHora(_ ts: Double) -> String { fmtFixo(Date(timeIntervalSince1970: ts), Idioma.ingles ? "EEE HH:mm" : "EEE HH:mm").replacingOccurrences(of: ".", with: "").capitalized }
    func isoDia(_ ts: Double) -> String { fmtFixo(Date(timeIntervalSince1970: ts), "yyyy-MM-dd") }

    static func duracao(_ s: Double?) -> String {
        guard let s else { return "—" }
        let m = Int(s / 60)
        if m < 60 { return "\(max(1, m)) min" }
        let h = m / 60
        if h < 24 { return m % 60 >= 10 ? "\(h)h\(String(format: "%02d", m % 60))" : "\(h) h" }
        let d = h / 24, r = h % 24
        return r > 0 ? "\(d) d \(r) h" : "\(d) d"
    }
    static let tamanhos: [(String, String, String, Color)] = [
        ("grande", "grandes", "large", Color(red: 0.40, green: 0.36, blue: 0.90)),
        ("media", "médias", "medium", Color(red: 0.22, green: 0.48, blue: 0.95)),
        ("rapida", "rápidas", "quick", Color(white: 0.62)),
    ]
    static func tamCor(_ t: String?) -> Color { tamanhos.first { $0.0 == (t ?? "media") }?.3 ?? .gray }
    static func tamNome(_ t: String?) -> String {
        switch t ?? "media" { case "grande": return tr("grande", "large"); case "rapida": return tr("rápida", "quick"); default: return tr("média", "medium") }
    }
    func qtd(_ t: String) -> Int { info.porTamanho?[t] ?? 0 }
    static func horas(_ s: Double) -> String { let m = Int(s / 60); return "\(m / 60)h\(String(format: "%02d", m % 60))" }
    static func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "0%" : "\(Int((Double(a) / Double(b) * 100).rounded()))%" }

    var diasUteis: Int {
        info.porDia.filter { d in
            guard let x = data(d.dia) else { return true }
            let w = Calendar(identifier: .gregorian).component(.weekday, from: x); return w != 1 && w != 7
        }.count
    }
    var porDiaUtil: String {
        let n = max(1, diasUteis); let v = Double(info.chegaram) / Double(n)
        return v >= 10 ? "\(Int(v.rounded()))" : String(format: "%.1f", v).replacingOccurrences(of: ".", with: Idioma.ingles ? "." : ",")
    }
    var diaMaisLongo: RelDia? { info.porDia.filter { $0.jornadaSeg != nil }.max { ($0.jornadaSeg ?? 0) < ($1.jornadaSeg ?? 0) } }
    var diasDepoisDas20: Int { info.porDia.filter { d in guard let f = d.jornadaFim, let h = Int(f.prefix(2)) else { return false }; return h >= 20 || h < 5 }.count }

    // linhas da lista de entregas (cabeçalho de dia + itens), repartidas em páginas
    enum Linha: Identifiable { case dia(String, Int), item(RelItem)
        var id: String { switch self { case .dia(let d, _): return "d" + d; case .item(let i): return i.id } }
        var peso: Double { switch self { case .dia: return 1.5; case .item(let i): return i.title.count > 60 ? 1.35 : 1 } }
    }
    func paginasEntregas(primeira: Double = 22.5) -> [[Linha]] {
        var linhas: [Linha] = []
        var porDia: [String: [RelItem]] = [:]
        for i in info.entregas { porDia[isoDia(i.doneAt ?? i.ts), default: []].append(i) }
        for d in porDia.keys.sorted(by: >) {
            let l = porDia[d]!.sorted { ($0.doneAt ?? 0) > ($1.doneAt ?? 0) }
            linhas.append(.dia(d, l.count)); linhas += l.map { .item($0) }
        }
        var pags: [[Linha]] = []; var cur: [Linha] = []; var peso = 0.0
        for l in linhas {
            let cap = pags.isEmpty ? primeira : 27.0
            if peso + l.peso > cap || (cur.count > 0 && peso + l.peso + 1 > cap && { if case .dia = l { return true }; return false }()) {
                pags.append(cur); cur = []; peso = 0
            }
            cur.append(l); peso += l.peso
        }
        if !cur.isEmpty { pags.append(cur) }
        return pags
    }

    func paginas() -> [AnyView] {
        var p: [AnyView] = [AnyView(RelResumo(c: self)), AnyView(RelDetalhe(c: self))]
        let ent = paginasEntregas()
        for (k, l) in ent.enumerated() { p.append(AnyView(RelEntregas(c: self, linhas: l, continua: k > 0))) }
        return p
    }
}

// MARK: - moldura da página

struct RelPagina<Conteudo: View>: View {
    let ctx: RelCtx; let n: Int; let total: Int
    @ViewBuilder let conteudo: () -> Conteudo
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            conteudo()
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Image(nsImage: ctx.icone).resizable().frame(width: 12, height: 12)
                Text(tr("Sísifo · gerado das conversas do WhatsApp, sem preenchimento manual", "Sisifo · built from WhatsApp conversations, no manual input"))
                Spacer()
                Text("\(ctx.info.nome) · \(ctx.periodoCurto) · \(n)/\(total)").monospacedDigit()
            }
            .font(.system(size: 7.5)).foregroundStyle(RelCtx.cinza)
            .padding(.top, 8)
            .overlay(alignment: .top) { Rectangle().fill(RelCtx.linha).frame(height: 0.5) }
        }
        .padding(.horizontal, 36).padding(.top, 34).padding(.bottom, 22)
        .foregroundStyle(RelCtx.tinta)
        .background(RelCtx.paper)
    }
}

struct RelAvatar: View {
    let c: RelCtx; let jid: String?; let nome: String; var size: CGFloat = 18
    var body: some View {
        Group {
            if let j = jid, let img = c.fotos[j] {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(ClientAvatar.color(for: nome))
                    Text(String(nome.prefix(1)).uppercased()).font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size).clipShape(Circle())
    }
}

struct RelTitulo: View {
    let texto: String; var sub: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(texto).font(.system(size: 12.5, weight: .bold))
            if let sub { Text(sub).font(.system(size: 9.5)).foregroundStyle(RelCtx.cinza) }
        }
    }
}

struct RelCartao<C: View>: View {
    var pad: CGFloat = 12
    var cheio = false
    @ViewBuilder let c: () -> C
    var body: some View {
        c().padding(pad).frame(maxWidth: .infinity, maxHeight: cheio ? .infinity : nil, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(RelCtx.card))
    }
}

// MARK: - página 1: a semana numa olhada

struct RelResumo: View {
    let c: RelCtx
    var i: RelInfo { c.info }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            cabecalho
            frase
            numeros
            tamanho
            grafico
            HStack(alignment: .top, spacing: 10) { foraDoHorario; pressa; mensagens }.fixedSize(horizontal: false, vertical: true)
        }
    }

    var cabecalho: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: c.icone).resizable().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Relatório da semana", "Weekly report")).font(.system(size: 22, weight: .bold))
                Text("\(i.nome) · \(c.periodo)").font(.system(size: 11)).foregroundStyle(RelCtx.cinza)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Sísifo").font(.system(size: 11, weight: .semibold))
                Text(tr("gerado ", "generated ") + c.diaHora(i.geradoEm)).font(.system(size: 9)).foregroundStyle(RelCtx.cinza)
            }
        }
    }

    var frase: some View {
        let a = Text(tr("Chegaram ", "")) + Text("\(i.chegaram)").foregroundColor(RelCtx.azul).bold()
            + Text(tr(" demandas em \(i.porDia.count) dias, ", " tasks came in over \(i.porDia.count) days, "))
            + Text(tr("cerca de \(c.porDiaUtil) por dia útil. ", "about \(c.porDiaUtil) per workday. "))
        let b = Text("\(i.entregues)").foregroundColor(Mood.calm).bold() + Text(tr(" foram entregues", " were delivered"))
            + Text(c.qtd("grande") > 0 ? tr(", \(c.qtd("grande")) delas grandes,", ", \(c.qtd("grande")) of them large,") : "")
            + Text(i.abertasAgora > 0 ? tr(" e \(i.abertasAgora) seguem abertas.", " and \(i.abertasAgora) are still open.") : tr(" e nada ficou pra trás.", " and nothing is left behind."))
        return (a + b).font(.system(size: 15.5, weight: .medium)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }

    func delta(_ agora: Int, _ antes: Int) -> String? {
        guard antes > 0 else { return nil }
        return tr("semana anterior: \(antes)", "last week: \(antes)")
    }

    var numeros: some View {
        HStack(spacing: 8) {
            bloco("\(i.entregues)", tr("entregues", "delivered"), Mood.calm, delta(i.entregues, i.anterior.entregues))
            bloco("\(i.chegaram)", tr("chegaram", "came in"), RelCtx.azul, delta(i.chegaram, i.anterior.chegaram))
            bloco(RelCtx.duracao(i.medianaSeg), tr("do pedido à entrega", "from ask to delivery"), Mood.warm, tr("mediana", "median"))
            bloco("\(i.pico)", tr("abertas ao mesmo tempo", "open at the same time"), Mood.hot, i.picoEm.map { tr("pico ", "peak ") + c.diaHora($0) })
        }
    }
    func bloco(_ v: String, _ r: String, _ cor: Color, _ nota: String?) -> some View {
        RelCartao(pad: 11) {
            VStack(alignment: .leading, spacing: 2) {
                Text(v).font(.system(size: 24, weight: .bold)).monospacedDigit().foregroundStyle(cor).lineLimit(1).minimumScaleFactor(0.6)
                Text(r).font(.system(size: 9.5, weight: .medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let nota { Text(nota).font(.system(size: 8)).foregroundStyle(RelCtx.cinza).lineLimit(1).minimumScaleFactor(0.8) }
            }
            .frame(height: 74, alignment: .topLeading)
        }
    }

    var tamanho: some View {
        let total = max(1, RelCtx.tamanhos.map { c.qtd($0.0) }.reduce(0, +))
        return RelCartao(pad: 14) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    RelTitulo(texto: tr("Tamanho do que foi entregue", "Size of what was delivered"),
                              sub: tr("esforço estimado pela IA a partir do pedido", "effort estimated by AI from the request"))
                    Spacer()
                }
                GeometryReader { g in
                    HStack(spacing: 3) {
                        ForEach(RelCtx.tamanhos, id: \.0) { t in
                            let n = c.qtd(t.0)
                            if n > 0 {
                                RoundedRectangle(cornerRadius: 4).fill(t.3)
                                    .frame(width: max(4, (g.size.width - 6) * CGFloat(n) / CGFloat(total)))
                            }
                        }
                    }
                }
                .frame(height: 10)
                HStack(spacing: 8) {
                    ForEach(RelCtx.tamanhos, id: \.0) { t in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(c.qtd(t.0))").font(.system(size: 20, weight: .bold)).monospacedDigit().foregroundStyle(t.3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tr(t.1, t.2)).font(.system(size: 10, weight: .semibold))
                                Text(faixaTam(t.0)).font(.system(size: 8)).foregroundStyle(RelCtx.cinza).lineLimit(1)
                                if let m = c.info.tempoPorTamanho?[t.0] ?? nil {
                                    Text(tr("pedido → entrega: ", "ask → delivery: ") + RelCtx.duracao(m)).font(.system(size: 8)).foregroundStyle(RelCtx.cinza).lineLimit(1)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
    func faixaTam(_ t: String) -> String {
        switch t { case "grande": return tr("trabalho de mais de 2 h", "over 2 h of work"); case "rapida": return tr("trabalho de até 15 min", "up to 15 min of work"); default: return tr("trabalho de 15 min a 2 h", "15 min to 2 h of work") }
    }

    var grafico: some View {
        let maxv = max(1, i.porDia.map { max($0.feitas, $0.chegaram) }.max() ?? 1)
        let alt: CGFloat = 64
        return RelCartao(pad: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    RelTitulo(texto: tr("Dia a dia", "Day by day"))
                    Spacer()
                    leg(RelCtx.azul.opacity(0.35), tr("chegaram", "came in")); leg(Mood.calm, tr("entregues", "delivered"))
                    leg(Mood.warm, tr("chegou fora do horário", "came in after hours"))
                }
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(i.porDia, id: \.dia) { d in
                        VStack(spacing: 4) {
                            HStack(alignment: .bottom, spacing: 3) {
                                VStack(spacing: 0) {
                                    Spacer(minLength: 0)
                                    Text("\(d.chegaram)").font(.system(size: 7.5)).foregroundStyle(RelCtx.cinza).padding(.bottom, 2)
                                    ZStack(alignment: .bottom) {
                                        RoundedRectangle(cornerRadius: 3).fill(RelCtx.azul.opacity(0.35))
                                        RoundedRectangle(cornerRadius: 3).fill(Mood.warm.opacity(0.85))
                                            .frame(height: d.chegaram == 0 ? 0 : max(0, alt * CGFloat(d.foraHorario) / CGFloat(maxv)))
                                    }
                                    .frame(width: 16, height: max(2, alt * CGFloat(d.chegaram) / CGFloat(maxv)))
                                }
                                VStack(spacing: 0) {
                                    Spacer(minLength: 0)
                                    Text("\(d.feitas)").font(.system(size: 7.5, weight: .semibold)).foregroundStyle(Mood.calm).padding(.bottom, 2)
                                    RoundedRectangle(cornerRadius: 3).fill(Mood.calm)
                                        .frame(width: 16, height: max(2, alt * CGFloat(d.feitas) / CGFloat(maxv)))
                                }
                            }
                            .frame(height: alt + 14, alignment: .bottom)
                            Text(c.diaSemana(d.dia)).font(.system(size: 9, weight: .semibold))
                            Text(c.diaMes(d.dia)).font(.system(size: 7.5)).foregroundStyle(RelCtx.cinza)
                            Text(d.jornadaIni.map { "\($0)–\(d.jornadaFim ?? "")" } ?? "—")
                                .font(.system(size: 7.5)).monospacedDigit().foregroundStyle(RelCtx.cinza)
                            Text(d.ativoSeg.map { tr("ativo ", "active ") + RelCtx.duracao($0) } ?? " ")
                                .font(.system(size: 7.5, weight: .semibold)).monospacedDigit().foregroundStyle(RelCtx.roxo)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                Text(tr("Embaixo de cada dia: primeira e última atividade minha (o dia vira às 5h) e o tempo ativo, que é o mínimo comprovado pelas mensagens e entregas.", "Under each day: my first and last activity (day turns at 5am) and active time, the minimum proven by messages and deliveries."))
                    .font(.system(size: 8)).foregroundStyle(RelCtx.cinza).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    func leg(_ cor: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Circle().fill(cor).frame(width: 6, height: 6); Text(t).font(.system(size: 8.5)).foregroundStyle(RelCtx.cinza) }
    }

    func mini(_ titulo: String, _ grande: String, _ cor: Color, _ texto: String) -> some View {
        RelCartao(cheio: true) {
            VStack(alignment: .leading, spacing: 4) {
                Text(titulo).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(RelCtx.cinza)
                Text(grande).font(.system(size: 20, weight: .bold)).monospacedDigit().foregroundStyle(cor)
                Text(texto).font(.system(size: 9)).lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
    var foraDoHorario: some View {
        var t = tr("\(i.foraHorario) das \(i.chegaram) demandas chegaram fora do expediente (antes das 9h, depois das 18h ou fim de semana).",
                   "\(i.foraHorario) of \(i.chegaram) tasks came in outside work hours (before 9am, after 6pm or weekends).")
        if c.diasDepoisDas20 > 0 { t += tr(" Em \(c.diasDepoisDas20) dias a última resposta foi depois das 20h.", " On \(c.diasDepoisDas20) days the last reply was after 8pm.") }
        return mini(tr("Fora do horário", "After hours"), RelCtx.pct(i.foraHorario, i.chegaram), Mood.warm, t)
    }
    var pressa: some View {
        var t = tr("\(i.urgentes) pedidas como urgentes", "\(i.urgentes) asked as urgent")
        if i.comPrazo > 0 { t += tr(" e \(i.comPrazo) com prazo marcado", " and \(i.comPrazo) with a set deadline") }
        t += tr(". \(i.clientesAtendidos) clientes diferentes pediram coisa na semana.", ". \(i.clientesAtendidos) different clients asked for something this week.")
        return mini(tr("Pra já", "Right now"), "\(i.urgentes)", Mood.hot, t)
    }
    var mensagens: some View {
        let t = tr("\(i.mensagens.recebidas) recebidas e \(i.mensagens.enviadas) enviadas por mim em \(i.mensagens.conversas) conversas de cliente. \(i.mensagens.enviadasFora) das minhas fora do horário.",
                   "\(i.mensagens.recebidas) received and \(i.mensagens.enviadas) sent by me across \(i.mensagens.conversas) client chats. \(i.mensagens.enviadasFora) of mine after hours.")
        return mini(tr("Mensagens", "Messages"), "\(i.mensagens.recebidas + i.mensagens.enviadas)", RelCtx.roxo, t)
    }

    var horas: some View {
        let maxv = max(1, i.porHora.max() ?? 1)
        return RelCartao(pad: 14) {
            VStack(alignment: .leading, spacing: 8) {
                RelTitulo(texto: tr("Que horas os pedidos chegam", "When requests come in"), sub: tr("faixa clara = expediente, 9h às 18h", "light band = work hours, 9am to 6pm"))
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<24, id: \.self) { h in
                        let v = i.porHora.indices.contains(h) ? i.porHora[h] : 0
                        let fora = h < 9 || h >= 18
                        VStack(spacing: 3) {
                            Text(v > 0 ? "\(v)" : "").font(.system(size: 6.5)).foregroundStyle(RelCtx.cinza)
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(v == 0 ? RelCtx.linha : (fora ? Mood.warm : RelCtx.azul).opacity(0.25 + 0.75 * Double(v) / Double(maxv)))
                                .frame(height: max(3, 40 * CGFloat(v) / CGFloat(maxv)))
                            Text(h % 3 == 0 ? "\(h)h" : "").font(.system(size: 6.5)).foregroundStyle(RelCtx.cinza).frame(height: 8)
                        }
                        .frame(maxWidth: .infinity)
                        .background(fora ? Color.clear : Color.white.opacity(0.7))
                    }
                }
                .frame(height: 64, alignment: .bottom)
            }
        }
    }
}

// MARK: - página 2: clientes, jornada, o que ficou aberto

struct RelDetalhe: View {
    let c: RelCtx
    var i: RelInfo { c.info }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            clientes
            HStack(alignment: .top, spacing: 10) { jornada; abertas }.fixedSize(horizontal: false, vertical: true)
            RelResumo(c: c).horas
        }
    }

    func col(_ t: String, _ w: CGFloat, _ al: Alignment = .trailing) -> some View {
        Text(t).font(.system(size: 8, weight: .semibold)).foregroundStyle(RelCtx.cinza).frame(width: w, alignment: al)
    }
    func num(_ v: Int, _ w: CGFloat, _ cor: Color = RelCtx.tinta, forte: Bool = false) -> some View {
        Text(v == 0 ? "·" : "\(v)").font(.system(size: 10, weight: forte ? .semibold : .regular)).monospacedDigit()
            .foregroundStyle(v == 0 ? RelCtx.cinza : cor).frame(width: w, alignment: .trailing)
    }

    var clientes: some View {
        let lista = Array(i.clientes.prefix(10))
        let resto = i.clientes.count - lista.count
        let top = max(1, lista.first?.pedidos ?? 1)
        return RelCartao(pad: 14) {
            VStack(alignment: .leading, spacing: 0) {
                RelTitulo(texto: tr("Por cliente", "By client"), sub: tr("\(i.clientes.count) clientes na semana", "\(i.clientes.count) clients this week"))
                    .padding(.bottom, 8)
                HStack(spacing: 0) {
                    Text(tr("cliente", "client")).font(.system(size: 8, weight: .semibold)).foregroundStyle(RelCtx.cinza)
                    Spacer()
                    col(tr("pedidos", "asked"), 84); col(tr("entregues", "done"), 52); col(tr("grandes", "large"), 44); col(tr("abertas", "open"), 42)
                    col(tr("urgentes", "urgent"), 46); col(tr("fora hor.", "after hrs"), 48); col(tr("até entregar", "to deliver"), 62)
                }
                .padding(.bottom, 4)
                ForEach(Array(lista.enumerated()), id: \.offset) { k, cl in
                    HStack(spacing: 0) {
                        RelAvatar(c: c, jid: cl.jid, nome: cl.client, size: 16).padding(.trailing, 7)
                        Text(cl.client).font(.system(size: 10, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 6)
                        HStack(spacing: 5) {
                            Capsule().fill(RelCtx.azul.opacity(0.35)).frame(width: max(2, 50 * CGFloat(cl.pedidos) / CGFloat(top)), height: 4)
                            Text("\(cl.pedidos)").font(.system(size: 10, weight: .semibold)).monospacedDigit().frame(width: 22, alignment: .trailing)
                        }
                        .frame(width: 84, alignment: .trailing)
                        num(cl.entregues, 52, Mood.calm, forte: true); num(cl.grandes ?? 0, 44, RelCtx.roxo, forte: true); num(cl.abertas, 42, Mood.hot)
                        num(cl.urgentes, 46, Mood.hot); num(cl.foraHorario, 48, Mood.warm)
                        Text(RelCtx.duracao(cl.medianaSeg)).font(.system(size: 9.5)).monospacedDigit().foregroundStyle(RelCtx.cinza).frame(width: 62, alignment: .trailing)
                    }
                    .padding(.vertical, 3.5)
                    .overlay(alignment: .top) { if k > 0 { Rectangle().fill(RelCtx.linha).frame(height: 0.5) } }
                }
                if resto > 0 {
                    Text(tr("+ \(resto) clientes com menos pedidos", "+ \(resto) more clients with fewer requests")).font(.system(size: 8.5)).foregroundStyle(RelCtx.cinza).padding(.top, 4)
                }
            }
        }
    }

    var jornada: some View {
        RelCartao(pad: 14, cheio: true) {
            VStack(alignment: .leading, spacing: 0) {
                RelTitulo(texto: tr("Jornada", "Workday"), sub: tr("início → fim · ativo", "start → end · active")).padding(.bottom, 8)
                ForEach(Array(i.porDia.enumerated()), id: \.offset) { k, d in
                    let tarde = d.jornadaFim.flatMap { Int($0.prefix(2)) }.map { $0 >= 20 || $0 < 5 } ?? false
                    HStack(spacing: 6) {
                        Text("\(c.diaSemana(d.dia)) \(c.diaMes(d.dia))").font(.system(size: 9.5, weight: .medium)).frame(width: 62, alignment: .leading)
                        Text(d.jornadaIni.map { "\($0) → \(d.jornadaFim ?? "")" } ?? tr("sem mensagens", "no messages"))
                            .font(.system(size: 9.5)).monospacedDigit().foregroundStyle(tarde ? Mood.warm : RelCtx.tinta)
                        Spacer(minLength: 4)
                        Text(d.ativoSeg.map { RelCtx.duracao($0) } ?? "").font(.system(size: 9.5, weight: .semibold)).monospacedDigit().foregroundStyle(RelCtx.roxo)
                        Text("\(d.enviadas)").font(.system(size: 8.5)).monospacedDigit().foregroundStyle(RelCtx.cinza).frame(width: 26, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                    .overlay(alignment: .top) { if k > 0 { Rectangle().fill(RelCtx.linha).frame(height: 0.5) } }
                }
                Text(tr("O dia vira às 5h (madrugada conta pro dia anterior). Ativo = soma dos trechos entre mensagens minhas e entregas com até 45 min de intervalo: é o mínimo, código feito sem mandar mensagem não entra. Última coluna = mensagens que mandei. Laranja = terminou depois das 20h.\(i.ativoTotalSeg.map { " Total ativo na semana: " + RelCtx.horas($0) + "." } ?? "")",
                        "Day turns at 5am. Active = sum of stretches between my messages and deliveries with gaps up to 45 min: a minimum, coding without messaging is not counted. Last column = messages I sent. Orange = ended after 8pm.\(i.ativoTotalSeg.map { " Total active this week: " + RelCtx.horas($0) + "." } ?? "")"))
                    .font(.system(size: 7.5)).foregroundStyle(RelCtx.cinza).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
        }
        .frame(width: 262)
    }

    var abertas: some View {
        RelCartao(pad: 14, cheio: true) {
            VStack(alignment: .leading, spacing: 6) {
                RelTitulo(texto: tr("Ainda abertas", "Still open"), sub: i.aguardandoCliente > 0 ? tr("\(i.aguardandoCliente) esperando o cliente", "\(i.aguardandoCliente) waiting on the client") : nil)
                if i.abertas.isEmpty {
                    Text(tr("Nada aberto. Tudo que chegou foi entregue.", "Nothing open. Everything that came in was delivered.")).font(.system(size: 9.5)).foregroundStyle(RelCtx.cinza)
                }
                ForEach(i.abertas.prefix(6)) { a in
                    HStack(alignment: .top, spacing: 6) {
                        RelAvatar(c: c, jid: a.jid, nome: a.client, size: 14).padding(.top, 1)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.title).font(.system(size: 9.5, weight: .medium)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                            Text(a.client + " · " + estado(a)).font(.system(size: 8)).foregroundStyle(RelCtx.cinza).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(RelCtx.duracao(c.info.geradoEm - a.ts)).font(.system(size: 8.5, weight: .semibold)).monospacedDigit().foregroundStyle(Mood.warm)
                    }
                }
                if i.abertas.count > 6 { Text("+ \(i.abertas.count - 6)").font(.system(size: 8.5)).foregroundStyle(RelCtx.cinza) }
            }
        }
    }
    func estado(_ a: RelItem) -> String {
        if a.espera == "esperando_cliente" { return tr("esperando o cliente", "waiting on client") }
        if a.espera == "respondida" { return tr("respondida", "answered") }
        if a.doing != nil { return tr("fazendo", "in progress") }
        return tr("na fila", "queued")
    }

    var outras: some View { outrasCartao }
    var outrasCartao: some View {
        let nomes: [String: (String, String)] = ["trafego": ("tráfego", "ads"), "design": ("design", "design"), "comercial": ("comercial", "sales"),
                                                  "operacao": ("operação", "operations"), "outro": ("outros", "other"), "social": ("social", "social")]
        let partes = i.outrasAreas.porArea.sorted { $0.value > $1.value }.map { k, v in "\(v) " + (nomes[k].map { tr($0.0, $0.1) } ?? k) }
        return RelCartao(pad: 14, cheio: true) {
            VStack(alignment: .leading, spacing: 4) {
                RelTitulo(texto: tr("De outras áreas", "Other areas"))
                Text(i.outrasAreas.total == 0
                     ? tr("Nenhum pedido de outra área nos grupos.", "No requests for other areas in the groups.")
                     : tr("Além disso, \(i.outrasAreas.total) pedidos nos mesmos grupos eram de outras áreas e não entram nos números acima: ", "On top of that, \(i.outrasAreas.total) requests in the same groups belonged to other areas and are not counted above: ") + partes.joined(separator: ", ") + ".")
                    .font(.system(size: 9)).lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var metodo: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(tr("Como os números são feitos", "How the numbers are made")).font(.system(size: 9, weight: .semibold))
            Text(tr("""
            O Sísifo lê as conversas de cliente no WhatsApp e transforma cada pedido de trabalho em uma demanda (com cliente, quem pediu e a mensagem original). \
            "Do pedido à entrega" é a mediana entre a mensagem do pedido e o momento em que marquei como feito, só nas que marquei à mão \
            (\(i.autoFeitas) foram fechadas sozinhas porque a própria conversa mostrou que estava resolvido). Expediente considerado: segunda a sexta, 9h às 18h. \
            A semana anterior teve \(i.anterior.chegaram) demandas chegando e \(i.anterior.entregues) entregues.
            """, """
            Sisifo reads client WhatsApp chats and turns each work request into a task (with client, requester and the original message). \
            "From ask to delivery" is the median between the request message and when I marked it done, only for the ones I closed by hand \
            (\(i.autoFeitas) were closed automatically because the chat itself showed it was solved). Work hours: Monday to Friday, 9am to 6pm. \
            Last week had \(i.anterior.chegaram) tasks coming in and \(i.anterior.entregues) delivered.
            """))
            .font(.system(size: 8)).foregroundStyle(RelCtx.cinza).lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(RelCtx.linha, lineWidth: 1))
    }
}

// MARK: - páginas 3+: tudo que foi entregue

struct RelEntregas: View {
    let c: RelCtx
    let linhas: [RelCtx.Linha]
    let continua: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !continua {
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        RelDetalhe(c: c).outras.frame(width: 220)
                        RelDetalhe(c: c).metodo
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 18)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(continua ? tr("Entregas (continuação)", "Deliveries (continued)") : tr("Tudo que foi entregue", "Everything delivered"))
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                if !continua {
                    Text(tr("\(c.info.entregues) itens · tamanho · pedido → entrega", "\(c.info.entregues) items · size · asked → delivered")).font(.system(size: 9)).foregroundStyle(RelCtx.cinza)
                }
            }
            .padding(.bottom, 10)
            ForEach(linhas) { l in
                switch l {
                case .dia(let d, let n):
                    HStack {
                        Text("\(c.diaSemana(d)) \(c.diaMes(d))").font(.system(size: 10, weight: .bold))
                        Text(tr("\(n) entregues", "\(n) delivered")).font(.system(size: 9)).foregroundStyle(Mood.calm)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(RelCtx.card))
                    .padding(.top, 6).padding(.bottom, 2)
                case .item(let it):
                    HStack(alignment: .center, spacing: 7) {
                        RelAvatar(c: c, jid: it.jid, nome: it.client, size: 15)
                        Text(it.client).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(RelCtx.cinza)
                            .lineLimit(2).minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
                            .frame(width: 100, alignment: .leading)
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(RelCtx.tamNome(it.size)).font(.system(size: 7, weight: .semibold)).foregroundStyle(RelCtx.tamCor(it.size))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(RelCtx.tamCor(it.size).opacity(0.13)))
                                .frame(width: 40, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                            Text(it.title).font(.system(size: 9.5)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            if it.urgent {
                                Text(tr("urgente", "urgent")).font(.system(size: 7, weight: .bold)).foregroundStyle(Mood.hot)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Capsule().fill(Mood.hot.opacity(0.12)))
                                    .fixedSize()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(horario(it)).font(.system(size: 8.5)).monospacedDigit().foregroundStyle(RelCtx.tinta.opacity(0.75))
                            Text(duracao(it)).font(.system(size: 7.5)).monospacedDigit().foregroundStyle(it.autoDone ? Mood.calm : RelCtx.cinza)
                        }
                        .lineLimit(1).fixedSize()
                        .frame(width: 96, alignment: .trailing)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 3).frame(minHeight: 24)
                }
            }
        }
    }

    func horario(_ it: RelItem) -> String {
        guard let f = it.doneAt else { return "" }
        let pedido = c.isoDia(it.ts) == c.isoDia(f) ? c.hora(it.ts) : c.diaHora(it.ts)
        return "\(pedido) → \(c.hora(f))"
    }
    func duracao(_ it: RelItem) -> String {
        guard let f = it.doneAt else { return "" }
        return it.autoDone ? tr("resolvida na conversa", "solved in chat") : RelCtx.duracao(max(60, f - it.ts))
    }
}
