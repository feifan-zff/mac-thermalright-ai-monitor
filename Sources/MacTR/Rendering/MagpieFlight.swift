// MagpieFlight.swift — magpie's own animations, after its web page
//
// magpie's routing view (`magpie web`, plugins/routing) plays each request as
// a flight: one magpie carries the dot from the agent through magpie to the
// member routing put first and lets it go there while it answers; another
// brings the answer back — a failure only as far as magpie, which hands the
// request on to the next member. Its logo flaps, flicks its tail and bobs.
//
// MagpieArt draws both birds from the page's own shapes (index.html #bird,
// routing client.js FLIER); FlightDirector keeps time — what the trace says
// changed becomes a flight phase lasting as long as the page's does.

import CoreGraphics
import Foundation

// MARK: - Easing

enum Ease {
    /// CSS cubic-bezier(x1, y1, x2, y2) at progress x.
    static func cubic(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func bx(_ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t }
        func by(_ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<20 {
            t = (lo + hi) / 2
            if bx(t) < x { lo = t } else { hi = t }
        }
        return by(t)
    }

    static func ease(_ x: Double) -> Double { cubic(0.25, 0.1, 0.25, 1, x) }
    static func easeOut(_ x: Double) -> Double { cubic(0, 0, 0.58, 1, x) }
    static func easeInOut(_ x: Double) -> Double { cubic(0.42, 0, 0.58, 1, x) }

    /// CSS @keyframes: (offset 0…1, value) stops, each step eased on its own.
    static func keyframes(_ stops: [(Double, Double)], _ p: Double, _ ease: (Double) -> Double) -> Double {
        guard let first = stops.first, let last = stops.last else { return 0 }
        if p <= first.0 { return first.1 }
        if p >= last.0 { return last.1 }
        for i in 1..<stops.count where p <= stops[i].0 {
            let a = stops[i - 1], b = stops[i]
            return a.1 + (b.1 - a.1) * ease((p - a.0) / (b.0 - a.0))
        }
        return last.1
    }
}

// MARK: - SVG path data

enum SVGPath {
    /// Absolute M/L/H/V/C/Q/Z path data — all magpie's shapes use.
    static func parse(_ d: String) -> CGPath {
        let path = CGMutablePath()
        let re = try! NSRegularExpression(pattern: "[A-Za-z]|-?(?:\\d+\\.?\\d*|\\.\\d+)")
        let ns = d as NSString
        let toks = re.matches(in: d, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        var i = 0
        func isNum() -> Bool { i < toks.count && !(toks[i].first?.isLetter ?? true) }
        func num() -> CGFloat { defer { i += 1 }; return CGFloat(Double(toks[i]) ?? 0) }
        func pt() -> CGPoint { CGPoint(x: num(), y: num()) }
        var cmd = "M", cur = CGPoint.zero, start = CGPoint.zero
        while i < toks.count {
            if !isNum() { cmd = toks[i]; i += 1 }
            switch cmd {
            case "M":
                cur = pt(); start = cur
                path.move(to: cur)
                cmd = "L"   // pairs after a moveto are linetos
            case "L": cur = pt(); path.addLine(to: cur)
            case "H": cur.x = num(); path.addLine(to: cur)
            case "V": cur.y = num(); path.addLine(to: cur)
            case "C":
                let c1 = pt(), c2 = pt()
                cur = pt()
                path.addCurve(to: cur, control1: c1, control2: c2)
            case "Q":
                let c = pt()
                cur = pt()
                path.addQuadCurve(to: cur, control: c)
            case "Z", "z":
                path.closeSubpath()
                cur = start
                while isNum() { i += 1 }   // nothing follows a close; never loop on it
            default:
                while isNum() { i += 1 }
            }
        }
        return path
    }
}

// MARK: - The birds

enum MagpieArt {

    // The logo: index.html's #bird (viewBox 0 0 44 44) and the cuts it moves in
    // (CGPaths, immutable once parsed: safe to share across threads)
    nonisolated(unsafe) private static let bird = SVGPath.parse(birdData)
    nonisolated(unsafe) private static let bodyCut = SVGPath.parse("M16 0H44V44H0V26.4H10.6L13 24.2L16 19Z M29.8 18.3L26 19L22 21L17 23.5L14.6 24.7L10.6 26.4L6 29V32L9 31.5L12.5 32L16.4 31.8L19 31.4L24 28.8L28.5 24L30.6 21.4Z")
    nonisolated(unsafe) private static let tailCut = SVGPath.parse("M0 0H17L17.2 19.6L14 25L10.6 26.4H0Z")
    nonisolated(unsafe) private static let wingCut = SVGPath.parse("M29.8 18.3L26 19L22 21L17 23.5L14.6 24.7L10.6 26.4L6 29V32L9 31.5L12.5 32L16.4 31.8L19 31.4L24 28.8L28.5 24L30.6 21.4Z")

    static let wagDuration = 0.9

