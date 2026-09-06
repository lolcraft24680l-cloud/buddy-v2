import SwiftUI

enum Laune: Equatable {
    case start, ruhe, hört, denkt, arbeitet, redet, freut, neugier, fehler

    var lebendig: Bool { self != .denkt && self != .arbeitet && self != .fehler }
}

extension Color {
    static let leere      = Color(red: 0.024, green: 0.027, blue: 0.039)
    static let irisHell   = Color(red: 0.71,  green: 0.96,  blue: 1.00)
    static let iris       = Color(red: 0.36,  green: 0.91,  blue: 1.00)
    static let irisTief   = Color(red: 0.11,  green: 0.62,  blue: 0.77)
    static let bernstein  = Color(red: 1.00,  green: 0.82,  blue: 0.29)
    static let bernsteinT = Color(red: 0.79,  green: 0.56,  blue: 0.06)
    static let minze      = Color(red: 0.44,  green: 1.00,  blue: 0.76)
    static let minzeTief  = Color(red: 0.09,  green: 0.60,  blue: 0.44)
    static let glut       = Color(red: 1.00,  green: 0.35,  blue: 0.35)
    static let glutTief   = Color(red: 0.63,  green: 0.13,  blue: 0.13)
}

// MARK: - Ein Auge

private struct Auge: View {
    let breite: CGFloat
    let höhe: CGFloat
    let farben: [Color]
    let lidHoch: Bool
    /// Wandernder Lichtstreifen, wenn ein Werkzeug arbeitet.
    let scan: Double?

    var body: some View {
        ZStack {
            LinearGradient(colors: farben, startPoint: .top, endPoint: .bottom)

            // Feine Zeilen wie auf einem alten Spielzeugdisplay
            GeometryReader { raum in
                Path { pfad in
                    var y: CGFloat = 0
                    while y < raum.size.height {
                        pfad.move(to: CGPoint(x: 0, y: y))
                        pfad.addLine(to: CGPoint(x: raum.size.width, y: y))
                        y += 4
                    }
                }
                .stroke(Color.black.opacity(0.17), lineWidth: 1)
            }

            // Lichtreflex oben — gibt dem Auge Tiefe
            Ellipse()
                .fill(Color.white.opacity(0.28))
                .frame(width: breite * 0.5, height: höhe * 0.16)
                .blur(radius: 6)
                .offset(x: -breite * 0.14, y: -höhe * 0.28)

            if let scan {
                LinearGradient(
                    colors: [.clear, .white.opacity(0.55), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: breite * 0.6)
                .offset(x: (scan * 2 - 1) * breite)
                .blendMode(.plusLighter)
            }

            // Das Lid liegt unter dem Auge und fährt zum Lächeln hoch.
            Ellipse()
                .fill(Color.leere)
                .frame(width: breite * 1.6, height: höhe * 1.2)
                .offset(y: lidHoch ? höhe * 0.6 : höhe * 1.3)
        }
        .frame(width: breite, height: höhe)
        .clipShape(RoundedRectangle(cornerRadius: breite * 0.28, style: .continuous))
    }
}

// MARK: - Das Gesicht

struct Gesicht: View {
    let laune: Laune
    /// Zählt bei jedem gesprochenen Wort hoch.
    let takt: Int
    /// Mikrofonpegel 0 bis 1, während zugehört wird.
    let pegel: Double

    @State private var lidschlag: CGFloat = 1
    @State private var zwinkerLinks: CGFloat = 1
    @State private var wippen: CGFloat = 0
    @State private var stauchen: CGFloat = 1
    @State private var blick: CGSize = .zero
    @State private var neigung: Double = 0
    @State private var erwacht = false
    @State private var atem: CGFloat = 1

    private let uhr = Timer.publish(every: 0.45, on: .main, in: .common).autoconnect()

    // MARK: Form je nach Laune

    private var breite: CGFloat { laune == .denkt || laune == .arbeitet ? 118 : 112 }

    private var höhe: CGFloat {
        switch laune {
        case .start:    return erwacht ? 150 : 6
        case .ruhe:     return 150
        case .hört:     return 164 + CGFloat(pegel) * 26
        case .denkt:    return 52
        case .arbeitet: return 74
        case .redet:    return 136
        case .freut:    return 150
        case .neugier:  return 156
        case .fehler:   return 64
        }
    }

    private var farben: [Color] {
        switch laune {
        case .denkt:    return [.white.opacity(0.92), .bernstein, .bernsteinT]
        case .arbeitet: return [.white.opacity(0.92), .minze, .minzeTief]
        case .fehler:   return [.white.opacity(0.88), .glut, .glutTief]
        default:        return [.irisHell, .iris, .irisTief]
        }
    }

    private var leuchten: Color { farben[1] }

    private var abstand: CGFloat {
        switch laune {
        case .denkt, .arbeitet: return 58
        case .freut:            return 46
        default:                return 50
        }
    }

