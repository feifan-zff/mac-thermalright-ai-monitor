// RoutingGroup.swift — the routing groups on the stage, as magpie's routing page lays them out
//
// Ported from `magpie web`'s routing view (plugins/routing client.js: staged
// and wayInfos, seated, the fold runs in rebuild, the row words in render):
// each agent's latest request, under a heading naming the way it went — its
// routing group, or the provider of its model — and under it the members it
// weighed, in the group's order; three or more accounts (or keys) of one
// provider and model side by side fold under a heading of their own; each
// row says what it did for that request, or why it sits out. Members the
// group leaves out (switched off, used up and not to spend credits, at their
// cap) aren't shown.

import Foundation

/// A way requests go: a routing group, or the provider a model is of.
struct StageWay {
    let key: String
    let name: String             // "Claude Opus 5.5"
    let ref: String              // "auto/claude-opus-5-5"
    let routing: String?         // its routing ("order", …); nil without a group
    let agent: String            // the agent of the request it tells of
    let isGroup: Bool
}

struct GroupRow {
    enum State { case idle, on, flying, rest, left }
    enum Kind { case member, fold, way }

    let kind: Kind
    let id: String               // unique on the stage: its way's key, then the member's id (or "fold:" + …)
    let member: MagpieMember     // the member; a fold's first; a way's first
    let members: [String]        // a fold's or a way's member ids; empty for a member
    let parent: String?          // the row it hangs under: its fold, or its way's heading
    let depth: Int               // how far in it is set: 0 for a heading
    let status: String           // what the row says (folded, as it says folded)
    let openStatus: String       // open: only what the rows under it don't
    let state: State
    let low: Bool                // 90% or more of its allowance used
    var way: StageWay? = nil     // a way's heading: the way it names
    var used: Double? = nil      // a member's: how much of the cycle that binds it is used (0…100)
    var timed = false            // its status ends in a countdown ("6d", "限流 · 31m"): drawn heavier

    var isFold: Bool { kind == .fold }
    var isWay: Bool { kind == .way }
}

enum RoutingGroup {

    static let foldAt = 3, long = 6

    /// The way a request went: its group, or its provider.
    static func way(_ r: MagpieRoute) -> StageWay {
        if let g = r.groupName {
            return StageWay(key: "g:" + (r.groupID ?? g), name: g, ref: r.groupRef ?? r.model,
                            routing: r.routing ?? "", agent: r.agent, isGroup: true)
        }
        let f = r.members.first { !$0.fallback } ?? r.members.first
        return StageWay(key: "p:" + r.provider, name: f?.name ?? r.provider, ref: r.model,
                        routing: nil, agent: r.agent, isGroup: false)
    }

    /// Every row of the stage: for each request (one a way), its way's heading
    /// when `headed`, then its members, each fold followed by its own.
    static func stage(_ routes: [MagpieRoute], headed: Bool, now: Date,
                      mask: (String) -> String, cycles: (MagpieMember) -> [Cycle] = { _ in [] }) -> [GroupRow] {
        var out: [GroupRow] = []
        for r in routes {
            let w = way(r)
            guard headed else {
                out += rows(r, now: now, mask: mask, cycles: cycles, prefix: w.key + ">", parent: nil, depth: 0)
                continue
            }
            let head = "way:" + w.key
            let kids = rows(r, now: now, mask: mask, cycles: cycles, prefix: w.key + ">", parent: head, depth: 1)
            guard let first = r.members.first else { continue }
            out.append(heading(head, w, first, r, kids.filter { $0.parent == head }, mask: mask))
            out += kids
        }
        return out
    }

    /// A way's heading: what the request is doing with it, and its routing
    /// (the chip, drawn) — folded, how many it has, and who is answering.
    private static func heading(_ id: String, _ w: StageWay, _ first: MagpieMember, _ r: MagpieRoute,
                                _ kids: [GroupRow], mask: (String) -> String) -> GroupRow {
        let on = kids.first { $0.state == .flying } ?? kids.first { $0.state == .on }
        var open: [String] = []
        if !r.done && r.tries.isEmpty { open.append(r.phase == "redact" ? "脱敏中…" : "路由中…") }
        var folded = open + ["\(r.members.count) 个成员"]
        if let on { folded.insert(on.isFold ? on.status : "\(who(on.member, mask: mask)) \(on.status)", at: 0) }
        let state: GroupRow.State =
            kids.contains { $0.state == .flying } ? .flying
            : on != nil ? .on
            : kids.allSatisfy { $0.state == .rest || $0.state == .left } ? .rest
            : .idle
        return GroupRow(kind: .way, id: id, member: first, members: r.members.map(\.id), parent: nil, depth: 0,
                        status: folded.joined(separator: " · "), openStatus: open.joined(separator: " · "),
                        state: state, low: false, way: w)
    }