    /// The logo in a square `rect` (flipped context). `wag` 0…1 plays the
    /// flap, tail flick and bob the page plays when its window opens; nil
    /// draws it whole, at rest, so the cuts never show.
    static func logo(_ ctx: CGContext, in rect: CGRect, color: CGColor, wag: Double? = nil) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / 44, y: rect.height / 44)
        ctx.setFillColor(color)
        guard let p = wag, p > 0, p < 1 else {
            ctx.addPath(bird)
            ctx.fillPath(using: .evenOdd)
            return
        }
        let e = { (x: Double) in Ease.cubic(0.3, 0, 0.3, 1, x) }
        let bob = Ease.keyframes([(0, 0), (0.18, -4), (0.40, 2), (0.62, -1), (1, 0)], p, e)
        let tail = Ease.keyframes([(0, 0), (0.18, 16), (0.36, -7), (0.54, 9), (0.72, -3), (0.86, 2), (1, 0)], p, e)
        let wing = Ease.keyframes([(0, 0), (0.12, 10), (0.26, -3), (0.40, 8), (0.56, -2), (0.72, 3), (1, 0)], p, e)
        rotate(ctx, bob, about: CGPoint(x: 26, y: 38))
        piece(ctx, bodyCut, evenOdd: true, turn: 0, about: .zero)
        piece(ctx, tailCut, evenOdd: false, turn: tail, about: CGPoint(x: 14, y: 22))
        piece(ctx, wingCut, evenOdd: false, turn: wing, about: CGPoint(x: 30, y: 19.8))
    }

    private static func piece(_ ctx: CGContext, _ cut: CGPath, evenOdd: Bool, turn: Double, about o: CGPoint) {
        ctx.saveGState()
        rotate(ctx, turn, about: o)
        ctx.addPath(cut)
        ctx.clip(using: evenOdd ? .evenOdd : .winding)
        ctx.addPath(bird)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    /// CSS rotate(deg) round a point; clockwise on screen in a flipped context.
    private static func rotate(_ ctx: CGContext, _ deg: Double, about o: CGPoint) {
        guard deg != 0 else { return }
        ctx.translateBy(x: o.x, y: o.y)
        ctx.rotate(by: CGFloat(deg * .pi / 180))
        ctx.translateBy(x: -o.x, y: -o.y)
    }

    // The flier (routing client.js FLIER): facing right, the dot it carries at
    // the tip of its beak, at the origin; its wings beat from the shoulder.
    nonisolated(unsafe) private static let farWing = SVGPath.parse("M-14.5 -3.4C-16.5 -9.5 -14.2 -15 -8.6 -18.6C-9.4 -12.6 -9.6 -7.4 -9.2 -3.2Z")
    nonisolated(unsafe) private static let nearWing = SVGPath.parse("M-15.6 -3.2C-17.8 -10.2 -15.2 -16.4 -8.4 -20.4C-9.3 -13.6 -9.4 -7.8 -8.8 -2.8Z")
    nonisolated(unsafe) private static let wingBar = SVGPath.parse("M-14.6 -5.6C-15.4 -10.4 -13.8 -14.4 -10.4 -17.2")
    nonisolated(unsafe) private static let tailFeathers = SVGPath.parse("M-31.5 3.1L-18.6 -1.8L-17.4 1.2L-30.8 4.6Z")
    nonisolated(unsafe) private static let beak = SVGPath.parse("M-2.3 -4.8L1.4 -3.3L-2.3 -2.2Z")

    static let flapPeriod = 0.42

    /// One flier in its own (already posed) coordinates; `t` (seconds) beats its wings.
    static func flier(_ ctx: CGContext, t: Double, ink: CGColor, card: CGColor) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.scaleBy(x: 1.2, y: 1.2)
        ctx.translateBy(x: -6.5, y: 3.2)

        ctx.saveGState()
        flap(ctx, farWing, t: t + 0.03)   // the far wing a beat ahead, as the page delays it -.03s
        ctx.setFillColor(ink.copy(alpha: 0.45) ?? ink)
        ctx.addPath(farWing)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.setFillColor(ink)
        ctx.addPath(tailFeathers)
        ctx.fillPath()
        ctx.fillEllipse(in: CGRect(x: -12.2 - 7.6, y: -1.4 - 3.9, width: 15.2, height: 7.8))
        ctx.fillEllipse(in: CGRect(x: -4.9 - 3.1, y: -3.7 - 3.1, width: 6.2, height: 6.2))
        ctx.addPath(beak)
        ctx.fillPath()
        ctx.setFillColor(card)
        ctx.fillEllipse(in: CGRect(x: -12.8 - 4.3, y: 0.4 - 1.6, width: 8.6, height: 3.2))   // belly

        ctx.saveGState()
        flap(ctx, nearWing, t: t)
        ctx.setFillColor(ink)
        ctx.addPath(nearWing)
        ctx.fillPath()
        ctx.setStrokeColor(card)
        ctx.setLineWidth(1.3)
        ctx.setLineCap(.round)
        ctx.addPath(wingBar)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// rtflap: down hard, up easy — scaleY 1 → -.62 (skewed -8°) → 1 every .42s,
    /// round the bottom middle of the wing (transform-origin 50% 100%, fill-box).
    private static func flap(_ ctx: CGContext, _ wing: CGPath, t: Double) {
        let p = (t / flapPeriod).truncatingRemainder(dividingBy: 1)
        let k = Ease.keyframes([(0, 0), (0.55, 1), (1, 0)], p) { Ease.cubic(0.45, 0, 0.3, 1, $0) }
        let box = wing.boundingBoxOfPath
        ctx.translateBy(x: box.midX, y: box.maxY)
        ctx.scaleBy(x: 1, y: CGFloat(1 - 1.62 * k))
        ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: CGFloat(tan(-8 * k * .pi / 180)), d: 1, tx: 0, ty: 0))
        ctx.translateBy(x: -box.midX, y: -box.maxY)
    }
}

