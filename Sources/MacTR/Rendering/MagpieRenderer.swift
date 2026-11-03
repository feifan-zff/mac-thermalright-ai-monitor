// MagpieRenderer.swift — magpie routing + subscription usage dashboard
//
// Set 2: ROUTING (live request flow) | 订阅用量 (subscription quotas)
// ROUTING mirrors magpie's routing view: agent nodes → magpie → the routing
// group's members, each request played as the page plays it: a magpie flies
// it out along the wires and another brings the answer back (MagpieFlight).
// 订阅用量 lists every subscription account's usage windows.
// Data comes from the local magpie gateway via MagpieCollector.
//
// Two layers keep the animation cheap: a base layer (background, cards,
// nearly all text) redrawn at most once a second when data or clocks change,
// and a per-frame overlay with only what moves (flowing wires, magpies, the
// dot they carry, pulses, live timers, cards that swell or shake) drawn over
// a blit of the base.

import AppKit
import CoreGraphics
import Foundation

final class MagpieRenderer: FrameRenderer, @unchecked Sendable {

    private let collector = MagpieCollector()
    private let pollQueue = DispatchQueue(label: "com.thermalvision.magpie")
    private var pollRunning = false
    private var pollGeneration = 0   // a stop→start within one sleep must not leave two loops
    private let lock = NSLock()
    private var _snap: MagpieSnapshot?

    private let renderMutex = NSLock()
    private var reusableCtx: CGContext?
    private var baseCtx: CGContext?
    private var baseImage: CGImage?
    private var baseKey = ""
    // Usage panel: quotas refresh every 30s and the pace rings move by the
    // minute, yet its text is the bulk of a base rebuild — redrawn for new quotas or the minute.
    private var usageCtx: CGContext?
    private var usageImage: CGImage?
    private var usageKey = ""

    // The routing group's rows as of the base layer: what they say only changes
    // with it, so the overlay's frames reuse them rather than work them out again
    private var groupRows: (key: String, rows: [GroupRow])?

    // The latest request of each model that was routed, kept past the trace's
    // window: one magpie holds before routing it stands on its way meanwhile
    private var lastRouted: [String: MagpieRoute] = [:]
    private var lastRoutedGeneration = -1

    private let flights = FlightDirector()
    private var focusID: Int?
    private var _flightFPS: Double?   // what the flights ask for, as of the last frame

    private enum Pass { case base, overlay }

    // The routing stage's three columns; the gaps between them are the sky a
    // magpie is seen in (it flies under the cards), so they're wide enough for one.
    // Drawn for a 1920-wide screen; a narrower one shrinks the columns (and the
    // magpies) in step, the heights stay.
    private static let designUsageW = 732, designRouteW: CGFloat = 1150
    private var stageScale: CGFloat { min(1, CGFloat(routeW) / Self.designRouteW) }
    private var agentW: Int { Int(184 * stageScale) }
    private var hubW: Int { Int(176 * stageScale) }
    private var wireGap: Int { Int(104 * stageScale) }
    private let hubH = 160
    private var birdScale: CGFloat { 1.6 * stageScale }   // LCD px per page px for the flight

    // Layout
    // 订阅用量 on the left, 路由 on the right
    private let usageX = Layout.margin
    private var usageW: Int { Layout.width * Self.designUsageW / 1920 }
    private var routeX: Int { usageX + usageW + Layout.gap }
    private var routeW: Int { Layout.width - Layout.margin - routeX }

    // The screen size the cached layers were drawn for
    private var canvas = (w: 0, h: 0)

    private let gold = Color.orange

