import AppKit
import SwiftUI

/// Balão daemon (Bolha A + chifrinhos), desenhado nas coordenadas do SVG (24x24, y pra baixo).
enum Daemon {
    /// pose da animação (unidades do SVG 24x24)
    struct Pose {
        var dy: CGFloat = 0, sx: CGFloat = 1, sy: CGFloat = 1, rot: CGFloat = 0, horns: CGFloat = 0
        /// balanço apoiado na base (graus): a pedra tomba pra um lado e pro outro
        var tilt: CGFloat = 0
        /// carinha: blink 0 aberto…1 fechado, look = olhar pro lado (unidades), grin = tamanho do sorriso
        var blink: CGFloat = 0, look: CGFloat = 0, grin: CGFloat = 1
    }

    /// tamanho do quadro na barra de menus: pedra com ~15 pt de altura, igual aos ícones do sistema
    static let barSize: CGFloat = 18

    static func image(filled: Bool, size: CGFloat = 18, color: NSColor = .black, template: Bool = true,
                      pose: Pose = Pose(), dot: NSColor? = nil) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = size / 24
            ctx.scaleBy(x: s, y: s)
            ctx.saveGState()
            // pulo + amasso a partir da base, giro pelo centro do balão
            ctx.translateBy(x: 11.5, y: 21.6 + pose.dy)
            ctx.rotate(by: pose.tilt * .pi / 180)
            ctx.scaleBy(x: pose.sx, y: pose.sy)
            ctx.translateBy(x: 0, y: -8.2)
            ctx.rotate(by: pose.rot * .pi / 180)
            ctx.translateBy(x: -11.5, y: -13.4)
            color.setFill()
            color.setStroke()

            // Sísifo: a pedra de basalto facetada (mesma do ícone), em silhueta pra barra de menus
            // coordenadas do SVG do ícone (viewBox 0 0 220, pedra entre x 52..178 e y 44..182)
            let k: CGFloat = 0.142
            func R(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: 11.5 + (x - 116) * k, y: 13.0 + (y - 113) * k) }
            let rock = NSBezierPath()
            rock.move(to: R(62, 150))
            rock.curve(to: R(70, 82), controlPoint1: R(52, 124), controlPoint2: R(56, 98))
            rock.line(to: R(84, 64))
            rock.curve(to: R(118, 46), controlPoint1: R(92, 54), controlPoint2: R(104, 48))
            rock.line(to: R(136, 44))
            rock.curve(to: R(160, 58), controlPoint1: R(146, 44), controlPoint2: R(154, 50))
            rock.line(to: R(172, 80))
            rock.curve(to: R(174, 116), controlPoint1: R(178, 92), controlPoint2: R(178, 104))
            rock.line(to: R(170, 140))
            rock.curve(to: R(140, 176), controlPoint1: R(168, 160), controlPoint2: R(156, 172))
            rock.line(to: R(104, 180))
            rock.curve(to: R(62, 150), controlPoint1: R(86, 182), controlPoint2: R(70, 172))
            rock.close()
            // arestas das faces (vazadas quando cheia, riscadas quando só contorno)
            let faces = NSBezierPath()
            faces.move(to: R(116, 48)); faces.line(to: R(112, 80)); faces.line(to: R(132, 112)); faces.line(to: R(152, 96)); faces.line(to: R(172, 92))
            faces.move(to: R(104, 84)); faces.line(to: R(108, 118)); faces.line(to: R(94, 160))
            faces.lineJoinStyle = .round; faces.lineCapStyle = .round
            if filled {
                rock.fill()
                NSGraphicsContext.current?.compositingOperation = .clear
                faces.lineWidth = 1.3
                faces.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            } else {
                rock.lineWidth = 1.8; rock.lineJoinStyle = .round
                rock.stroke()
                faces.lineWidth = 1.2
                faces.stroke()
            }
            ctx.restoreGState()
            if let dot {
                // bolinha "tem novidade", com respiro vazado em volta
                let c = NSPoint(x: 21.2, y: 4.4)
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: c.x - 3.6, y: c.y - 3.6, width: 7.2, height: 7.2)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                dot.setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - 2.6, y: c.y - 2.6, width: 5.2, height: 5.2)).fill()
            }
            return true
        }
        img.isTemplate = template
        return img
    }
}

/// logo do topo do painel: daemon branco num quadradinho
struct DaemonLogo: View {
    var size: CGFloat = 34
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.35, green: 0.85, blue: 0.55), Mood.calm], startPoint: .top, endPoint: .bottom))
            Image(nsImage: Daemon.image(filled: true, size: size * 0.72, color: .white, template: false))
        }
        .frame(width: size, height: size)
    }
}

/// animação "daemon acordou" na menu bar: 2 pulinhos com amasso, balanço e chifrinhos mexendo
enum WakeAnim {
    static let duration: Double = 1.5     // pulinhos
    static let bubbleIn: Double = 0.95    // cápsula começa a sair (pousando do 1º pulo)
    static let open: Double = 0.38        // tempo pra abrir/fechar
    static let hold: Double = 4.2         // fica aberta
    static var total: Double { bubbleIn + open + hold + open }

    static let green = NSColor(red: 0.16, green: 0.70, blue: 0.47, alpha: 1)

    /// 0...1 com mola leve na abertura
    static func bubbleProgress(_ t: Double) -> Double {
        let a = t - bubbleIn
        if a <= 0 { return 0 }
        if a < open { let u = a / open; return 1 - pow(1 - u, 3) * cos(u * .pi * 0.5) + sin(u * .pi) * 0.06 }
        if a < open + hold { return 1 }
        let u = min((a - open - hold) / open, 1)
        return 1 - u * u * (3 - 2 * u)
    }