    /// The rows of one request's members, each fold followed by its own:
    /// ids start `prefix`, top rows hang under `parent` set in `depth`.
    static func rows(_ r: MagpieRoute, now: Date, mask: (String) -> String,
                     cycles: (MagpieMember) -> [Cycle] = { _ in [] },
                     prefix: String = "", parent: String? = nil, depth: Int = 0) -> [GroupRow] {
        let f = Findings(r, now: now)
        let seats = seated(r)
        var out: [GroupRow] = []
        var run: [MagpieMember] = []

        func row(_ w: MagpieMember, parent: String?, depth: Int) -> GroupRow {
            let cycle = binding(cycles(w))
            let (status, state, low) = say(w, r, f, now: now, cycle: cycle)
            var g = GroupRow(kind: .member, id: prefix + seat(w), member: w, members: [], parent: parent, depth: depth,
                             status: status, openStatus: status, state: state, low: low)
            if w.known { g.used = cycle?.used ?? w.usedPercent }
            g.timed = status.range(of: #"(^|· )\d+[mhd]$"#, options: .regularExpression) != nil
            return g
        }
        func flush() {
            defer { run = [] }
            guard run.count >= foldAt, let first = run.first else {
                out += run.map { row($0, parent: parent, depth: depth) }
                return
            }
            let key = prefix + "fold:" + seat(first)
            let kids = run.map { row($0, parent: key, depth: depth + 1) }
            out.append(together(key, first, kids, parent: parent, depth: depth))
            out += kids
        }
        for w in seats {
            if folding(w), let head = run.first, foldKey(head) == foldKey(w) {
                run.append(w)
            } else {
                flush()
                if folding(w) { run = [w] } else { out.append(row(w, parent: parent, depth: depth)) }
            }
        }
        flush()
        return out
    }

    // MARK: Order

    /// The page's seated, but for those the group leaves out (the user asked
    /// they not be shown): those weighed, in the group's order — its members,
    /// then by name. Within a provider the page goes by the order its accounts
    /// were signed in, which the trace doesn't carry; the order the gateway
    /// weighed them in stands for it.
    static func seated(_ r: MagpieRoute) -> [MagpieMember] {
        let all = r.members
        var weighed: [String: Int] = [:]
        for (i, w) in all.enumerated() where weighed[seat(w)] == nil { weighed[seat(w)] = i }
        func place(_ w: MagpieMember) -> Int {
            r.groupMembers.firstIndex(of: w.provider + "/" + w.model)
                ?? r.groupMembers.firstIndex { $0.hasPrefix(w.provider + "/") }
                ?? r.groupMembers.count
        }
        func before(_ a: MagpieMember, _ b: MagpieMember) -> Bool {
            if a.fallback != b.fallback { return !a.fallback }
            if place(a) != place(b) { return place(a) < place(b) }
            let na = a.name.isEmpty ? a.provider : a.name, nb = b.name.isEmpty ? b.provider : b.name
            if na != nb { return na < nb }
            if a.aside != b.aside { return !a.aside }
            return weighed[seat(a)] ?? 0 < weighed[seat(b)] ?? 0
        }
        return all.sorted(by: before)
    }

    private static func seat(_ w: MagpieMember) -> String { w.id + "\u{0}" + w.model }
    private static func folding(_ w: MagpieMember) -> Bool { w.kind == "account" || w.kind == "key" }
    private static func foldKey(_ w: MagpieMember) -> String {
        [w.kind, w.provider, w.model, w.fallback ? "1" : "0", w.aside ? "1" : "0"].joined(separator: "\u{0}")
    }

    // MARK: What each row says

    /// What the request's tries found: who answered, who is answering, the
    /// error the agent got, one the gateway went on from, who rests till when.
    private struct Findings {
        var answered: Set<String> = [], trying: Set<String> = []
        var gave: [String: MagpieTry] = [:], went: [String: MagpieTry] = [:]
        var rests: [String: MagpieRest] = [:]
        var served: [String: String] = [:]   // what answered, by member
        var speed: [String: String] = [:]    // how fast it answered, by member ("87 tok/s")

        init(_ r: MagpieRoute, now: Date) {
            for w in r.members { if let rest = w.rest { rests[w.id] = rest } }
            for (i, t) in r.tries.enumerated() {
                let last = i == r.tries.count - 1
                if !t.done { trying.insert(t.id) }
                else if !t.failed { answered.insert(t.id); served[t.id] = t.served }
                else if t.rest == nil && !t.again && !t.earlier && r.done && last { gave[t.id] = t }
                else if t.rest == nil && !t.again && !t.credits && !last { went[t.id] = t }
                if let rest = t.rest { rests[t.id] = rest }
            }
            for id in answered { rests[id] = nil }   // it answered: whatever rest it began in is over
            // The reply's tokens belong to the last try that answered. How fast
            // the model wrote is the page's decode (#196, #731): its answer over
            // the window it wrote in. When that cannot be told — no first token,
            // or a burst a relay let go at its end — no speed is shown
            if let answeredLast = r.tries.last(where: { $0.done && !$0.failed }),
               let out = r.out, out > 0 {
                // Route timestamps include earlier attempts; try timestamps do not.
                // Only use a pair measured from the same origin. Without route
                // timing, reasoning timestamps cannot safely be attributed to a try.
                let timing: (ms: Int, ttft: Int?)?
                if let ms = r.ms, let ttft = r.ttft {
                    timing = (ms, ttft)
                } else if (r.reasoning ?? 0) == 0, r.reasoningHidden != true,
                          r.firstText == nil, r.firstReasoning == nil, let ms = answeredLast.ms {
                    timing = (ms, answeredLast.ttft)
                } else {
                    timing = nil
                }
                if let timing,
                   let d = RoutingGroup.decode(out: out, ms: timing.ms, ttft: timing.ttft, firstText: r.firstText,
                                               flow: r.flow, firstReasoning: r.firstReasoning,
                                               reasoning: r.reasoning, reasoningHidden: r.reasoningHidden) {
                    speed[answeredLast.id] = "\(Int((Double(d.n) * 1000 / Double(d.w)).rounded())) tok/s"
                }
            }
        }
    }

    private static func say(_ w: MagpieMember, _ r: MagpieRoute, _ f: Findings, now: Date,
                            cycle: Cycle?) -> (String, GroupRow.State, Bool) {
        // The panel's rows are one line each: the page's words, cut to the gist
        let rest = f.rests[w.id], resting = rest.map { $0.until > now } ?? false
        let s: String
        if w.unlisted { s = unlistedWord(w, cycle: cycle, now: now) }
        else if resting, let rest { s = restSay(rest, now: now) }
        else if w.window != nil { s = "超出上下文" }
        else if f.trying.contains(w.id) { s = "回答中" }
        else if f.answered.contains(w.id) {
            // How fast it put the reply out says how it answered; until its
            // tokens land, a remote magpie (a provider, not an account) hides
            // who is behind it: the model it served says it
            s = f.speed[w.id] ?? (w.kind == "provider" ? f.served[w.id] ?? "已回答" : "已回答")
        }
        else if let t = f.gave[w.id] ?? f.went[w.id] {
            // a quota failure has no word (the bar says it): its renewal says when it is back
            let said = (t.status.flatMap { $0 > 0 ? "\($0) " : nil } ?? "") + failWord(t.fail)
            s = said.isEmpty ? (cycle?.renews ?? w.renews ?? w.due).map { renewWord($0, now: now) } ?? "" : said
        }
        else if w.known, w.usedPercent != nil {
            // How much is used is the bar along the row's foot; the words say
            // what it can't — when the window renews, and what happens at its end
            var parts: [String] = []
            if let at = cycle?.renews ?? w.renews ?? w.due { parts.append(renewWord(at, now: now)) }
            if w.creditsLast && !(r.members.first?.creditsLast ?? false) { parts.append("用积分") }
            s = parts.joined(separator: " · ")
        }
        else { s = "" }

        let flying = !resting && f.trying.contains(w.id)
        let state: GroupRow.State =
            flying ? .flying
            : (!resting && f.answered.contains(w.id)) ? .on
            : (resting || f.gave[w.id] != nil) ? .rest
            : (w.unlisted || w.window != nil) ? .left
            : .idle
        let low = w.routing.isEmpty && w.known && (cycle?.used ?? w.usedPercent ?? 0) >= 90
        return (s, state, low)
    }

    /// A fold tells of its members together: the one answering or that
    /// answered, then how many are there to route to, and how many sit out.
    private static func together(_ key: String, _ first: MagpieMember, _ kids: [GroupRow],
                                 parent: String?, depth: Int) -> GroupRow {
        let on = kids.first { $0.state == .flying } ?? kids.first { $0.state == .on }
        let resting = kids.filter { $0.state == .rest }.count
        let held = kids.filter { $0.state == .left }.count
        var counts: [String] = []
        if resting + held < kids.count { counts.append("\(kids.count - resting - held) 可用") }
        if resting > 0 { counts.append("\(resting) 休息") }
        if held > 0 { counts.append("\(held) 不用") }
        var folded = counts
        // what the one answering says; its heading names the provider, the panel's
        // one line has no room for whose account
        if let on { folded.insert(on.status, at: 0) }
        let state: GroupRow.State =
            kids.contains { $0.state == .flying } ? .flying
            : on != nil ? .on
            : resting + held == kids.count ? .rest
            : .idle
        return GroupRow(kind: .fold, id: key, member: first, members: kids.map(\.member.id), parent: parent,
                        depth: depth, status: folded.joined(separator: " · "), openStatus: counts.joined(separator: " · "),
                        state: state, low: false)
    }

    static func who(_ w: MagpieMember, mask: (String) -> String) -> String {
        w.kind == "provider" ? w.name : (w.who.map(mask) ?? w.name)
    }

    /// A reply's answer and the window it wrote it in, as the page's decodeOf
    /// tells it (#196, #731). The answer is its output less the reasoning the
    /// stream kept hidden (it was written before the stream showed any); the
    /// window runs from its first text, or its first reasoning when only that
    /// was shown. Nil when it cannot be told: no first token, a window under
    /// 100 ms or beyond 10,000 tok/s, or one that came in a burst — a relay
    /// held the reply back and let it go at its end (its content in under a
    /// quarter of its window, or its answer at over 20 times the pace its
    /// reasoning came before its first text).
    static func decode(out: Int, ms: Int, ttft: Int?, firstText: Int?, flow: Int?,
                       firstReasoning: Int?, reasoning: Int?, reasoningHidden: Bool?) -> (n: Int, w: Int)? {
        guard let ttft, ttft > 0, ms > 0, out > 0 else { return nil }
        let think = reasoning ?? 0
        let text = firstText ?? 0, began = firstReasoning ?? 0, ran = flow ?? 0
        guard think >= 0, think <= out, text >= 0, began >= 0, ran >= 0 else { return nil }
        if (reasoningHidden ?? false) && text <= 0 { return nil }
        // reasoning shown on its own counts: the window is from where it began
        let visible = think > 0 && text <= 0 && began >= ttft && ran > 0 && think <= out
        let n = think > 0 && !visible ? out - think : out
        let from = visible ? began : (think > 0 ? text : ttft)
        guard n > 0, from > 0, from < ms else { return nil }
        let w = ms - from
        // The trace is external data: products of valid Int values can overflow.
        let count = Double(n), window = Double(w)
        guard w >= 100, count * 1000 <= 10000 * window else { return nil }
        if ran > 0 && Double(ran) * 4 < window { return nil }
        if think > 0 && text > 0 && count * (Double(text) - Double(ttft)) > 20 * Double(think) * window { return nil }
        return (n, w)
    }

    /// One billing cycle of an account: how much of it is used (0…100) and when
    /// it renews.
    typealias Cycle = (used: Double, renews: Date?)

    /// The cycle that binds an account. A request needs room in all of its cycles
    /// (an AND), so what matters is the one that has none: with several used up
    /// the account is back only when the last of them renews; with none, the
    /// one most used — the nearer renewal when they tie.
    static func binding(_ cycles: [Cycle]) -> Cycle? {
        let spent = cycles.filter { $0.used >= 99.5 }
        if !spent.isEmpty { return spent.max { ($0.renews ?? .distantPast) < ($1.renews ?? .distantPast) } }
        return cycles.max { a, b in
            a.used != b.used ? a.used < b.used : (a.renews ?? .distantFuture) > (b.renews ?? .distantFuture)
        }
    }

    /// How long until a usage window renews, bare for a row's narrow end:
    /// "42m", "3h", "6d".
    private static func renewWord(_ at: Date, now: Date) -> String {
        let m = max(1, Int((at.timeIntervalSince(now) / 60).rounded()))
        return m < 60 ? "\(m)m"
            : m < 48 * 60 ? "\(Int((Double(m) / 60).rounded()))h"
            : "\(Int((Double(m) / 1440).rounded()))d"
    }

    private static func unlistedWord(_ w: MagpieMember, cycle: Cycle?, now: Date) -> String {
        if w.held { return "此 Key 不可用" }
        if w.noCredits {   // used up: the bar says it, the words say when it renews
            return (cycle?.renews ?? w.renews ?? w.due).map { renewWord($0, now: now) } ?? "暂不使用"
        }
        if let cap = w.capped { return "已达 \(cap)% 上限" }
        if w.barred { return "只用于其他模型" }
        return "暂不使用"
    }

    private static let failWords = [
        "rate": "限流", "credit": "余额不足", "quota": "", "other": "失败", "auth": "需要登录",
        "canceled": "已取消", "verify": "需要验证", "refused": "被安全过滤拒绝", "overflow": "超出模型长度",
        "slow": "迟迟不开始", "offline": "网络断开", "proxy": "代理不可达",
    ]

    static func failWord(_ why: String?) -> String { why.flatMap { failWords[$0] } ?? "失败" }

    /// A resting row: why, and how long until it is back ("限流 · 31m"). A failure that names no kind says its status.
    static func restSay(_ rest: MagpieRest, now: Date) -> String {
        let named = failWords[rest.why] != nil && rest.why != "other"
        let status = !named ? (rest.status.map { "\($0) " } ?? "") : ""
        return [status + failWord(rest.why), renewWord(rest.until, now: now)].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