    // The clock in the routing panel's top-right corner: "22:15", and "11月2日 周一" beside it
    private let clockH = 34
    private let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    private let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE"
        return f
    }()

    // MARK: - Collection

    func startMetrics() {
        lock.lock()
        guard !pollRunning else { lock.unlock(); return }
        pollRunning = true
        pollGeneration += 1
        let gen = pollGeneration
        lock.unlock()
        log("[Magpie] Polling \(collector.baseURL)")
        pollQueue.async { [weak self] in self?.pollLoop(gen) }
    }

    func stopMetrics() {
        lock.lock(); pollRunning = false; lock.unlock()
    }

    private func isPolling(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pollRunning && gen == pollGeneration
    }

    private func pollLoop(_ gen: Int) {
        var tick = 0
        var wasOnline: Bool?
        while isPolling(gen) {
            autoreleasepool {
                // Trace every second; today's usage every 15s, quotas every 30s (both on the first tick)
                let snap = collector.collect(quotas: tick % 30 == 0, usage: tick % 15 == 0)
                guard isPolling(gen), snap.generation == MagpieConfig.generation else { return }
                lock.lock(); _snap = snap; lock.unlock()
                if snap.online != wasOnline {
                    log("[Magpie] Gateway \(snap.online ? "online" : "offline: \(snap.error ?? "")") (\(collector.baseURL))")
                    wasOnline = snap.online
                }
                // Retry quotas next tick if the gateway was down
                tick = snap.online ? tick + 1 : 0
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    /// Frames per second the panel wants now, nil to idle at the configured interval:
    /// 20 while a magpie flies, 10 while a request is under way (or just finished).
    func preferredFrameRate() -> Double? {
        lock.lock(); defer { lock.unlock() }
        if let f = _flightFPS { return f }
        guard let s = _snap else { return nil }
        if s.anyInFlight { return 10 }
        if let last = s.routes.last, last.done,
           Date().timeIntervalSince(last.time) * 1000 - Double(last.ms ?? 0) < 2000 {
            return 10
        }
        return nil
    }

    /// The request the hub tells of (its group, its routing). Every request
    /// played is drawn, each agent's; this one only names the hub, and stays
    /// until its answer is home so requests sent at once don't flick it about.
    private func pickFocus(_ snap: MagpieSnapshot) -> MagpieRoute? {
        if let id = focusID, let r = snap.routes.last(where: { $0.id == id }),
           r.inFlight || flights.isPlaying(id) {
            return r
        }
        let r = snap.routes.last(where: { $0.inFlight }) ?? snap.routes.last
        focusID = r?.id
        return r
    }

    /// The base's clock texts tick each second while one counts seconds — a
    /// request under way ("回答中 8s"), one sent less than a minute ago
    /// ("26秒前"), a member back in less than a minute ("40 秒后恢复") — else
    /// each minute (the time, "3分前", "12 分钟后恢复"): idle, the base and the
    /// JPEG made of it stay as they are for a minute.
    private func tick(_ snap: MagpieSnapshot, now: Double) -> Int {
        let at = Date(timeIntervalSince1970: now)
        func soon(_ rest: MagpieRest?) -> Bool { rest.map { $0.until > at && $0.until.timeIntervalSince(at) < 61 } ?? false }
        let seconds = snap.anyInFlight || snap.routes.contains { r in
            at.timeIntervalSince(r.time) < 61 || r.members.contains { soon($0.rest) } || r.tries.contains { soon($0.rest) }
        }
        return seconds ? Int(now) : Int(now / 60) * 60
    }

    // MARK: - Render

    /// Draw for the screen the handshake found. Waits out a frame being drawn, so
    /// none is ever drawn across the change.
    func adaptCanvas(width: Int, height: Int) {
        renderMutex.lock()
        defer { renderMutex.unlock() }
        if Layout.update(width: width, height: height, remember: true) {
            log("[Magpie] Canvas \(width)x\(height)")
        }
    }

    func render() -> CGImage? {
        renderMutex.lock()
        defer { renderMutex.unlock() }

        lock.lock()
        let snap = _snap
        lock.unlock()
        guard let snap, snap.generation == MagpieConfig.generation else { return nil }

        let w = Layout.width
        let h = Layout.height
        if canvas != (w, h) {   // another screen: every layer was drawn for the old size
            canvas = (w, h)
            baseCtx = nil; baseImage = nil; baseKey = ""
            usageCtx = nil; usageImage = nil; usageKey = ""
            reusableCtx = nil
            groupRows = nil
        }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        let now = Date().timeIntervalSince1970

        if lastRoutedGeneration != snap.generation {
            lastRoutedGeneration = snap.generation
            lastRouted = [:]
            focusID = nil
            flights.reset()
            groupRows = nil
            baseKey = ""
            usageKey = ""
        }
        flights.update(snap.routes, now: now)
        let focus = pickFocus(snap)
        let fps = flights.frameRate(now: now)
        lock.lock(); _flightFPS = fps; lock.unlock()
        // Every request still played: under way, or its magpies not yet home —
        // each agent's is drawn, not only the one the hub tells of
        let active = Set(snap.routes.filter { $0.inFlight || flights.isPlaying($0.id) }.map(\.id))

        // Base layer: news (the snapshot's version, not each poll), the requests
        // played, or a clock text ticking over ("26秒前", "回答中 8s", the time)
        let key = "\(snap.version)|\(focus?.id ?? 0)|\(active.sorted())|\(tick(snap, now: now))|\(DisplayShape.cornerRadius)"
        if key != baseKey || baseImage == nil {
            if baseCtx == nil { baseCtx = makeContext() }
            guard let bc = baseCtx else { return nil }
            baseKey = key   // set first: what the base works out is kept under it (groupRows)
            for r in snap.routes where !r.members.isEmpty { lastRouted[r.model] = r }   // news comes with a new base
            bc.saveGState()
            bc.translateBy(x: 0, y: CGFloat(h))
            bc.scaleBy(x: 1, y: -1)
            Draw.gradientBackground(bc)
            renderRouting(bc, snap: snap, focus: focus, active: active, pass: .base, now: now)
            bc.restoreGState()
            drawUsage(bc, snap: snap, now: now)
            maskScreenCorners(bc)
            baseImage = bc.makeImage()
        }
        guard let base = baseImage else { return nil }
        // Nothing moving (no flight, pulse or shake, no request under way): the
        // overlay would draw nothing, so the frame is the base itself — the same
        // image until the base changes, which lets the engine reuse its JPEG
        if fps == nil && !snap.anyInFlight { return base }

        if reusableCtx == nil { reusableCtx = makeContext() }
        guard let ctx = reusableCtx else { return nil }

        // Untransformed same-size .copy blit — CG's memcpy fast path
        ctx.saveGState()
        ctx.setBlendMode(.copy)
        ctx.draw(base, in: full)
        ctx.setBlendMode(.normal)
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        renderRouting(ctx, snap: snap, focus: focus, active: active, pass: .overlay, now: now)
        let image = ctx.makeImage()
        ctx.restoreGState()
        return image
    }

    /// Blit the cached usage panel into `ctx` (unflipped, native coords).
    private func drawUsage(_ ctx: CGContext, snap: MagpieSnapshot, now: Double) {
        // new quotas, or the minute: its pace rings and "3天后" move by minutes at most
        let key = "\(snap.quotaVersion)|\(Int(now / 60))|\(snap.online)|\(DisplayShape.cornerRadius)"
        if key != usageKey || usageImage == nil {
            if usageCtx == nil { usageCtx = makeContext() }
            guard let uc = usageCtx else { return }
            uc.clear(CGRect(x: 0, y: 0, width: Layout.width, height: Layout.height))
            uc.saveGState()
            uc.translateBy(x: 0, y: CGFloat(Layout.height))
            uc.scaleBy(x: 1, y: -1)
            renderUsage(uc, snap: snap)
            uc.restoreGState()
            usageImage = uc.makeImage()
            usageKey = key
        }
        guard let img = usageImage else { return }
        // Transparent outside the panel, so its rounded corners keep the gradient
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: Layout.width, height: Layout.height))
    }

    private func makeContext() -> CGContext? {
        CGContext(data: nil, width: Layout.width, height: Layout.height,
                  bitsPerComponent: 8, bytesPerRow: Layout.width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    // MARK: - Routing panel

    private struct AgentNode {
        let agent: String
        let latest: MagpieRoute
    }

    private func renderRouting(_ ctx: CGContext, snap: MagpieSnapshot, focus: MagpieRoute?, active: Set<Int>,
                               pass: Pass, now t: Double) {
        let px = routeX, py = Layout.panelY, pw = routeW, ph = Layout.panelHeight
        let base = pass == .base
        if base {
            Draw.panel(ctx, x: px, y: py, w: pw, h: ph, radius: panelRadius)
            drawClock(ctx, right: px + pw - 24, top: py + 12, now: Date(timeIntervalSince1970: t), today: snap.today)
        }

        guard snap.online else {
            guard base else { return }
            Draw.centeredText(ctx, "magpie · " + (snap.error ?? "无法连接"), cx: px + pw / 2, y: py + ph / 2 - 30,
                              font: Fonts.system(30, weight: .semibold), color: Color.textS)
            Draw.centeredText(ctx, collector.baseURL, cx: px + pw / 2, y: py + ph / 2 + 14,
                              font: Fonts.mono(18), color: Color.textL)
            return
        }

        // Focus: the request told of (pickFocus), else nothing yet
        guard let focus else {
            guard base else { return }
            Draw.centeredText(ctx, snap.routingNote ?? "等待请求…", cx: px + pw / 2, y: py + ph / 2 - 14,
                              font: Fonts.system(26), color: Color.textL)
            return
        }

        // Agent nodes: every agent with a request under way or still played
        // (that one), the hub's first, then the most recent others — three at most
        var nodes: [AgentNode] = []
        func add(_ r: MagpieRoute) {
            if nodes.count < 3 && !nodes.contains(where: { $0.agent == r.agent }) {
                nodes.append(AgentNode(agent: r.agent, latest: r))
            }
        }
        add(focus)
        for r in snap.routes.reversed() where active.contains(r.id) { add(r) }
        for r in snap.routes.reversed() { add(r) }
        nodes.sort { $0.agent < $1.agent }   // stable positions frame to frame

        let top = py + 14, bottom = py + ph - 14
        let cy = (top + bottom) / 2
        let accent = agentColor(focus.agent)   // the page draws a request's way in its agent's colour

        // Columns
        let agentX = px + 20
        let hubX = agentX + agentW + wireGap
        let memX = hubX + hubW + wireGap, memW = px + pw - 20 - memX
        let hubRect = CGRect(x: hubX, y: cy - hubH / 2, width: hubW, height: hubH)

        // Where the magpies fly: the wires' ends, and the cards they fly under
        var stage = FlightStage()
        stage.scale = birdScale
        stage.hubIn = CGPoint(x: hubRect.minX, y: hubRect.midY)
        stage.hubOut = CGPoint(x: hubRect.maxX, y: hubRect.midY)
        stage.hubSize = hubRect.size
        var cards = [hubRect]

        // Agent nodes (stacked, centered)
        let nodeH = 100, nodeGap = 14
        let nodesH = nodes.count * nodeH + (nodes.count - 1) * nodeGap
        var nodeY = cy - nodesH / 2
        for n in nodes {
            // lit while its request is played (or it is the one the hub tells of)
            let focused = active.contains(n.latest.id) || n.agent == focus.agent
            let rect = CGRect(x: agentX, y: nodeY, width: agentW, height: nodeH)
            let out = CGPoint(x: rect.maxX, y: rect.midY)
            stage.agentOut[n.agent] = out
            cards.append(rect)
            let animated = n.latest.inFlight
            if animated != base {
                link(ctx, from: out, to: stage.hubIn, color: focused ? agentColor(n.agent) : Color.border,
                     animated: animated, t: t)
            }
            let swell = flights.agentPulse(n.agent, now: t)
            if !base && swell > 1 {   // rttick: the card swells as its request leaves, and as the answer lands
                swelled(ctx, rect, swell) {
                    drawAgentNode(ctx, rect: rect, node: n, focused: focused, pass: .base, t: t)
                    drawAgentNode(ctx, rect: rect, node: n, focused: focused, pass: .overlay, t: t)
                }
            } else {
                drawAgentNode(ctx, rect: rect, node: n, focused: focused, pass: pass, t: t)
            }
            nodeY += nodeH + nodeGap
        }

        // The routing groups, as the page's stage lays them out (RoutingGroup):
        // each agent's latest request under a heading naming its way (its
        // routing group, or the provider of its model) — on a way two share, the
        // one played (the hub's first) — and under it its members in the group's order, three
        // or more accounts of one provider and model folded under a heading,
        // each heading's rows hung under it on a lane
        var staged: [MagpieRoute] = [], wayAt: [String: Int] = [:]
        func rank(_ r: MagpieRoute) -> Int { r.id == focus.id ? 2 : active.contains(r.id) ? 1 : 0 }
        for n in nodes {
            guard let r = routedOrStandIn(n.latest) else { continue }
            let key = RoutingGroup.way(r).key
            if let i = wayAt[key] {
                if rank(r) > rank(staged[i]) { staged[i] = r }
            } else {
                wayAt[key] = staged.count
                staged.append(r)
            }
        }
        let headed = staged.count > 1 || staged.contains { $0.groupName != nil }
        // the ways lit: each one a request is played on, and the hub's
        let litWays = Set(staged.filter { active.contains($0.id) || $0.id == focus.id }.map { RoutingGroup.way($0).key })
        let all: [GroupRow]
        if let g = groupRows, g.key == baseKey {
            all = g.rows
        } else {
            all = RoutingGroup.stage(staged, headed: headed, now: Date(timeIntervalSince1970: t), mask: maskAccount,
                                     cycles: { cycles(of: $0, in: snap.quotas) })
            groupRows = (baseKey, all)
        }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // the way each row is on: its heading's agent colours its lit wires
        var wayOf: [String: String] = [:], agentOf: [String: String] = [:]
        for row in all {
            let k = row.way?.key ?? row.parent.flatMap { wayOf[$0] } ?? row.id.components(separatedBy: ">")[0]
            wayOf[row.id] = k
            agentOf[row.id] = row.way?.agent ?? row.parent.flatMap { agentOf[$0] } ?? focus.agent
        }

        // the members' column starts under the clock in the panel's corner
        let rowsTop = top + clockH, avail = bottom - rowsTop, rowGap = 6, minRowH = 40, indent = 28
        let maxRows = (avail + rowGap) / (minRowH + rowGap)
        // What fits, most open first: every heading open (a fold of fewer than
        // six accounts, as the page opens one), then the folds shut, then only
        // the lit ways open, then the headings alone
        func shown(folds: Bool, ways: (String) -> Bool) -> [GroupRow] {
            all.filter { row in
                var p = row.parent
                while let id = p, let up = byID[id] {
                    if up.isWay && !ways(wayOf[id] ?? "") { return false }
                    if up.isFold && !(folds && up.members.count < RoutingGroup.long) { return false }
                    p = up.parent
                }
                return true
            }
        }
        let fits = [shown(folds: true) { _ in true }, shown(folds: false) { _ in true },
                    shown(folds: false) { litWays.contains($0) }, shown(folds: false) { _ in false }]
        var visible = fits.first { $0.count <= maxRows } ?? fits[fits.count - 1]
        var hiddenCount = 0
        if visible.count > maxRows {   // still too many: the last are counted instead
            hiddenCount = visible.count - (maxRows - 1)
            visible = Array(visible.prefix(maxRows - 1))
        }
        let open = Set(visible.compactMap(\.parent))
        let n = visible.count + (hiddenCount > 0 ? 1 : 0)
        let rowH = n > 0 ? min(52, (avail - (n - 1) * rowGap) / n) : 52
        var rowY = max(rowsTop, cy - (n * rowH + max(0, n - 1) * rowGap) / 2)   // level with magpie if they fit

        // Each row's card, and its wire from magpie: a top row's straight from
        // it, a row under a heading's on down the heading's lane
        var rows: [(row: GroupRow, rect: CGRect, wire: [Cubic], inFocus: Bool, color: CGColor)] = []
        var pathOf: [String: [Cubic]] = [:], rectOf: [String: CGRect] = [:]
        for row in visible {
            let inset = row.depth * indent
            let rect = CGRect(x: memX + inset, y: rowY, width: memW - inset, height: rowH)
            let into = CGPoint(x: rect.minX, y: rect.midY)
            var wire = [FlightStage.wire(stage.hubOut, into)], path = wire
            if let p = row.parent, let pr = rectOf[p], let up = pathOf[p] {
                wire = lane(from: pr, to: rect)   // its own stretch; its heading draws the rest
                path = up + wire
            }
            rows.append((row, rect, wire, litWays.contains(wayOf[row.id] ?? ""), agentColor(agentOf[row.id] ?? focus.agent)))
            pathOf[row.id] = path
            rectOf[row.id] = rect
            cards.append(rect)
            rowY += rowH + rowGap
        }
        // where a request to a member flies: its row, or the heading folded over
        // it — on each way apart, as one account can be in two groups
        var pathsByWay: [String: [String: [Cubic]]] = [:]
        for r in all where r.kind == .member {
            var id: String? = r.id
            while let i = id, pathOf[i] == nil { id = byID[i]?.parent }
            if let i = id, let p = pathOf[i] { pathsByWay[wayOf[r.id] ?? "", default: [:]][r.member.id] = p }
        }

        // No one weighed (the page's noneWhy): magpie holds the request before
        // routing it — masking it, or still reading it — or nothing took it.
        // Ghost rows hold the column meanwhile, a light sweeping them while it waits.
        let ghostH = 52, ghostN = all.isEmpty ? 3 : 0
        let ghostTop = max(rowsTop, cy - (ghostN * ghostH + (ghostN - 1) * rowGap) / 2)
        let ghosts = (0..<ghostN).map {
            CGRect(x: memX, y: ghostTop + $0 * (ghostH + rowGap), width: memW, height: ghostH)
        }
        cards += ghosts

        // The sky round an area: the area, but the cards on it — a wire under
        // them is hidden, and a magpie under all but magpie's own card, which it
        // flies over. Only the cards it meets go in: a clip costs with its shapes.
        func sky(_ r: CGRect, under: [CGRect]) -> CGPath {
            let p = CGMutablePath()
            p.addRect(r)
            for c in under where c.intersects(r) {
                p.addPath(CGPath(roundedRect: c.insetBy(dx: -1, dy: -1), cornerWidth: 15, cornerHeight: 15, transform: nil))
            }
            return p
        }
        let birdCards = cards.filter { $0 != hubRect }

        // Wires first, the cards over them (a lane starts under its heading).
        // The overlay's flowing ones are each clipped to the sky round itself.
        let wires = rows.filter { ($0.row.state == .flying) != base }
        for w in wires {
            ctx.saveGState()
            if !base {
                let box = hull(w.wire).insetBy(dx: -4, dy: -4)
                ctx.clip(to: box)
                ctx.addPath(sky(box, under: cards))
                ctx.clip(using: .evenOdd)
            }
            strokeWire(ctx, w.wire, state: shownState(w.row, inFocus: w.inFocus), color: w.color, t: t)
            ctx.restoreGState()
        }

        for (row, rect, _, inFocus, _) in rows {
            let isOpen = open.contains(row.id), state = shownState(row, inFocus: inFocus)
            if !base, inFocus, let hit = hit(for: row, open: isOpen, t: t), hit.dx != 0 {
                // rthit: a failure shakes it off its place — cleared to the panel first
                ctx.setFillColor(Color.panelBG)
                ctx.fill(rect.insetBy(dx: -2, dy: -2))
                ctx.saveGState()
                ctx.translateBy(x: hit.dx * birdScale, y: 0)
                drawRow(ctx, rect: rect, row: row, state: state, open: isOpen, pass: .base)
                ctx.restoreGState()
            } else {
                drawRow(ctx, rect: rect, row: row, state: state, open: isOpen, pass: pass)
            }
        }

        if base {
            if hiddenCount > 0 {
                Draw.text(ctx, "+\(hiddenCount) 个成员", x: memX + 12, y: rowY + 4,
                          font: Fonts.system(15), color: Color.textL)
            }
            if !ghosts.isEmpty {
                for g in ghosts {
                    strokeWire(ctx, [FlightStage.wire(stage.hubOut, CGPoint(x: g.minX, y: g.midY))],
                               state: .left, color: accent, t: t)
                }
                for (i, g) in ghosts.enumerated() { drawGhost(ctx, g, i) }
                // what holds it, as the page's noneWhy says it
                let why = focus.done
                    ? focus.error.map { "没有成员接下这个请求：" + $0 } ?? "没有成员能接 \(focus.model)"
                    : focus.phase == "redact" ? "magpie 正在为这个请求脱敏（设置 › 隐私），之后再挑选成员"
                    : "magpie 还没为这个请求挑好成员"
                let font = Fonts.system(15)
                Draw.text(ctx, truncate(why, font: font, maxW: CGFloat(memW - 28)), x: memX + 14,
                          y: Int(ghosts[ghosts.count - 1].maxY) + 12, font: font, color: focus.done ? Color.red : Color.textL)
            }
            // magpie hub (drawn last so links tuck under it)
            drawHub(ctx, rect: hubRect, focus: focus, wag: nil)
            return
        }

        // magpie swells and its logo wags as a request passes through it
        let pulse = flights.hubPulse(now: t)
        if pulse.scale > 1 || pulse.wag != nil {
            swelled(ctx, hubRect, pulse.scale) {
                drawHub(ctx, rect: hubRect, focus: focus, wag: pulse.wag)
            }
        }

        if focus.inFlight {
            for (i, g) in ghosts.enumerated() { shimmerGhost(ctx, g, i, t: t) }
        }

        // The flights, every request played (each agent's, in its colour, along
        // its own way): under the agents' and members' cards, over magpie's
        for r in snap.routes where active.contains(r.id) {
            var s = stage
            if let w = routedOrStandIn(r).map({ RoutingGroup.way($0).key }) { s.memberPath = pathsByWay[w] ?? [:] }
            flights.draw(ctx, routeID: r.id, stage: s, sky: { sky($0, under: birdCards) }, color: agentColor(r.agent),
                         ink: Color.textW, card: Color.panelBG, now: t)
        }

        // A failed member's tag, over its row's top edge
        for (row, rect, _, inFocus, _) in rows where inFocus {
            if let hit = hit(for: row, open: open.contains(row.id), t: t), hit.tagAlpha > 0 {
                drawHitTag(ctx, hit.tag, card: rect, alpha: hit.tagAlpha)
            }
        }
    }

    /// A request as the stage shows it: routed, itself; held before routing
    /// (masked, or still read), on the way its model went last — that group's
    /// members, none of them tried yet; else nothing to show of it.
    private func routedOrStandIn(_ r: MagpieRoute) -> MagpieRoute? {
        if !r.members.isEmpty { return r }
        guard !r.done, let c = lastRouted[r.model] else { return nil }
        return MagpieRoute(id: r.id, seq: r.seq, time: r.time, agent: r.agent, model: r.model, provider: c.provider,
                           groupID: c.groupID, groupRef: c.groupRef, groupName: c.groupName, routing: c.routing,
                           members: c.members, left: [], groupMembers: c.groupMembers, tries: r.tries,
                           phase: r.phase, error: r.error, done: r.done, status: r.status, ms: r.ms,
                           tokens: r.tokens, out: r.out, folder: r.folder)
    }

    /// How a row is drawn: as it is for the focused request; another agent's
    /// request, done, is told of but not lit — only one answering now is.
    private func shownState(_ row: GroupRow, inFocus: Bool) -> GroupRow.State {
        inFocus || row.state != .on ? row.state : .idle
    }

    /// A failure on a row: its member's, or, under a heading shut, one of the heading's.
    private func hit(for row: GroupRow, open: Bool, t: Double) -> (dx: CGFloat, tag: String, tagAlpha: CGFloat)? {
        if row.kind == .member { return flights.memberHit(row.member.id, now: t) }
        guard !open else { return nil }
        for id in row.members { if let h = flights.memberHit(id, now: t) { return h } }
        return nil
    }

    /// The page's lane from a fold's heading down to one of its accounts:
    /// in from the heading's left edge, down beside the accounts, in to this one.
    private func lane(from p: CGRect, to a: CGRect) -> [Cubic] {
        let x = p.minX + 14, r: CGFloat = 14
        func quad(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint) -> Cubic {
            (p0, CGPoint(x: p0.x + (c.x - p0.x) * 2 / 3, y: p0.y + (c.y - p0.y) * 2 / 3),
             CGPoint(x: p1.x + (c.x - p1.x) * 2 / 3, y: p1.y + (c.y - p1.y) * 2 / 3), p1)
        }
        let top = CGPoint(x: x, y: p.midY + r), bottom = CGPoint(x: x, y: a.midY - r)
        return [quad(CGPoint(x: p.minX, y: p.midY), CGPoint(x: x, y: p.midY), top),
                (top, top, bottom, bottom),
                quad(bottom, CGPoint(x: x, y: a.midY), CGPoint(x: a.minX, y: a.midY))]
    }

    /// What a chain of curves can reach: the box round all their points and controls.
    private func hull(_ path: [Cubic]) -> CGRect {
        let pts = path.flatMap { [$0.0, $0.1, $0.2, $0.3] }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return .null }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// A member's wire, as the page draws it: lit in the agent's colour for the
    /// one that answered, flowing while it answers, faint and dashed for one
    /// resting or left out, a quiet line otherwise.
    private func strokeWire(_ ctx: CGContext, _ path: [Cubic], state: GroupRow.State, color: CGColor, t: Double) {
        guard let first = path.first else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.move(to: first.0)
        for c in path { ctx.addCurve(to: c.3, control1: c.1, control2: c.2) }
        let s = birdScale
        switch state {
        case .flying:
            ctx.setStrokeColor(color)
            ctx.setLineWidth(2.5)
            ctx.setLineDash(phase: CGFloat(-(t / 0.7 * 8 * Double(s)).truncatingRemainder(dividingBy: 8 * Double(s))),
                            lengths: [3 * s, 5 * s])
        case .on:
            ctx.setStrokeColor(color)
            ctx.setLineWidth(2)
        case .rest, .left:
            ctx.setStrokeColor(Color.border.copy(alpha: 0.45) ?? Color.border)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [2 * s, 6 * s])
        case .idle:
            ctx.setStrokeColor(Color.border)
            ctx.setLineWidth(1.5)
        }
        ctx.strokePath()
    }

    /// Draw scaled round a card's centre (rttick's swell).
    private func swelled(_ ctx: CGContext, _ rect: CGRect, _ s: CGFloat, _ draw: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -rect.midX, y: -rect.midY)
        draw()
        ctx.restoreGState()
    }

    /// "429 · 限流" in red over a member's top-right edge, rising in as it shows.
    private func drawHitTag(_ ctx: CGContext, _ tag: String, card rect: CGRect, alpha: CGFloat) {
        let font = Fonts.system(15, weight: .semibold)
        let w = textWidth(tag, font: font) + 18
        let r = CGRect(x: rect.maxX - 14 - w, y: rect.minY - 13 + (1 - alpha) * 5, width: w, height: 24)
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setFillColor(Color.red)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 7, cornerHeight: 7, transform: nil))
        ctx.fillPath()
        Draw.text(ctx, tag, x: Int(r.minX) + 9, y: Int(r.minY) + 3, font: font,
                  color: CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.restoreGState()
    }

    private func drawAgentNode(_ ctx: CGContext, rect: CGRect, node: AgentNode,
                               focused: Bool, pass: Pass, t: Double) {
        let r = node.latest
        let x = Int(rect.minX) + 16
        let base = pass == .base
        if base {
            let accent = agentColor(node.agent)
            card(ctx, rect, border: focused ? accent : Color.border, width: focused ? 2 : 1)
            let font = Fonts.system(22, weight: .bold)
            Draw.text(ctx, truncate(agentName(node.agent), font: font, maxW: rect.width - 32),
                      x: x, y: Int(rect.minY) + 12, font: font, color: Color.textW)
            Draw.text(ctx, truncate(shortModel(r.model), font: Fonts.mono(14), maxW: rect.width - 32),
                      x: x, y: Int(rect.minY) + 72, font: Fonts.mono(14), color: Color.textL)
        }

        // Status line: still, and in whole seconds while answering, so it ticks
        // with the base layer (rebuilt each second) rather than every frame
        guard base else { return }
        let y = Int(rect.minY) + 46

        // Status dot + text
        let dotColor: CGColor
        let status: String
        if r.inFlight {
            dotColor = gold
            let s = Int(max(0, Date(timeIntervalSince1970: t).timeIntervalSince(r.time)))
            status = "回答中 " + (s < 60 ? "\(s)s" : "\(s / 60)m\(s % 60)s")
        } else if r.failed {
            dotColor = Color.red
            status = "失败 \(r.status ?? 0) · " + ago(r.time)
        } else {
            dotColor = Color.green.copy(alpha: 0.8) ?? Color.green
            status = seconds(Double(r.ms ?? 0) / 1000) + " · " + ago(r.time)
        }
        ctx.setFillColor(dotColor)
        ctx.fillEllipse(in: CGRect(x: x, y: y + 6, width: 10, height: 10))
        Draw.text(ctx, status, x: x + 18, y: y, font: Fonts.system(16), color: Color.textS)
    }

    /// The time, right-aligned at `right`, its date dimmer to its left, and
    /// left of that what the gateway's requests used today: "今日 3.70M tokens · $100".
    private func drawClock(_ ctx: CGContext, right: Int, top: Int, now: Date, today: MagpieToday?) {
        let timeFont = Fonts.system(26, weight: .semibold), dayFont = Fonts.system(16)
        let time = timeFormat.string(from: now), day = dayFormat.string(from: now)
        rightText(ctx, time, right: right, y: top, font: timeFont, color: Color.textW)
        let dayRight = right - Int(textWidth(time, font: timeFont)) - 12
        rightText(ctx, day, right: dayRight, y: top + 8, font: dayFont, color: Color.textL)

        guard let today else { return }
        let bold = Fonts.system(18, weight: .semibold)
        var parts: [(String, NSFont, CGColor)] = [("今日 ", dayFont, Color.textL), (tokenCount(today.tokens), bold, Color.textW),
                                                   (" tokens", dayFont, Color.textL)]
        if let cost = costText(today) {
            parts += [("  ·  ", dayFont, Color.textL), (cost, bold, Color.textW)]
        }
        var x = CGFloat(dayRight) - textWidth(day, font: dayFont) - 24
            - parts.reduce(0) { $0 + textWidth($1.0, font: $1.1) }
        for (s, font, color) in parts {
            Draw.text(ctx, s, x: Int(x), y: top + (font === bold ? 6 : 8), font: font, color: color)
            x += textWidth(s, font: font)
        }
    }

    /// "3.70M", "812K", "1.25B": a token count as the usage page shortens it.
    private func tokenCount(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1e9 { return String(format: "%.2fB", d / 1e9) }
        if d >= 1e6 { return String(format: "%.2fM", d / 1e6) }
        if d >= 1e4 { return String(format: "%.0fK", d / 1e3) }
        if d >= 1e3 { return String(format: "%.1fK", d / 1e3) }
        return "\(n)"
    }

    /// The usage page's cost: "$100", "$12.34", "$0.123", "+" when some
    /// requests had no price; none when nothing could be priced.
    private func costText(_ t: MagpieToday) -> String? {
        guard let c = t.cost, c > 0 || t.unpriced == 0 else { return nil }
        let s = c >= 100 ? String(format: "%.0f", c) : c >= 1 ? String(format: "%.2f", c) : String(format: "%.3f", c)
        return "$" + s + (t.unpriced > 0 ? "+" : "")
    }

    private func drawHub(_ ctx: CGContext, rect: CGRect, focus: MagpieRoute, wag: Double?) {
        card(ctx, rect, border: Color.textS, width: 2)
        let cx = Int(rect.midX)
        var y = Int(rect.minY) + 14

        // magpie's logo, as on its page; it wags as a request passes (wag 0…1)
        MagpieArt.logo(ctx, in: CGRect(x: CGFloat(cx) - 19, y: CGFloat(y), width: 38, height: 38),
                       color: Color.textW, wag: wag)
        y += 40
        Draw.centeredText(ctx, "magpie", cx: cx, y: y,
                          font: Fonts.system(24, weight: .bold), color: Color.textW)
        y += 32
        // None weighed and no group: what magpie is doing with it, as the page's
        // head says (waitWord), and no routing chip — there is no routing to tell
        let none = focus.members.isEmpty && focus.groupName == nil
        let sub = focus.groupName
            ?? (!none ? "直连" : focus.done ? "未路由" : focus.phase == "redact" ? "脱敏中…" : "路由中…")
        Draw.centeredText(ctx, truncate(sub, font: Fonts.system(16), maxW: rect.width - 24),
                          cx: cx, y: y, font: Fonts.system(16), color: Color.textS)
        y += 26
        guard !none else { return }

        // Routing chip
        let chip = routingLabel(focus.routing) + " ›"
        let font = Fonts.system(16, weight: .bold)
        let cw = textWidth(chip, font: font) + 26
        let chipRect = CGRect(x: CGFloat(cx) - cw / 2, y: CGFloat(y), width: cw, height: 26)
        ctx.setFillColor(Color.textW)
        ctx.addPath(CGPath(roundedRect: chipRect, cornerWidth: 13, cornerHeight: 13, transform: nil))
        ctx.fillPath()
        Draw.centeredText(ctx, chip, cx: cx, y: y + 3, font: font, color: Color.bgTop)
    }

    /// One row of the stage, on one line (the page's .rt-accts li, cut to what
    /// the panel has room for): a dot, its provider's icon, the account (a
    /// fold: its provider and how many), its model, and what it says; a way's
    /// heading names its group (or provider), what agents send to it, and its
    /// routing. White-edged for the one answering or that answered, dashed and
    /// dim for one resting, dotted and dim for one left out. Nothing on it
    /// moves: the wire flowing into it says it is answering.
    private func drawRow(_ ctx: CGContext, rect: CGRect, row: GroupRow, state: GroupRow.State,
                         open: Bool, pass: Pass) {
        guard pass == .base else { return }
        let w = row.member
        let on = state == .on || state == .flying
        card(ctx, rect, border: on ? Color.textW : Color.border, width: on ? 2 : 1,
             dash: state == .rest ? [7, 5] : state == .left ? [2, 4] : nil)

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setAlpha(state == .rest ? 0.5 : state == .left ? 0.45 : 1)

        let shuts = row.isFold || row.isWay
        let x = rect.minX + 14, cy = rect.midY
        var right = rect.maxX - (shuts ? 38 : 16)
        let titleFont = Fonts.system(18, weight: .semibold), subFont = Fonts.system(15), mono = Fonts.mono(14)
        let statusFont = row.timed ? Fonts.system(15, weight: .bold) : subFont   // a countdown stands out
        var textX: CGFloat, end: CGFloat
        let status = shuts && open ? row.openStatus : row.status

        if let way = row.way {
            // A way's heading: the group's fan (or the provider's icon), its
            // name, what agents send to it, and its routing as a chip
            if way.isGroup { fan(ctx, in: CGRect(x: x, y: cy - 10, width: 20, height: 20)) }
            else { drawIcon(ctx, w, in: CGRect(x: x, y: cy - 10, width: 20, height: 20)) }
            textX = x + 30
            let title = truncate(way.name, font: titleFont, maxW: (right - textX) * 0.4)
            Draw.text(ctx, title, x: Int(textX), y: Int(cy) - 12, font: titleFont, color: Color.textW)
            textX += textWidth(title, font: titleFont) + 10
            if let routing = way.routing {
                let label = routingLabel(routing), font = Fonts.system(14, weight: .semibold)
                let pill = CGRect(x: right - textWidth(label, font: font) - 20, y: cy - 12,
                                  width: textWidth(label, font: font) + 20, height: 24)
                ctx.setFillColor(Color.barBG)
                ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 12, cornerHeight: 12, transform: nil))
                ctx.fillPath()
                Draw.text(ctx, label, x: Int(pill.minX) + 10, y: Int(pill.minY) + 3, font: font, color: Color.textS)
                right = pill.minX - 10
            }
            // what it says goes before the name agents send to it
            let saying = status.isEmpty ? 0 : min(textWidth(status, font: subFont), 200) + 14
            let ref = truncate(way.ref, font: mono, maxW: max(40, min(220, right - textX - 14 - saying)))
            Draw.text(ctx, ref, x: Int(textX), y: Int(cy) - 9, font: mono, color: Color.textL)
            end = textX + textWidth(ref, font: mono)
        } else {
            // Dot: filled for the one answering or that answered
            let dot = CGRect(x: x, y: cy - 5, width: 10, height: 10)
            if on {
                ctx.setFillColor(Color.textW)
                ctx.fillEllipse(in: dot)
            } else {
                ctx.setStrokeColor(Color.textL)
                ctx.setLineWidth(1.5)
                ctx.strokeEllipse(in: dot.insetBy(dx: 0.75, dy: 0.75))
            }
            drawIcon(ctx, w, in: CGRect(x: x + 20, y: cy - 10, width: 20, height: 20))

            // The account (a fold: its provider, and how many), then its model
            textX = x + 50
            let title = truncate(row.isFold ? (w.name.isEmpty ? w.provider : w.name) : RoutingGroup.who(w, mask: maskAccount),
                                 font: titleFont, maxW: (right - textX) * 0.45)
            Draw.text(ctx, title, x: Int(textX), y: Int(cy) - 12, font: titleFont, color: on ? Color.textW : Color.textS)
            textX += textWidth(title, font: titleFont) + 8
            let sub = row.isFold ? "\(row.members.count) 个\(w.kind == "key" ? " Key" : "账号")" : w.fallback ? "备用" : ""
            if !sub.isEmpty {
                Draw.text(ctx, sub, x: Int(textX), y: Int(cy) - 10, font: subFont, color: Color.textL)
                textX += textWidth(sub, font: subFont) + 8
            }
            let model = truncate(w.model, font: mono, maxW: max(40, min(200, right - textX - 14)))
            let chip = CGRect(x: textX, y: cy - 11, width: textWidth(model, font: mono) + 14, height: 22)
            ctx.setFillColor(Color.barBG)
            ctx.addPath(CGPath(roundedRect: chip, cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
            Draw.text(ctx, model, x: Int(chip.minX) + 7, y: Int(chip.minY) + 2, font: mono, color: Color.textS)
            end = chip.maxX
        }

        // The allowance used in its current period, as a bar along the card's
        // foot: an account's own (a heading or a fold tells of no one account)
        if row.kind == .member, let used = row.used {
            let pct = min(max(used, 0), 100)
            Draw.bar(ctx, x: Int(rect.minX) + 14, y: Int(rect.maxY) - 9, w: Int(rect.width) - 28, h: 4,
                     percent: pct, color: Color.forPercent(pct))
        }

        // What it says, right-aligned in what room is left
        let room = right - end - 14
        if !status.isEmpty && room > 30 {
            let color: CGColor
            switch state {
            case .rest:
                ctx.setAlpha(0.85)   // .rest em: red, and less dim than the rest of the row
                color = Color.red
            case .on, .flying: color = Color.textW
            default: color = row.low ? Color.textS : Color.textL
            }
            rightText(ctx, truncate(status, font: statusFont, maxW: room), right: Int(right), y: Int(cy) - 10,
                      font: statusFont, color: color)
        }
        if shuts { chevron(ctx, center: CGPoint(x: rect.maxX - 22, y: cy), up: open) }
    }

    /// A routing group's mark, the page's FAN: one point fanning out to three.
    private func fan(_ ctx: CGContext, in r: CGRect) {
        let a = CGPoint(x: r.minX + 4, y: r.midY)
        let ends = [CGPoint(x: r.maxX - 4, y: r.minY + 4), CGPoint(x: r.maxX - 4, y: r.midY),
                    CGPoint(x: r.maxX - 4, y: r.maxY - 4)]
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(Color.textS)
        ctx.setLineWidth(1.6)
        for e in ends {
            ctx.move(to: a)
            ctx.addCurve(to: e, control1: CGPoint(x: a.x + 6, y: a.y), control2: CGPoint(x: e.x - 6, y: e.y))
        }
        ctx.strokePath()
        for p in [a] + ends {
            ctx.setFillColor(Color.panelBG)
            ctx.fillEllipse(in: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
            ctx.strokeEllipse(in: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
        }
    }

    /// A ghost row, holding the members' column while no one is weighed: a
    /// row's shape — dot, icon, account, model, what it says — in blanks.
    private func drawGhost(_ ctx: CGContext, _ rect: CGRect, _ i: Int) {
        card(ctx, rect, border: Color.border, width: 1, dash: [6, 5])
        let dot = CGRect(x: rect.minX + 14, y: rect.midY - 5, width: 10, height: 10)
        ctx.setStrokeColor(Color.textD)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: dot.insetBy(dx: 0.75, dy: 0.75))
        ctx.setFillColor(Color.barBG)
        ctx.addPath(ghostBars(rect, i))
        ctx.fillPath()
    }

    /// A ghost row's blanks: icon, account, model chip, and what it says on the right.
    private func ghostBars(_ rect: CGRect, _ i: Int) -> CGPath {
        let x = rect.minX + 14, cy = rect.midY
        let account = [0.30, 0.24, 0.34][i % 3] * rect.width
        let path = CGMutablePath()
        for b in [CGRect(x: x + 20, y: cy - 10, width: 20, height: 20),
                  CGRect(x: x + 50, y: cy - 8, width: account, height: 16),
                  CGRect(x: x + 60 + account, y: cy - 11, width: 120, height: 22),
                  CGRect(x: rect.maxX - 16 - 90, y: cy - 7, width: 90, height: 14)] {
            path.addRoundedRect(in: b, cornerWidth: min(6, b.height / 2), cornerHeight: min(6, b.height / 2))
        }
        return path
    }

    /// The light sweeping a ghost row's blanks left to right while the request
    /// waits; the rows a beat apart, as a list loading reads.
    private func shimmerGhost(_ ctx: CGContext, _ rect: CGRect, _ i: Int, t: Double) {
        let period = 1.6, band: CGFloat = 180
        let p = CGFloat(((t - Double(i) * 0.15) / period).truncatingRemainder(dividingBy: 1) + 1)
            .truncatingRemainder(dividingBy: 1)
        let x = rect.minX - band + (rect.width + 2 * band) * p
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.addPath(ghostBars(rect, i))
        ctx.clip()
        ctx.drawLinearGradient(shimmer, start: CGPoint(x: x, y: 0), end: CGPoint(x: x + band, y: 0), options: [])
    }

    private let shimmer = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0), CGColor(red: 1, green: 1, blue: 1, alpha: 0.16),
                 CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
        locations: [0, 0.5, 1])!

    /// A provider's icon: magpie's own logo for a magpie gateway, else its
    /// initial on its colour.
    private func drawIcon(_ ctx: CGContext, _ w: MagpieMember, in r: CGRect) {
        if w.icon == "magpie" {
            MagpieArt.logo(ctx, in: r, color: Color.textW)
            return
        }
        ctx.setFillColor(providerColor(w.provider))
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
        let name = w.name.isEmpty ? w.provider : w.name
        Draw.centeredText(ctx, String(name.prefix(1)).uppercased(), cx: Int(r.midX), y: Int(r.minY) + 1,
                          font: Fonts.system(13, weight: .bold), color: Color.bgTop)
    }

    private func providerColor(_ provider: String) -> CGColor {
        switch provider {
        case let p where p.hasPrefix("claude"): return Color.claude
        case let p where p.hasPrefix("codex") || p.hasPrefix("openai"): return Color.blue
        case let p where p.hasPrefix("devin"): return Color.green
        case let p where p.hasPrefix("antigravity") || p.hasPrefix("gemini"): return Color.purple
        case let p where p.hasPrefix("kimi"): return Color.cyan
        case let p where p.hasPrefix("cursor"): return Color.cursor
        default: return Color.textS
        }
    }

    /// A fold's chevron: up while it is open, as the page turns it.
    private func chevron(_ ctx: CGContext, center c: CGPoint, up: Bool) {
        let dy: CGFloat = up ? -3 : 3
        ctx.setStrokeColor(Color.textL)
        ctx.setLineWidth(1.8)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: c.x - 6, y: c.y - dy))
        ctx.addLine(to: CGPoint(x: c.x, y: c.y + dy))
        ctx.addLine(to: CGPoint(x: c.x + 6, y: c.y - dy))
        ctx.strokePath()
    }

    // MARK: - Usage panel

    /// One card per subscription type, showing the account in use right now as two
    /// circles: the short window (5h) on the left, the long one (7d / month) on the
    /// right. Each circle is a pair of concentric rings — usage outside, time
    /// elapsed in the window (pace) as a thin line inside.
    private struct UsageCard {
        let name: String
        let user: String?                   // already masked for display
        let short: MagpieQuotaWindow?
        let long: MagpieQuotaWindow?
        let healthy: Bool
    }

    private func usageCards(_ quotas: [MagpieQuota]) -> [UsageCard] {
        // Dedupe: the same account can appear locally and via a relay — keep the
        // healthy copy, but remember the freshest activity either copy saw
        var best: [String: MagpieQuota] = [:]
        var active: [String: Date] = [:]
        var order: [String] = []
        for q in quotas {
            // Nothing to show (e.g. free API-key tiers with no windows)
            if q.windows.isEmpty && q.error == nil { continue }
            if q.provider.hasSuffix("~keys") { continue }
            let prov = q.provider.split(separator: "/").last.map(String.init) ?? q.provider
            let key = "\(prov)|\(q.user ?? "")|\(q.plan ?? "")"
            if let at = q.activeAt { active[key] = max(active[key] ?? at, at) }
            if let cur = best[key] {
                let better = (cur.error != nil && q.error == nil)
                    || (cur.error == nil) == (q.error == nil) && q.windows.count > cur.windows.count
                if better { best[key] = q }
            } else {
                best[key] = q
                order.append(key)
            }
        }
        var byType: [String: [(q: MagpieQuota, activeAt: Date?)]] = [:]
        for key in order {
            guard let q = best[key] else { continue }
            byType[displayName(q.name), default: []].append((q, active[key]))
        }
        return byType.keys.sorted().compactMap { name in
            guard let current = byType[name]?.min(by: inUseFirst) else { return nil }
            return usageCard(name: name, current.q)
        }
    }

    /// Which account of a type is in use: healthy first, then the freshest sign of
    /// use (lastServedAt / usage rising), then the busiest short window — a 5h
    /// window only climbs while the account is being used.
    private func inUseFirst(_ a: (q: MagpieQuota, activeAt: Date?),
                            _ b: (q: MagpieQuota, activeAt: Date?)) -> Bool {
        if (a.q.error == nil) != (b.q.error == nil) { return a.q.error == nil }
        let ta = a.activeAt ?? .distantPast, tb = b.activeAt ?? .distantPast
        if ta != tb { return ta > tb }
        return shortestWindowUse(a.q) > shortestWindowUse(b.q)
    }

    private func shortestWindowUse(_ q: MagpieQuota) -> Double {
        let timed = q.windows.compactMap { w in windowDuration(w).map { (w, $0) } }
        guard let d = timed.map(\.1).min() else { return 0 }
        return timed.filter { $0.1 == d }.map(\.0.usedPercent).max() ?? 0
    }

    private func usageCard(name: String, _ q: MagpieQuota) -> UsageCard {
        // Shortest and longest timed windows; the most-used one when several tie
        let timed = q.windows.compactMap { w in windowDuration(w).map { (w, $0) } }
        func busiest(_ d: TimeInterval) -> MagpieQuotaWindow? {
            timed.filter { $0.1 == d }.max { $0.0.usedPercent < $1.0.usedPercent }?.0
        }
        let shortest = timed.map(\.1).min(), longest = timed.map(\.1).max()
        var short = shortest.flatMap(busiest)
        var long = longest.flatMap(busiest)
        if shortest == longest {
            // One window length only: a day or less reads as the short slot
            if (shortest ?? .infinity) > 86400 { short = nil } else { long = nil }
        }
        // No length in the name ("Credits"): it's the account's long-term budget
        if long == nil && short == nil { long = q.windows.max { $0.usedPercent < $1.usedPercent } }
        return UsageCard(name: name, user: q.user.map(maskAccount),
                         short: short, long: long, healthy: q.error == nil)
    }

    /// An account as the screen shows it: "fe***@gmail.com · Team", "138****0000".
    private func maskAccount(_ account: String) -> String {
        var parts = account.components(separatedBy: " · ")
        let id = parts[0]
        if let at = id.firstIndex(of: "@") {
            parts[0] = String(id[..<at].prefix(2)) + "***" + id[at...]
        } else if id.count >= 7, id.allSatisfy(\.isNumber) {
            parts[0] = id.prefix(3) + "****" + id.suffix(4)
        } else if id.count > 3 {
            parts[0] = id.prefix(2) + "***" + id.suffix(1)
        }
        return parts.joined(separator: " · ")
    }

    /// The billing cycles of the account a member is (from the quotas): the same
    /// account can be in them locally and via a relay — the copy with most cycles.
    /// None for a key, a provider, or an account the quotas don't know.
    private func cycles(of w: MagpieMember, in quotas: [MagpieQuota]) -> [RoutingGroup.Cycle] {
        guard w.kind == "account", let who = w.who else { return [] }
        let mine = quotas.filter { q in
            q.error == nil && q.user == who
                && (q.provider.split(separator: "/").last.map(String.init) ?? q.provider) == w.provider
                && (q.plan == nil || w.plan == nil || q.plan == w.plan)
        }
        guard let q = mine.max(by: { $0.windows.count < $1.windows.count }) else { return [] }
        return q.windows.map { win in
            (used: min(max(win.usedPercent, 0), 100), renews: win.resetsAt)
        }
    }

    /// 0…1 through a window's current period; nil when its length is unknown.
    private func periodProgress(_ w: MagpieQuotaWindow) -> Double? {
        guard let d = windowDuration(w), let reset = w.resetsAt else { return nil }
        return min(max(1 - reset.timeIntervalSinceNow / d, 0), 1)
    }

    /// Length of a usage window, from its name ("5 hours", "7 days", "Weekly",
    /// "Month", "Claude & GPT · 7 days"…). nil when the name doesn't say ("Credits").
    private func windowDuration(_ w: MagpieQuotaWindow) -> TimeInterval? {
        let base = (w.name.components(separatedBy: " · ").last ?? w.name).lowercased()
        switch base {
        case "daily": return 86400
        case "weekly": return 7 * 86400
        case "month", "monthly":
            if let reset = w.resetsAt,
               let start = Calendar.current.date(byAdding: .month, value: -1, to: reset) {
                return reset.timeIntervalSince(start)
            }
            return 30 * 86400
        default:
            let parts = base.split(separator: " ")
            guard parts.count == 2, let n = Double(parts[0]) else { return nil }
            switch parts[1] {
            case "minute", "minutes": return n * 60
            case "hour", "hours": return n * 3600
            case "day", "days": return n * 86400
            case "week", "weeks": return n * 7 * 86400
            default: return nil
            }
        }
    }

    private func renderUsage(_ ctx: CGContext, snap: MagpieSnapshot) {
        let px = usageX, py = Layout.panelY, pw = usageW, ph = Layout.panelHeight
        Draw.panel(ctx, x: px, y: py, w: pw, h: ph, radius: panelRadius)

        let cards = usageCards(snap.quotas)
        guard !cards.isEmpty else {
            Draw.centeredText(ctx, snap.online ? "读取中…" : "—", cx: px + pw / 2, y: py + ph / 2 - 14,
                              font: Fonts.system(24), color: Color.textL)
            return
        }

        // Grid: columns first (up to 3), a row more once they're full (up to 4).
        // The cards share the panel, so fewer of them are bigger.
        let gap = 6, left = px + 12, top = py + 12
        let areaW = pw - 24, areaH = py + ph - 12 - top
        let maxCols = 3, maxRows = 4
        let cols = min(cards.count, maxCols)
        let rows = min((cards.count + cols - 1) / cols, maxRows)
        let cw = (areaW - (cols - 1) * gap) / cols, chh = (areaH - (rows - 1) * gap) / rows
        let layout = (rows: rows, cols: cols, cardW: cw, cardH: chh,
                      radius: circleRadius(cardW: cw, cardH: chh))
        let capacity = layout.rows * layout.cols
        let overflow = cards.count > capacity
        let shown = Array(cards.prefix(overflow ? capacity - 1 : capacity))
        func slot(_ i: Int) -> CGRect {
            CGRect(x: left + (i % layout.cols) * (layout.cardW + gap),
                   y: top + (i / layout.cols) * (layout.cardH + gap),
                   width: layout.cardW, height: layout.cardH)
        }
        for (i, c) in shown.enumerated() {
            drawUsageCard(ctx, c, rect: slot(i), radius: layout.radius)
        }
        if overflow {
            let rect = slot(capacity - 1)
            card(ctx, rect, border: Color.border, width: 1, radius: usageCardRadius)
            Draw.centeredText(ctx, "+\(cards.count - shown.count) 类", cx: Int(rect.midX), y: Int(rect.midY) - 12,
                              font: Fonts.system(20, weight: .semibold), color: Color.textL)
        }
    }

    private static let cardTitleH: CGFloat = 30   // title + account, on one line
    private static let cardPadX: CGFloat = 14     // title and circles share this inset

    /// Largest circle radius that fits two side by side under the card title.
    private func circleRadius(cardW: Int, cardH: Int) -> CGFloat {
        // Two outer diameters (4r + 2 ring widths ≈ 4.3r), side padding, an 8px gap
        let byWidth = (CGFloat(cardW) - 2 * Self.cardPadX - 8) / 4.3
        let byHeight = (CGFloat(cardH) - Self.cardTitleH - 10) / 2 - 4
        return min(byWidth, byHeight, 56)
    }

    private func drawUsageCard(_ ctx: CGContext, _ c: UsageCard, rect: CGRect, radius r: CGFloat) {
        card(ctx, rect, border: Color.border, width: 1, radius: usageCardRadius)

        // Title on the left, masked account right-aligned on the same line
        let x = Int(rect.minX + Self.cardPadX)
        let maxW = rect.width - 2 * Self.cardPadX
        let tf = Fonts.system(17, weight: .semibold)
        let title = truncate(c.name, font: tf, maxW: maxW)
        Draw.text(ctx, title, x: x, y: Int(rect.minY) + 7,
                  font: tf, color: c.healthy ? Color.textW : Color.textL)
        if let user = c.user {
            let sf = Fonts.system(11)
            let room = maxW - textWidth(title, font: tf) - 8
            if room > 30 {
                rightText(ctx, truncate(user, font: sf, maxW: room), right: Int(rect.maxX - Self.cardPadX),
                          y: Int(rect.minY) + 12, font: sf, color: Color.textS)
            }
        }

        let cy = rect.minY + Self.cardTitleH + (rect.height - Self.cardTitleH) / 2 - 2
        // Ring outer edges sit on the padding: left one flush with the title
        let inset = Self.cardPadX + r + ringWidth(r) / 2
        usageCircle(ctx, c.healthy ? c.short : nil, center: CGPoint(x: rect.minX + inset, y: cy), radius: r)
        usageCircle(ctx, c.healthy ? c.long : nil, center: CGPoint(x: rect.maxX - inset, y: cy), radius: r)
    }

    private func ringWidth(_ r: CGFloat) -> CGFloat {
        max(5, (r * 0.17).rounded())
    }

    /// One window as concentric rings — outer: usage, thin inner: time elapsed in
    /// the period (outer ahead of inner = burning faster than the period runs).
    /// No window: empty tracks and a dash.
    private func usageCircle(_ ctx: CGContext, _ w: MagpieQuotaWindow?, center: CGPoint, radius r: CGFloat) {
        let outerW = ringWidth(r)
        let used = min(max(w?.usedPercent ?? 0, 0), 100)
        ring(ctx, center: center, radius: r, width: outerW,
             fraction: used / 100, color: Color.forPercent(used))
        ring(ctx, center: center, radius: r - outerW - 3, width: 1.5,
             fraction: w.flatMap(periodProgress) ?? 0, color: Color.textS)

        let cx = Int(center.x)
        guard let w else {
            Draw.centeredText(ctx, "—", cx: cx, y: Int(center.y - r * 0.3),
                              font: Fonts.system(r * 0.45, weight: .bold), color: Color.textD)
            return
        }
        // Used up: "100%" says nothing new (the full red ring already does) —
        // show how long until it refreshes instead
        let exhausted = used >= 99.5 && w.resetsAt != nil
        let main = exhausted ? untilCN(w.resetsAt!) : "\(Int(used.rounded()))%"
        let mainMaxW = (r - outerW - 5) * 1.8
        var size = (r * (main.count > 3 ? 0.38 : 0.44)).rounded()
        while size > 10 && textWidth(main, font: Fonts.system(size, weight: .bold)) > mainMaxW { size -= 1 }
        Draw.centeredText(ctx, main, cx: cx, y: Int(center.y - size * 0.75),
                          font: Fonts.system(size, weight: .bold),
                          color: used >= 90 ? Color.red : Color.textW)
        // "Claude 7d" when it fits inside the ring, else just "7d"
        let lf = Fonts.system((r * 0.29).rounded())
        let maxW = (r - outerW - 6) * 1.6
        var label = exhausted ? "后刷新" : windowLabel(w.name)
        if textWidth(label, font: lf) > maxW {
            label = windowLabel(w.name.components(separatedBy: " · ").last ?? w.name)
        }
        Draw.centeredText(ctx, truncate(label, font: lf, maxW: maxW),
                          cx: cx, y: Int(center.y + size * 0.35), font: lf, color: Color.textL)
    }

    /// Full-circle track with an arc from 12 o'clock, clockwise, for `fraction`.
    private func ring(_ ctx: CGContext, center: CGPoint, radius: CGFloat, width: CGFloat,
                      fraction: Double, color: CGColor) {
        ctx.saveGState()
        ctx.setLineWidth(width)
        ctx.setStrokeColor(Color.barBG)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.strokePath()
        if fraction > 0 {
            // Flipped context: increasing angles run clockwise on screen
            let start = -CGFloat.pi / 2
            ctx.setLineCap(.round)
            ctx.setStrokeColor(color)
            ctx.addArc(center: center, radius: radius, startAngle: start,
                       endAngle: start + 2 * .pi * CGFloat(min(fraction, 1)), clockwise: false)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    // MARK: - Drawing helpers

    // Rounded screens: panels and the corner cards share the screen corner's
    // centre (concentric), so nothing pokes into the clipped corners.
    private var panelRadius: CGFloat {
        max(16, DisplayShape.cornerRadius - CGFloat(Layout.margin))
    }

    private var usageCardRadius: CGFloat {
        max(14, panelRadius - 12)   // cards sit 12px inside the panel
    }

    /// Black out what a rounded screen can't show, so the on-Mac preview matches it.
    private func maskScreenCorners(_ ctx: CGContext) {
        let r = DisplayShape.cornerRadius
        guard r > 0 else { return }
        let full = CGRect(x: 0, y: 0, width: Layout.width, height: Layout.height)
        let path = CGMutablePath()
        path.addRect(full)
        path.addRoundedRect(in: full, cornerWidth: r, cornerHeight: r)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fillPath(using: .evenOdd)
    }

    private func card(_ ctx: CGContext, _ rect: CGRect, border: CGColor, width: CGFloat,
                      radius: CGFloat = 14, dash: [CGFloat]? = nil) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.setFillColor(Color.bgTop)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.saveGState()
        ctx.setStrokeColor(border)
        ctx.setLineWidth(width)
        if let dash { ctx.setLineDash(phase: 0, lengths: dash) }
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// A wire: the horizontal S-curve between two cards, the one the magpies
    /// fly along. A live one flows, as the page's rtflow: dashes 3·5 marching
    /// 8 page px toward the target every .7s.
    private func link(_ ctx: CGContext, from a: CGPoint, to b: CGPoint, color: CGColor,
                      animated: Bool, t: Double, dim: Bool = false) {
        let (_, c1, c2, _) = FlightStage.wire(a, b)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // Animated links are overlay, drawn over the cards — keep them in the gap
        ctx.clip(to: CGRect(x: min(a.x, b.x), y: 0, width: abs(b.x - a.x), height: CGFloat(Layout.height)))
        ctx.setStrokeColor(dim ? (color.copy(alpha: 0.6) ?? color) : color)
        if animated {
            let s = birdScale
            ctx.setLineWidth(2.5)
            ctx.setLineCap(.butt)
            ctx.setLineDash(phase: CGFloat(-(t / 0.7 * 8 * Double(s)).truncatingRemainder(dividingBy: 8 * Double(s))),
                            lengths: [3 * s, 5 * s])
        } else {
            ctx.setLineWidth(dim ? 1.5 : 2)
            ctx.setLineCap(.round)
            if color == Color.border { ctx.setLineDash(phase: 0, lengths: [5, 5]) }
        }
        ctx.move(to: a)
        ctx.addCurve(to: b, control1: c1, control2: c2)
        ctx.strokePath()
    }

    private func rightText(_ ctx: CGContext, _ s: String, right: Int, y: Int, font: NSFont, color: CGColor) {
        Draw.text(ctx, s, x: right - Int(textWidth(s, font: font)), y: y, font: font, color: color)
    }

    private func textWidth(_ s: String, font: NSFont) -> CGFloat {
        Draw.width(s, font: font)
    }

    // What a text cut to a width came to: the same rows are cut the same way
    // each time the base is drawn (render thread only, under renderMutex)
    private var truncated: [String: String] = [:]

    private func truncate(_ s: String, font: NSFont, maxW: CGFloat) -> String {
        if textWidth(s, font: font) <= maxW { return s }
        let key = "\(s)\u{0}\(font.fontName)\u{0}\(font.pointSize)\u{0}\(maxW)"
        if let t = truncated[key] { return t }
        if truncated.count > 2000 { truncated.removeAll(keepingCapacity: true) }
        // the longest head that fits with "…": widths only grow with it, so halve
        let chars = Array(s)
        var lo = 0, hi = chars.count   // lo fits (or none does, at worst), hi doesn't
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if textWidth(String(chars[..<mid]) + "…", font: font) <= maxW { lo = mid } else { hi = mid }
        }
        let t = String(chars[..<lo]) + "…"
        truncated[key] = t
        return t
    }

    // MARK: - Labels

    private func agentName(_ id: String) -> String {
        switch id {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "cursor": return "Cursor"
        case "t3code": return "T3 Code"
        case "opencode": return "OpenCode"
        default: return id.prefix(1).uppercased() + id.dropFirst()
        }
    }

    private func agentColor(_ id: String) -> CGColor {
        switch id {
        case "claude": return Color.claude
        case "codex": return Color.cyan
        case "cursor": return Color.cursor
        case "t3code": return Color.orange
        default: return Color.purple
        }
    }

    private func routingLabel(_ mode: String?) -> String {
        switch mode {
        case nil, "": return "直连"
        case "order": return "按顺序"
        case "balance", "round-robin", "roundrobin": return "轮流"
        case "random": return "随机"
        case "cost", "cheapest": return "最省"
        case "fastest", "latency": return "最快"
        case "quota": return "按额度"
        default: return mode!
        }
    }

    private func displayName(_ name: String) -> String {
        // "Claude Code · US" → "Claude Code" (relay suffix adds nothing on the LCD),
        // "Grok (SuperGrok)" → "Grok" (the plan isn't shown)
        let base = name.components(separatedBy: " · ").first ?? name
        return base.components(separatedBy: " (").first ?? base
    }

    /// "7 days" → "7d"; "Claude & GPT · 7 days" → "Claude 7d" (keeps per-model windows apart)
    private func windowLabel(_ name: String) -> String {
        let parts = name.components(separatedBy: " · ")
        let base = parts.last ?? name
        let short: String
        switch base {
        case "5 hours": short = "5h"
        case "1 day": short = "1d"
        case "7 days": short = "7d"
        case "Weekly": short = "周"
        case "Month": short = "月"
        case "Credits": short = "额度"
        case "Limit": short = "限额"
        default: short = base
        }
        guard parts.count > 1, let model = parts.first?.split(separator: " ").first else { return short }
        return "\(model) \(short)"
    }

    private func shortModel(_ m: String) -> String {
        m.hasPrefix("us/") ? String(m.dropFirst(3)) : m
    }

    private func seconds(_ s: Double) -> String {
        s < 60 ? String(format: "%.1fs", max(s, 0)) : "\(Int(s) / 60)m\(Int(s) % 60)s"
    }

    private func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "\(max(s, 0))秒前" }
        if s < 3600 { return "\(s / 60)分前" }
        return "\(s / 3600)小时前"
    }

    /// "3天" / "5小时" / "42分" until a reset time
    private func untilCN(_ d: Date) -> String {
        let s = Int(d.timeIntervalSinceNow)
        if s <= 0 { return "即将" }
        if s < 3600 { return "\(max(s / 60, 1))分" }
        if s < 86400 { return "\(s / 3600)小时" }
        return "\(s / 86400)天"
    }
}