// MARK: - Flights

/// One cubic Bézier: start, two controls, end.
typealias Cubic = (CGPoint, CGPoint, CGPoint, CGPoint)

/// Where flights go, as the routing panel lays its cards out this frame.
struct FlightStage {
    var agentOut: [String: CGPoint] = [:]    // an agent card's right edge: its wire's start
    var hubIn = CGPoint.zero                 // magpie's left edge: where agents' wires end
    var hubOut = CGPoint.zero                // its right edge: where members' wires start
    var hubSize = CGSize.zero
    var memberPath: [String: [Cubic]] = [:]  // magpie's right edge to a member's row: its wire, through
                                             // its fold's heading when it hangs under one (or to the
                                             // heading, folded)
    var scale: CGFloat = 1                   // LCD px per page px

    /// A wire's S: the same curve the panel strokes.
    static func wire(_ a: CGPoint, _ b: CGPoint) -> Cubic {
        let dx = (b.x - a.x) * 0.5
        return (a, CGPoint(x: a.x + dx, y: a.y), CGPoint(x: b.x - dx, y: b.y), b)
    }
}

/// Plays each request as the page does, timed by what the trace says: a new
/// request takes off from its agent, a try begun sends it on, a try done
/// sends the answer home (or a failure back to magpie for the next member).
final class FlightDirector {

    private enum Dot { case request, answer, failed }

    /// A wire end inside magpie, and the way a flight there is heading.
    private enum Tip { case agentEnd, agentEndBack, memberStart, memberStartBack }

    private enum Leg {
        case agent(rev: Bool)                // the agent's wire to magpie
        case member(String, rev: Bool)       // magpie's wire to a member
        case via(Tip, Tip)                   // through magpie, from one wire to the next
    }

    private enum Phase {
        case toHub                  // routing hasn't picked yet: to magpie, to wait there
        case waitHub(Int)           // at magpie, for try n
        case out(Int)               // carried to try n's member
        case held(Int)              // let go at the member while it answers
        case retreat(Int)           // a failure, back to magpie
        case home                   // the answer (or the error) back to the agent
        case over
    }

    private struct Bird {
        let born: Double
        var leftAt: Double?         // let go of the dot: off, up and away
        var angle: Double?
        var flip = false
        var vx: CGFloat?
        var at = CGPoint.zero
        var posedAt = 0.0
    }

    private struct Flight {
        let agent: String
        var phase = Phase.toHub
        var t0 = 0.0
        var duration = 0.0
        var legs: [Leg] = []
        var waitTip: Tip?           // where in magpie the dot waits, once it does
        var dot = Dot.request
        var carrier: Bird?
        var gone: [Bird] = []
    }

    private var flights: [Int: Flight] = [:]
    private var seen: Set<Int> = []
    private var primed = false
    private var hubTicks: [Double] = []
    private var agentTicks: [String: Double] = [:]
    private var hits: [String: (at: Double, tag: String)] = [:]

    private static let tickDuration = 0.4, awayDuration = 0.45, comeDuration = 0.3
    private static let shakeDuration = 0.45, tagDuration = 1.8

    // MARK: Time

    /// Request IDs and member IDs are local to one gateway.
    func reset() {
        flights.removeAll()
        seen.removeAll()
        primed = false
        hubTicks.removeAll()
        agentTicks.removeAll()
        hits.removeAll()
    }

    func update(_ routes: [MagpieRoute], now: Double) {
        var byID: [Int: MagpieRoute] = [:]
        for r in routes { byID[r.id] = r }
        for r in routes where !seen.contains(r.id) {
            seen.insert(r.id)
            // At start-up only what is under way flies (the page's resume);
            // after that every new request does, even one answered between polls
            if r.inFlight || (primed && now - r.time.timeIntervalSince1970 < 15) {
                takeOff(r, now: now)
            }
        }
        primed = true
        seen.formIntersection(byID.keys)

        for id in Array(flights.keys) {
            guard var f = flights[id] else { continue }
            for _ in 0..<5 {   // a poll can settle several steps at once
                if !advance(&f, byID[id], now: now) { break }
            }
            f.gone.removeAll { now - ($0.leftAt ?? now) > Self.awayDuration }
            if case .over = f.phase, f.gone.isEmpty, f.carrier == nil {
                flights[id] = nil
            } else {
                flights[id] = f
            }
        }
        hubTicks.removeAll { now - $0 > MagpieArt.wagDuration }
        agentTicks = agentTicks.filter { now - $0.value < Self.tickDuration }
        hits = hits.filter { now - $0.value.at < Self.tagDuration }
    }

    /// Still being played, its last bird not yet gone.
    func isPlaying(_ routeID: Int) -> Bool { flights[routeID] != nil }

    /// 20fps while anything moves, 10 while a dot only waits, nil when idle.
    func frameRate(now: Double) -> Double? {
        let moving = flights.values.contains { f in
            if !f.gone.isEmpty { return true }
            switch f.phase {
            case .toHub, .out, .retreat, .home: return true
            default: return false
            }
        } || hubTicks.contains { $0 <= now } || !agentTicks.isEmpty
            || hits.values.contains { now - $0.at < Self.shakeDuration }
        if moving { return 20 }
        return flights.isEmpty && hits.isEmpty ? nil : 10
    }