    var body: some View {
        ZStack {
            if laune == .arbeitet || laune == .denkt { kreisel }

            if laune == .arbeitet {
                TimelineView(.animation) { schlag in
                    augenpaar(scan: schlag.date.timeIntervalSince1970
                        .truncatingRemainder(dividingBy: 1.4) / 1.4)
                }
            } else {
                augenpaar(scan: nil)
            }
        }
        .frame(height: 220)
        .onReceive(uhr) { _ in puls() }
        .onAppear { aufwachen() }
        .onChange(of: takt) { _, _ in sprechStoß() }
        .onChange(of: laune) { _, neu in reagiere(auf: neu) }
    }

    // MARK: Augen

    private func augenpaar(scan: Double?) -> some View {
        HStack(spacing: abstand) {
            Auge(breite: breite, höhe: höhe, farben: farben,
                 lidHoch: laune == .freut, scan: scan)
                .scaleEffect(x: 1, y: zwinkerLinks, anchor: .center)
                .rotationEffect(.degrees(laune == .fehler ? 9 : 0))

            Auge(breite: breite, höhe: höhe, farben: farben,
                 lidHoch: laune == .freut, scan: scan)
                .rotationEffect(.degrees(laune == .fehler ? -9 : 0))
        }
        .shadow(color: leuchten.opacity(0.55), radius: 30)
        .shadow(color: leuchten.opacity(0.22), radius: 85)
        .scaleEffect(x: 1, y: lidschlag * stauchen, anchor: .center)
        .scaleEffect(atem)
        .rotationEffect(.degrees(neigung))
        .offset(x: blick.width, y: blick.height + wippen)
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: laune)
        .animation(.easeOut(duration: 0.12), value: pegel)
        .animation(.easeInOut(duration: 0.08), value: lidschlag)
        .animation(.easeInOut(duration: 0.08), value: zwinkerLinks)
    }

    // MARK: Kreisel

    /// Drei Punkte, die beim Nachdenken und Arbeiten um das Gesicht kreisen.
    private var kreisel: some View {
        TimelineView(.animation) { takt in
            let zeit = takt.date.timeIntervalSince1970
            let tempo = laune == .arbeitet ? 1.7 : 1.0
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let winkel = zeit * tempo + Double(i) * 2.094
                    Circle()
                        .fill(leuchten)
                        .frame(width: 7, height: 7)
                        .offset(x: cos(winkel) * 148, y: sin(winkel) * 62)
                        .opacity(0.35 + 0.4 * (sin(winkel) + 1) / 2)
                        .blur(radius: 0.5)
                }
            }
        }
        .transition(.opacity)
    }

    // MARK: Bewegung

    /// Ein Puls alle 0,45 Sekunden treibt Blinzeln, Zwinkern und Blickwechsel.
    private func puls() {
        guard erwacht else { return }
        let zufall = Double.random(in: 0...1)

        withAnimation(.easeInOut(duration: 2.6)) {
            atem = laune == .ruhe ? CGFloat.random(in: 0.985...1.015) : 1
        }

        guard laune.lebendig else { return }

        // Blinzeln
        if lidschlag == 1, zwinkerLinks == 1, zufall < 0.14 {
            lidschlag = 0.04
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { lidschlag = 1 }
            return
        }
        // Gelegentlich nur ein Auge — wirkt sofort lebendiger
        if lidschlag == 1, zwinkerLinks == 1, laune == .ruhe, zufall > 0.975 {
            zwinkerLinks = 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { zwinkerLinks = 1 }
            return
        }
        // Blicksprünge
        if zufall > 0.86 {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
                blick = CGSize(width: .random(in: -14...14), height: .random(in: -8...8))
                neigung = Double.random(in: -2.5...2.5)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                withAnimation(.easeInOut(duration: 0.9)) {
                    blick = .zero
                    if laune != .neugier { neigung = 0 }
                }
            }
        }
    }

    /// Beim Sprechen wippt und staucht das Gesicht pro Wort.
    private func sprechStoß() {
        guard laune == .redet else { return }
        withAnimation(.easeOut(duration: 0.08)) {
            wippen = -9
            stauchen = 1.08
        }
        withAnimation(.easeIn(duration: 0.14).delay(0.08)) {
            wippen = 0
            stauchen = 1
        }
    }

    private func reagiere(auf neu: Laune) {
        switch neu {
        case .neugier:
            withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) { neigung = 9 }
        case .fehler:
            // Kurzes Kopfschütteln
            for (i, wert) in [12.0, -12.0, 7.0, 0.0].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.09) {
                    withAnimation(.easeInOut(duration: 0.09)) { blick.width = wert }
                }
            }
        case .freut:
            withAnimation(.spring(response: 0.32, dampingFraction: 0.5)) { wippen = -14 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { wippen = 0 }
            }
        default:
            withAnimation(.easeOut(duration: 0.3)) { neigung = 0 }
        }
    }

    /// Startsequenz: die Augen fahren hoch wie ein Bildschirm, der angeht.
    private func aufwachen() {
        guard !erwacht else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.spring(response: 0.75, dampingFraction: 0.62)) { erwacht = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            lidschlag = 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { lidschlag = 1 }
        }
    }
}