    /// frame completo da menu bar: daemon (pose) + cápsula com texto
    static func frame(t: Double, text: String, height: CGFloat = 22) -> NSImage {
        let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let textW = ceil((text as NSString).size(withAttributes: attrs).width)
        let fullW = textW + 18
        let p = bubbleProgress(t)
        let capW = max(0, fullW * CGFloat(p))
        let gap: CGFloat = capW > 0 ? 4 : 0
        let total = height + gap + capW
        let daemon = image(t: t)
        let img = NSImage(size: NSSize(width: total, height: height), flipped: false) { _ in
            daemon.draw(in: NSRect(x: 0, y: 0, width: height, height: height))
            guard capW > 1 else { return true }
            let capH: CGFloat = 16
            let r = NSRect(x: height + gap, y: (height - capH) / 2, width: capW, height: capH)
            let path = NSBezierPath(roundedRect: r, xRadius: capH / 2, yRadius: capH / 2)
            green.setFill(); path.fill()
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            let alpha = CGFloat(min(max((p - 0.55) / 0.45, 0), 1))
            var a = attrs; a[.foregroundColor] = NSColor.white.withAlphaComponent(alpha)
            let th = (text as NSString).size(withAttributes: a).height
            (text as NSString).draw(at: NSPoint(x: r.minX + 9, y: r.midY - th / 2 + 0.5), withAttributes: a)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        img.isTemplate = false
        return img
    }

    private static func image(t: Double) -> NSImage {
        Daemon.image(filled: true, size: Daemon.barSize, color: green, template: false, pose: pose(min(t, duration)))
    }

    static func pose(_ t: Double) -> Daemon.Pose {
        var p = Daemon.Pose()
        let x = min(max(t / duration, 0), 1)
        func hop(_ u: Double, _ h: Double) {
            p.dy = CGFloat(-h * sin(.pi * u))
            if u < 0.14 { let k = 1 - u / 0.14; p.sy = 1 - 0.16 * k; p.sx = 1 + 0.12 * k }          // agacha
            else if u > 0.88 { let k = (u - 0.88) / 0.12; p.sy = 1 - 0.12 * k; p.sx = 1 + 0.09 * k } // pousa
            else { p.sy = 1 + 0.04 * sin(.pi * u); p.sx = 1 - 0.04 * sin(.pi * u) }                  // estica no ar
        }
        if x < 0.38 { hop(x / 0.38, 1.7) }
        else if x < 0.68 { hop((x - 0.38) / 0.30, 1.0) }
        else { let u = (x - 0.68) / 0.32; let k = 1 - u; p.sy = 1 - 0.10 * k * k; p.sx = 1 + 0.07 * k * k }
        p.rot = CGFloat(9 * sin(x * 3 * 2 * .pi) * (1 - x))
        p.horns = CGFloat(16 * sin(x * 5 * 2 * .pi) * (1 - x * 0.8))
        p.grin = CGFloat(1 + 0.35 * sin(.pi * min(x / 0.7, 1)))   // risadinha enquanto pula
        p.look = CGFloat(0.7 * sin(x * 2 * 2 * .pi) * (1 - x))
        return p
    }
}

/// travessura de tempos em tempos (parado): olha pros lados, pisca, sorri malvado e mexe os chifrinhos
enum IdleAnim {
    static let duration: Double = 2.2

    static func pose(_ t: Double) -> Daemon.Pose {
        var p = Daemon.Pose()
        let x = min(max(t / duration, 0), 1)
        func bump(_ a: Double, _ b: Double) -> Double {   // 0→1→0 suave entre a e b
            guard x > a, x < b else { return 0 }
            return sin(.pi * (x - a) / (b - a))
        }
        // olha pra esquerda, depois direita, volta
        if x < 0.22 { p.look = CGFloat(-0.9 * sin(.pi / 2 * x / 0.22)) }
        else if x < 0.45 { p.look = CGFloat(-0.9 + 1.8 * (1 - cos(.pi * (x - 0.22) / 0.23)) / 2) }
        else if x < 0.6 { p.look = CGFloat(0.9 * cos(.pi / 2 * (x - 0.45) / 0.15)) }
        // piscadinha
        p.blink = CGFloat(bump(0.62, 0.72))
        // sorrisão + chifrinhos + tremidinha de risada
        let laugh = bump(0.66, 1.0)
        p.grin = CGFloat(1 + 0.4 * laugh)
        p.horns = CGFloat(12 * sin(x * 6 * 2 * .pi) * laugh)
        p.dy = CGFloat(-0.5 * abs(sin(x * 8 * 2 * .pi)) * laugh)
        return p
    }
}

/// som de demanda nova (janela › Ajustes › Som de demanda nova). Gerados por tools/sons_sisifo.py
enum WakeSound {
    static let options: [(id: String, name: String)] = [("eco-morro", "Eco do morro")]
    static let padrao = "eco-morro"
    static var current: String {
        let v = UserDefaults.standard.string(forKey: "sound") ?? padrao
        return v == "off" || options.contains(where: { $0.id == v }) ? v : padrao
    }
    nonisolated(unsafe) private static var playing: NSSound?

    static func play(_ v: String = current) {
        guard v != "off", let url = Bundle.main.url(forResource: v, withExtension: "wav", subdirectory: "sounds") else { return }
        playing?.stop()
        let snd = NSSound(contentsOf: url, byReference: true)
        snd?.volume = 0.8
        snd?.play()
        playing = snd
    }
}