    private func takeOff(_ r: MagpieRoute, now: Double) {
        var f = Flight(agent: r.agent)
        f.carrier = Bird(born: now)
        agentTicks[r.agent] = now
        if let first = r.tries.first {
            go(&f, .out(0), [.agent(rev: false), .via(.agentEnd, .memberStart), .member(first.id, rev: false)],
               1.4, now)
            hubTicks.append(now + 1.4 * 0.45)   // passing through magpie
        } else {
            go(&f, .toHub, [.agent(rev: false)], 0.62, now)
        }
        flights[r.id] = f
    }

    private func go(_ f: inout Flight, _ phase: Phase, _ legs: [Leg], _ duration: Double, _ now: Double) {
        f.phase = phase
        f.legs = legs
        f.duration = duration
        f.t0 = now
    }

    private func letGo(_ f: inout Flight, now: Double) {
        guard var b = f.carrier else { return }
        b.leftAt = now
        f.gone.append(b)
        f.carrier = nil
    }

    /// One step of a flight; true when it moved on to another phase.
    private func advance(_ f: inout Flight, _ r: MagpieRoute?, now: Double) -> Bool {
        guard let r else {   // dropped from the trace: nothing of it stays behind
            if case .over = f.phase { return false }
            letGo(&f, now: now)
            f.phase = .over
            return true
        }
        let landed = now - f.t0 >= f.duration
        switch f.phase {
        case .toHub:
            guard landed else { return false }
            f.waitTip = .agentEnd
            f.phase = .waitHub(0)
            hubTicks.append(now)
            return true

        case .waitHub(let i):
            if i < r.tries.count {
                if f.carrier == nil { f.carrier = Bird(born: now) }
                hubTicks.append(now)
                go(&f, .out(i), [.via(f.waitTip ?? .agentEnd, .memberStart), .member(r.tries[i].id, rev: false)],
                   0.9, now)
                return true
            }
            guard r.done else { return false }
            letGo(&f, now: now)
            f.phase = .over
            return true

        case .out(let i):
            guard landed else { return false }
            letGo(&f, now: now)   // it waits at the member while it answers
            f.phase = .held(i)
            return true

        case .held(let i):
            guard i < r.tries.count else { f.phase = .over; return true }
            let tr = r.tries[i]
            guard tr.done else { return false }
            if !tr.failed {
                guard r.done else { return false }   // the reply's tokens come with the route done
                f.dot = .answer
                f.carrier = Bird(born: now)
                goHome(&f, member: tr.id, 1.4, now)
                return true
            }
            hits[tr.id] = (now, Self.tag(tr))
            f.dot = .failed
            f.carrier = Bird(born: now)
            if i + 1 < r.tries.count || !r.done {
                go(&f, .retreat(i), [.member(tr.id, rev: true)], 0.62, now)   // magpie hands it on
            } else {
                goHome(&f, member: tr.id, 1.35, now)   // that was the answer: the agent gets the error
            }
            return true

        case .retreat(let i):
            guard landed else { return false }
            letGo(&f, now: now)
            f.dot = .request
            f.waitTip = .memberStartBack
            f.phase = .waitHub(i + 1)
            hubTicks.append(now)
            return true

        case .home:
            guard landed else { return false }
            letGo(&f, now: now)
            agentTicks[f.agent] = now
            f.phase = .over
            return true

        case .over:
            return false
        }
    }

    private func goHome(_ f: inout Flight, member: String, _ duration: Double, _ now: Double) {
        go(&f, .home, [.member(member, rev: true), .via(.memberStartBack, .agentEndBack), .agent(rev: true)],
           duration, now)
        hubTicks.append(now + duration * 0.55)
    }

    /// The red tag a failed member shows: "429 · 限流".
    private static func tag(_ t: MagpieTry) -> String {
        let s = t.status ?? 0
        let word: String
        switch s {
        case 429: word = "限流"
        case 401, 403: word = "认证失败"
        case 402: word = "额度用尽"
        case 408, 504: word = "超时"
        case 500...599: word = "上游错误"
        case 0: return "失败"
        default: word = "失败"
        }
        return "\(s) · \(word)"
    }

    // MARK: Cards

    /// rttick: magpie's card swells 4% and its logo wags as a request passes.
    func hubPulse(now: Double) -> (scale: CGFloat, wag: Double?) {
        guard let at = hubTicks.last(where: { $0 <= now }) else { return (1, nil) }
        let p = now - at
        return (Self.tick(p), p < MagpieArt.wagDuration ? p / MagpieArt.wagDuration : nil)
    }

    /// An agent's card swells as its request leaves and as the answer lands.
    func agentPulse(_ agent: String, now: Double) -> CGFloat {
        agentTicks[agent].map { Self.tick(now - $0) } ?? 1
    }

    private static func tick(_ dt: Double) -> CGFloat {
        guard dt >= 0, dt < tickDuration else { return 1 }
        return CGFloat(Ease.keyframes([(0, 1), (0.4, 1.04), (1, 1)], dt / tickDuration, Ease.easeOut))
    }

    /// rthit: a member a failure hit shakes (page px, x) and wears its tag a while.
    func memberHit(_ id: String, now: Double) -> (dx: CGFloat, tag: String, tagAlpha: CGFloat)? {
        guard let h = hits[id] else { return nil }
        let dt = now - h.at
        let dx = dt < Self.shakeDuration
            ? Ease.keyframes([(0, 0), (0.2, -5), (0.4, 4), (0.6, -2), (0.8, 1), (1, 0)], dt / Self.shakeDuration, Ease.ease)
            : 0
        let alpha = min(1, dt / 0.25, (Self.tagDuration - dt) / 0.25)
        return (CGFloat(dx), h.tag, CGFloat(max(0, alpha)))
    }

    // MARK: Drawing

    /// Draw one request's flight. The caller clips it under the agents' and
    /// members' cards (the page's sky sits beneath them); it crosses magpie's
    /// own card over the top.
    /// `sky` gives where it may be seen round an area (even-odd): each bird and
    /// dot is clipped to it only round itself, as a clip's cost goes with its
    /// area and shapes.
    func draw(_ ctx: CGContext, routeID: Int, stage s: FlightStage, sky: (CGRect) -> CGPath, color: CGColor,
              ink: CGColor, card: CGColor, now: Double) {
        guard var f = flights[routeID] else { return }
        defer { flights[routeID] = f }
        func inSky(_ p: CGPoint, _ r: CGFloat, _ draw: () -> Void) {
            let box = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            ctx.saveGState()
            ctx.clip(to: box)
            ctx.addPath(sky(box))
            ctx.clip(using: .evenOdd)
            draw()
            ctx.restoreGState()
        }
        let birdR = 44 * s.scale   // a flier's reach, flapping, banked and flying off

        // Birds let go fly off from where they let go, whatever the stage does
        for b in f.gone { inSky(b.at, birdR) { drawBird(ctx, b, scale: s.scale, ink: ink, card: card, now: now) } }

        if case .over = f.phase { return }
        guard let line = polyline(f.legs, agent: f.agent, stage: s) else { return }
        let k = f.duration > 0 ? min(1, max(0, (now - f.t0) / f.duration)) : 1
        let e = (1 - cos(Double.pi * k)) / 2   // eased in and out, as a bird glides to land
        // every wire ends at a card, and the sky is under the cards: a flight
        // starts and ends a dot clear of them, so a dot held is seen whole
        let edge = min(6 * s.scale, line.length / 4)
        let d = edge + CGFloat(e) * (line.length - 2 * edge)
        let pt = line.point(d)

        inSky(pt, 12 * s.scale) { drawDot(ctx, at: pt, f: f, color: color, card: card, scale: s.scale) }

        guard var b = f.carrier else { return }
        let p0 = line.point(d - 3 * s.scale), p1 = line.point(d + 3 * s.scale)
        var vx = p1.x - p0.x, vy = p1.y - p0.y
        if abs(vx) + abs(vy) < 0.01 {
            vx = b.vx ?? (Self.startsBack(f.legs) ? -1 : 1)
            vy = 0
        }
        b.vx = vx
        // heading the way it flies, turned about to fly left, tilted no more than a bird banks
        let aim = max(-24, min(24, atan2(Double(vy), Double(abs(vx))) * 180 / .pi))
        let flip = vx < 0
        if let a = b.angle, b.flip == flip {
            let dt = max(0, now - b.posedAt)
            b.angle = a + (aim - a) * (1 - pow(0.88, dt * 60))   // the page eases 12% a frame at 60fps
        } else {
            b.angle = aim
        }
        b.flip = flip
        b.at = pt
        b.posedAt = now
        f.carrier = b
        inSky(pt, birdR) { drawBird(ctx, b, scale: s.scale, ink: ink, card: card, now: now) }
    }

    private static func startsBack(_ legs: [Leg]) -> Bool {
        switch legs.first {
        case .agent(let rev)?, .member(_, let rev)?: return rev
        default: return false
        }
    }

    private func drawDot(_ ctx: CGContext, at p: CGPoint, f: Flight, color: CGColor, card: CGColor,
                         scale s: CGFloat) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // the page's rtheld breathes it while the member answers; the panel keeps it still
        switch f.dot {
        case .request:   // filled with the agent's colour, glowing
            guard let sprite = glowSprite(color, scale: s) else { return }
            let w = CGFloat(sprite.width)
            ctx.draw(sprite, in: CGRect(x: p.x - w / 2, y: p.y - w / 2, width: w, height: w))
        case .answer, .failed:   // an answer ringed with it; a failure ringed red
            let r = 4 * s
            let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            ctx.setFillColor(f.dot == .failed ? color : card)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(f.dot == .failed ? Color.red : color)
            ctx.setLineWidth(2.25 * s)
            ctx.strokeEllipse(in: rect)
        }
    }

    /// The request's dot with its glow, drawn once per colour: a blurred shadow
    /// is the dearest thing in a frame, and the dot never changes.
    // (one per agent colour: requests of several agents fly at once)
    private var glows: [CGColor: CGImage] = [:]
    private var glowScale: CGFloat = 0

    private func glowSprite(_ color: CGColor, scale s: CGFloat) -> CGImage? {
        if glowScale != s { glows = [:]; glowScale = s }
        if let g = glows[color] { return g }
        let r = 4.5 * s, blur = 6 * s
        let side = Int((2 * (r + blur)).rounded(.up))
        guard let c = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let mid = CGFloat(side) / 2
        c.setShadow(offset: .zero, blur: blur, color: color)
        c.setFillColor(color)
        c.fillEllipse(in: CGRect(x: mid - r, y: mid - r, width: 2 * r, height: 2 * r))
        guard let image = c.makeImage() else { return nil }
        glows[color] = image
        return image
    }

    private func drawBird(_ ctx: CGContext, _ b: Bird, scale s: CGFloat, ink: CGColor, card: CGColor, now: Double) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: b.at.x, y: b.at.y)
        ctx.scaleBy(x: b.flip ? -s : s, y: s)
        ctx.rotate(by: CGFloat((b.angle ?? 0) * .pi / 180))
        var alpha: CGFloat = 1
        if let left = b.leftAt {   // .away: up and off, shrinking, gone
            let p = CGFloat(Ease.cubic(0.3, 0, 0.2, 1, (now - left) / Self.awayDuration))
            ctx.translateBy(x: 14 * p, y: -16 * p)
            ctx.scaleBy(x: 1 - 0.2 * p, y: 1 - 0.2 * p)
            alpha = 1 - p
        } else if now - b.born < Self.comeDuration {   // rtcome: drops in from up behind
            let p = CGFloat(Ease.easeOut((now - b.born) / Self.comeDuration))
            ctx.translateBy(x: -6 * (1 - p), y: -10 * (1 - p))
            ctx.scaleBy(x: 0.85 + 0.15 * p, y: 0.85 + 0.15 * p)
            alpha = p
        }
        guard alpha > 0.01 else { return }
        if alpha < 1 {
            ctx.setAlpha(alpha)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        MagpieArt.flier(ctx, t: now, ink: ink, card: card)
        if alpha < 1 { ctx.endTransparencyLayer() }
    }

    // MARK: Geometry

    private struct Polyline {
        var points: [CGPoint] = []
        var lengths: [CGFloat] = []   // running length at each point
        var length: CGFloat { lengths.last ?? 0 }

        mutating func append(_ p: CGPoint) {
            if let last = points.last {
                let step = hypot(p.x - last.x, p.y - last.y)
                if step < 0.01 { return }
                lengths.append(length + step)
            } else {
                lengths.append(0)
            }
            points.append(p)
        }

        func point(_ d: CGFloat) -> CGPoint {
            guard let first = points.first else { return .zero }
            if d <= 0 { return first }
            var lo = 0, hi = lengths.count - 1
            if d >= lengths[hi] { return points[hi] }
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if lengths[mid] <= d { lo = mid } else { hi = mid }
            }
            let t = (d - lengths[lo]) / max(lengths[hi] - lengths[lo], 0.0001)
            let a = points[lo], b = points[hi]
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    /// The flight's legs laid end to end; nil while one of its cards isn't on stage.
    private func polyline(_ legs: [Leg], agent: String, stage s: FlightStage) -> Polyline? {
        var line = Polyline()
        for leg in legs {
            let cs: [Cubic]
            var rev = false
            switch leg {
            case .agent(let r):
                guard let a = s.agentOut[agent] else { return nil }
                cs = [FlightStage.wire(a, s.hubIn)]
                rev = r
            case .member(let id, let r):
                guard let path = s.memberPath[id], !path.isEmpty else { return nil }
                cs = path
                rev = r
            case .via(let from, let to):
                cs = [via(from, to, stage: s)]
            }
            var pts = cs.flatMap { c in (0...20).map { bezier(c, CGFloat($0) / 20) } }
            if rev { pts.reverse() }
            pts.forEach { line.append($0) }
        }
        return line.points.count > 1 ? line : nil
    }

    private func tip(_ t: Tip, _ s: FlightStage) -> (p: CGPoint, tx: CGFloat) {
        switch t {
        case .agentEnd: return (s.hubIn, 1)
        case .agentEndBack: return (s.hubIn, -1)
        case .memberStart: return (s.hubOut, 1)
        case .memberStartBack: return (s.hubOut, -1)
        }
    }

    /// The way through magpie from one wire to the next: a gentle arc across
    /// it, carrying on the way the flight came in and leaving the way the next
    /// wire goes — or, out the side it came in, a loop round inside.
    private func via(_ from: Tip, _ to: Tip, stage s: FlightStage) -> Cubic {
        let (a, atx) = tip(from, s), (b, btx) = tip(to, s)
        let dx = b.x - a.x, dy = b.y - a.y, dist = hypot(dx, dy)
        if dist < 4 {
            let k = min(s.hubSize.width, s.hubSize.height) * 0.42, m = k * 0.6
            let ny = -atx   // the normal to a horizontal heading
            return (a, CGPoint(x: a.x + atx * k, y: a.y - ny * m),
                    CGPoint(x: b.x - btx * k, y: b.y + ny * m), b)
        }
        let k = dist * 0.38, l = min(16 * s.scale, dist * 0.12)
        let nx = dy / dist, ny = -dx / dist
        return (a, CGPoint(x: a.x + atx * k + nx * l, y: a.y + ny * l),
                CGPoint(x: b.x - btx * k + nx * l, y: b.y + ny * l), b)
    }

    private func bezier(_ c: Cubic, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, cc = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * c.0.x + b * c.1.x + cc * c.2.x + d * c.3.x,
                       y: a * c.0.y + b * c.1.y + cc * c.2.y + d * c.3.y)
    }
}

// index.html's <path id="bird">: the magpie logo, viewBox 0 0 44 44
private let birdData = "M1.5 5.5C1.3 5.7 1.2 6.5 1.2 6.9C1.2 6.9 1.2 7 1.2 7.1C1.1 7.4 1.3 8 1.4 8.3C1.4 8.4 1.5 8.5 1.5 8.7C1.5 8.9 1.7 9 1.8 9.3C2.2 9.9 2.2 10 2.3 10.1C2.4 10.2 2.5 10.3 2.6 10.5C2.8 10.8 3 11.1 3.2 11.3C3.3 11.3 3.4 11.6 3.6 11.8C3.8 12 4.1 12.4 4.2 12.5C4.7 13 5.2 13.7 5.4 13.9C6 14.5 6.5 15.1 6.7 15.3C6.7 15.4 6.9 15.5 6.9 15.7C7.3 15.9 7.7 16.5 7.9 16.8C7.9 16.8 8 16.9 8 16.9C8.1 16.9 8.2 17.2 8.2 17.3C8.2 17.3 8.1 17.2 8.1 17.1C7.9 16.9 7.9 16.9 7.6 16.6C7.5 16.5 7.4 16.5 7.4 16.3C7.2 16.2 6.7 15.7 6.3 15.2C6.1 15.1 6 14.9 6 14.9C5.9 14.8 5.7 14.7 5.7 14.6C5.6 14.5 5.4 14.3 5.3 14.2C5.1 14.1 4.9 13.8 4.7 13.5C4.5 13.3 4.2 13.1 4.1 12.9C4.1 12.9 3.8 12.7 3.8 12.5C3.5 12.3 3 11.8 2.8 11.4C1.8 10.5 0.9 9.6 0.7 9.6C0.6 9.7 0.6 9.8 0.5 10C0.5 10.1 0.6 10.2 0.5 10.3C0.5 10.4 0.6 10.5 0.6 10.6C0.5 10.7 0.5 10.9 0.6 11C0.5 11.1 0.6 11.4 0.6 11.5C0.9 12.9 1.3 13.8 2.8 14.9C2.9 15.1 3.3 15.3 3.4 15.4C3.4 15.5 3.6 15.6 3.7 15.7C4.2 16 6.4 17.8 7 18.4C7.4 18.8 7.4 18.8 7.5 18.9C7.6 19 7.7 19 7.7 19.1C7.7 19.2 7.8 19.2 7.9 19.2C7.9 19.3 8.1 19.4 8.1 19.5C8.2 19.6 8.2 19.7 8.3 19.7C8.3 19.7 8.3 19.7 8.2 19.7C8.2 19.6 8.1 19.6 8 19.6C7.9 19.5 7.9 19.4 7.8 19.4C7.7 19.3 7.6 19.2 7.6 19.2C7.6 19.1 7.5 19 7.3 18.9C7.2 18.9 6.9 18.6 6.7 18.4C6.1 17.8 4.5 16.6 3.5 16C3.4 15.8 3 15.6 2.9 15.5C2.6 15.3 1.5 14.6 0.9 14.3C0.7 14.1 0.6 14.1 0.6 14.2C0.5 14.5 0.8 15.9 0.9 16.1C0.9 16.2 1 16.2 0.9 16.3C1.2 16.8 1.9 17.6 2.7 18.3C2.8 18.5 4 19.2 4.7 19.5C6.2 20.5 6.6 20.7 7.4 21.5C8.2 22.2 8.7 22.7 9.3 23.6C9.5 24.1 9.9 24.4 10.3 25.3C10.4 25.5 10.5 25.8 10.5 25.8C10.7 25.8 10.8 25.7 11 25.4C11.6 25 11.9 24.6 12.3 24.3C12.8 24 13 23.8 13 23.7C13.1 23.7 13.1 23.8 13 24C12 24.8 11 26 10.2 26.9C10.1 27.1 9.9 27.5 9.7 27.7C9.5 27.8 9.4 28 9.4 28C9.4 28 9.3 28.3 9.1 28.5C8.6 29.2 7.7 30.8 7.7 30.9C7.7 31 7.8 31 8.3 30.8C9 30.4 9.5 30.2 10.4 30C11.7 29.6 12.5 29.6 11.6 30C10.5 30.2 9.7 30.6 9.2 31.2C8.8 31.7 8.8 31.7 9.3 31.7C10.1 31.8 10.9 31.9 11.6 32.2C12.8 32.7 13.5 33.1 15.5 34.8C16.4 35.5 17.3 36.2 17.8 36.4C17.9 36.5 18.1 36.7 18.2 36.8C19.1 37.3 21.2 38.1 22.3 38.3C22.4 38.3 22.7 38.3 22.8 38.3C22.8 38.5 23 38.5 23 38.5C23.1 38.5 23.2 38.5 23.3 38.5C23.6 38.6 25.9 38.6 26.1 38.5C26.2 38.5 26.3 38.5 26.4 38.5C26.5 38.5 26.6 38.5 26.7 38.3C26.7 38.3 27 38.3 27.1 38.3C28.3 38.1 30.2 37.3 31.4 36.7C31.5 36.7 31.7 36.4 31.8 36.4C32.2 36.2 33.2 35.4 33.4 35.2C34.2 34.5 35.5 33 35.8 32.6C35.8 32.5 36 32.2 36.1 32C36.4 31.8 36.6 31.4 36.6 31.2C36.7 31.1 36.8 30.9 36.9 30.8C37.2 30.4 37.5 29.6 37.7 29.2C37.7 29.1 37.8 28.7 37.9 28.7C38.1 28.5 38.4 27.1 38.5 26.8C39 25.2 39.1 23.7 39 22.4C39 22.2 38.9 21.9 38.9 21.8C38.9 21.7 38.9 21.6 38.9 21.4C38.6 20.5 38.5 19.9 38.2 19C37.9 18.5 37.5 17.5 37.3 17.2C37 16.8 36.8 15.8 36.8 15.2C36.8 13.8 37.7 12.7 39.6 12.2C40.1 12.1 41.3 11.8 42.1 11.7C43.5 11.5 43.5 11.5 43.4 11.3C42.9 10.7 40.9 9.9 39.2 9.7C37.9 9.5 38.1 9.5 37.6 9C37 8.6 36.4 8 36 7.9C36 7.8 35.8 7.8 35.7 7.7C35.1 7.3 34.2 7 33.1 6.9C32.6 6.7 31.6 6.9 31 7C29.6 7.3 28.3 8 27.3 9.2C26.7 9.8 26.2 10.8 25.7 11.7C25.5 12.1 24.8 13.4 24.7 13.7C24.6 13.9 24.5 14.1 24.1 14.7C23.5 15.7 22.1 16.9 20.6 17.8C20.5 18 20.3 18.2 20.1 18.3C19.7 18.5 19.4 18.8 19.1 19C18.9 19.1 18.7 19.3 18.5 19.4C18 19.8 17.2 20.3 17 20.5C16.9 20.5 16.8 20.6 16.7 20.7C16.3 20.8 16.1 20.9 16 20.9C15.5 20.8 14.9 20.5 14.2 20.2C13.7 19.8 12.7 18.9 12.4 18.6C12.3 18.5 12.2 18.4 12.1 18.2C11.9 18 11.2 17.1 11 16.6C10.9 16.5 10.8 16.4 10.7 16.3C10.7 16.2 10.6 16.1 10.6 15.9C10.5 15.9 10.4 15.7 10.4 15.6C10.3 15.5 10.2 15.2 10.1 15C10 14.8 9.8 14.4 9.7 14.2C9.6 14 9.5 13.7 9.4 13.6C9.4 13.4 9.3 13.2 9.2 13C9.2 12.8 9 12.6 9 12.5C8.9 12.3 8.7 12.1 8.7 12C8.7 12 8.5 11.7 8.5 11.7C8.3 11.2 8.2 10.9 7.5 10C6.4 8.3 4.2 6.4 2.7 5.8C2 5.5 1.6 5.4 1.5 5.5ZM28.4 16.7C29.2 16.9 29.7 17.2 29.9 17.7C30.1 18.2 30 18.9 29.6 19.4C29.2 19.9 28.2 20.9 27.6 21.2C26.8 21.7 25.3 22.4 24.2 22.7C23.9 22.8 23.6 22.9 23.5 22.9C22.8 23.2 20.7 23.7 19.6 24C19 24.2 18.4 24.3 18.1 24.4C17.9 24.4 16.1 24.9 15.3 25.1C14.6 25.2 14.7 25.1 15.7 23.6C16.4 22.7 18.5 20.6 19.4 19.9C20.8 18.8 21.4 18.4 23.2 17.6C23.8 17.4 25.6 16.8 25.9 16.8C25.9 16.8 26.3 16.8 26.6 16.7C26.8 16.7 28.2 16.7 28.4 16.7ZM30.4 20.2C30.5 20.3 30.6 20.6 30.6 20.7C31.7 23.1 33.4 24.6 35.6 25.3C36.1 25.5 36.7 25.7 37.2 25.8C37.7 25.8 37.8 25.9 37.8 26.1C37.7 26.2 37.7 26.3 37.7 26.5C37.7 26.6 37.7 26.8 37.6 27C37.4 28.5 36.8 29.9 36.1 31C36.1 31.2 35.9 31.4 35.9 31.6C35.7 31.9 35.2 32.6 34.7 33.3C32.6 35.6 29.7 37.3 26.6 37.8C26.5 37.8 26.3 37.9 26.2 37.9C25.8 37.9 23.7 37.9 23.3 37.9C23.2 37.9 23 37.8 22.9 37.8C21.1 37.6 19.3 36.8 18 35.7C17.7 35.4 17 34.7 16.8 34.5C16.3 33.8 16.1 33 16.3 32.5C16.5 31.8 16.8 31.6 17.9 31.1C19.1 30.5 19.4 30.4 20.2 30C21.4 29.4 23.2 28.4 23.9 27.9C23.9 27.8 24.2 27.7 24.5 27.6C26.3 26.3 28 24.6 28.9 22.9C29.5 22.2 29.7 21.6 29.9 20.7C30.1 20 30.2 19.9 30.4 20.2Z"
