// MagpieCollector.swift — Live routing + subscription quotas from the local magpie gateway
//
// Polls a magpie gateway's HTTP API (read-only; address + key from MagpieConfig):
//   /v1/magpie/trace   — recent requests: agent, routing group, member order, tries
//   /v1/magpie/quotas  — every subscription account's usage windows + reset times
// The trace is fetched in full once, then incrementally with ?after=<seq> (a
// request's seq bumps on every update), so a remote gateway costs a few KB/s
// instead of ~200KB/s. A file:///dir base URL reads canned dir/v1/magpie/{trace,
// quotas} — for testing and demos.
//
// A remote gateway's /v1/magpie/trace is refused to gateway keys, but its web
// page (`magpie web`) shows the same trace to whoever holds the web key. Given
// a key the gateway rejects, the collector signs in like that page does
// (GET /?k=<key> → cookie) and reads /api/gateway/trace + /api/usage/quotas.

import Foundation

// MARK: - Snapshot types

/// A member sitting out: rate limited, out of quota, … until a time.
struct MagpieRest: Sendable {
    let why: String         // "quota" | "rate" | "credit" | "auth" | "other" | …
    let status: Int?
    let until: Date
}

struct MagpieTry: Sendable {
    let id: String
    let done: Bool
    let status: Int?
    let ms: Int?
    let ttft: Int?
    let start: Date?
    let error: String?
    let fail: String?       // why it failed, magpie's word ("quota", "rate", …)
    let rest: MagpieRest?   // the member it put to rest
    let again: Bool         // retried on the same member
    let credits: Bool       // went on to the member's credits
    let earlier: Bool
    let served: String?     // the model that answered, as the upstream names it (a remote magpie hides who is behind it)

    /// The page's tryOk, inverted: a reply that broke off after its 200 has a fail.
    var failed: Bool { done && !((status ?? 0) > 0 && (status ?? 0) < 400 && fail == nil) }
}

struct MagpieMember: Sendable {
    let id: String
    let kind: String        // "account" | "key" | "provider"
    let provider: String    // "codex", "devin", "us"
    let name: String        // "Codex", "US"
    let icon: String?       // the page's icon name ("codex-color", "magpie", …)
    let who: String?        // account e-mail for subscription accounts
    let plan: String?
    let model: String
    let routing: String     // the member's own routing over its accounts ("" = none)
    let known: Bool         // its usage is known
    let usedPercent: Double?
    let due: Date?          // when the binding usage window resets
    let renews: Date?       // when the window usedPercent is of renews
    let credits: Bool       // spends credits once its allowance is used up
    let creditsLast: Bool
    let rest: MagpieRest?
    // set aside, not routed to: the gateway key may not use it, it's at its
    // usage cap, used up and set not to spend credits, or serves other models
    let unlisted: Bool
    let held: Bool
    let noCredits: Bool
    let capped: Int?
    let barred: Bool
    let window: Int?        // the request is longer than its context window
    let fallback: Bool
    let aside: Bool

    /// One left out the page still shows (seated): held back, not unusable.
    var heldOut: Bool { !held && (capped != nil || noCredits || window != nil) }
}

struct MagpieRoute: Sendable {
    let id: Int
    let seq: Int
    let time: Date
    let agent: String
    let model: String
    let provider: String    // what its model resolved to: a provider, or "magpie" while it holds it
    let groupID: String?
    let groupRef: String?   // the name agents send to it: "auto/claude-opus-5-5"
    let groupName: String?
    let routing: String?    // group routing mode ("order", …); nil = direct model
    let members: [MagpieMember]     // weighed for this request, in its order
    let left: [MagpieMember]        // the group's others, left out of it
    let groupMembers: [String]      // the group's "provider/model" members, in its order
    let tries: [MagpieTry]
    let phase: String?      // before routing: "redact" while magpie masks it (Settings › Privacy)
    let error: String?      // why nothing took it, when nothing did
    let done: Bool
    let status: Int?
    let ms: Int?
    let tokens: Int?
    let out: Int?
    let folder: String?

    var inFlight: Bool { !done }
    var failed: Bool {
        done && ((status ?? 0) != 200 || error != nil || tries.last?.failed == true)
    }
}

struct MagpieQuotaWindow: Sendable, Equatable {
    let name: String
    let usedPercent: Double
    let resetsAt: Date?
}

struct MagpieQuota: Sendable, Equatable {
    let provider: String    // "us/claude", "codex", …
    let name: String        // "Claude Code"
    let plan: String?
    let user: String?
    let windows: [MagpieQuotaWindow]
    let error: String?
    let balance: String?
    let lastServedAt: Date?
    /// Latest sign of use: lastServedAt, or when this session saw its usage rise
    /// (relayed accounts carry no lastServedAt, but their usage still climbs).
    let activeAt: Date?
}

/// What the gateway's requests used today, in this computer's zone (its usage
/// page's "today": /v1/magpie/usage?period=today).
struct MagpieToday: Sendable {
    let calls: Int
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int     // all writes; the gateway's cache_write_1h is a part of it
    let cost: Double?       // USD; nil when nothing could be priced
    let unpriced: Int       // requests with no price: the cost is at least `cost`

    /// Every token the requests used: in, out, and read from and written to the cache.
    var tokens: Int { input + output + cacheRead + cacheWrite }
}

struct MagpieSnapshot: Sendable {
    let generation: Int             // the configuration that produced this snapshot
    let online: Bool
    let error: String?              // why offline: unreachable / rejected key / HTTP status
    let routingNote: String?        // online, but why there is no routing data
    let routes: [MagpieRoute]       // oldest → newest
    let quotas: [MagpieQuota]
    let today: MagpieToday?         // nil until read, or when this key can't read it
    // Bumped only when something shown changed (a poll that finds nothing new
    // keeps them), so the panel redraws for news, not for every poll
    let version: Int
    let quotaVersion: Int           // the quotas alone


    var anyInFlight: Bool { routes.contains { $0.inFlight } }
}

// MARK: - Collector

final class MagpieCollector: @unchecked Sendable {

    var baseURL: String { MagpieConfig.baseURL }

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10   // a web page's quotas can take ~5s
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        // The web sign-in cookie is handled by hand (read off the 303, sent as a header)
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        return URLSession(configuration: cfg, delegate: NoRedirects(), delegateQueue: nil)
    }()

    deinit {
        session.invalidateAndCancel()
    }

    /// How this gateway is read: its API with a gateway key, or its web page.
    private enum Access { case gateway, web }
    private var access = Access.gateway
    private var webCookie: String?

    private enum Endpoint { case trace, quotas, usage }

    private func path(_ e: Endpoint) -> String {
        switch (access, e) {
        case (.gateway, .trace):  return "/v1/magpie/trace"
        case (.gateway, .quotas): return "/v1/magpie/quotas"
        case (.gateway, .usage):  return "/v1/magpie/usage"
        case (.web, .trace):      return "/api/gateway/trace"
        case (.web, .quotas):     return "/api/usage/quotas"
        case (.web, .usage):      return "/api/usage"
        }
    }

    // Incremental trace state (reset whenever the gateway or key changes)
    private var routesByID: [Int: MagpieRoute] = [:]
    private var lastSeq: Int?
    private var generation = -1
    // magpie serves the trace to its own machine only: a gateway key gets 403 on
    // it but can still read quotas. Re-checked at the quota cadence, not every second.
    private var traceForbidden = false
    private static let routingLocalOnly = "路由明细仅网关本机可读"
    private static let keepRoutes = 20

    // Quotas change slowly and the endpoint costs ~200ms — keep the last good copy.
    private var cachedQuotas: [MagpieQuota] = []
    private var quotasRead = false
    // Today's usage (~17KB, ~200ms): read every few polls, the last good copy kept
    private var cachedToday: MagpieToday?
    // Per account: total used % at the last refresh, and when it last went up
    private var usageSeen: [String: (total: Double, roseAt: Date?)] = [:]

    // What the last snapshot showed, in short: a change bumps its version
    private var version = 0, quotaVersion = 0, traceTick = 0
    private var shown = ""

    private func stamp(_ s: String) -> Int {
        if s != shown { shown = s; version += 1 }
        return version
    }

    private func offline(_ message: String) -> MagpieSnapshot {
        MagpieSnapshot(generation: generation, online: false, error: message, routingNote: nil, routes: [], quotas: [], today: nil,
                       version: stamp("offline|" + message), quotaVersion: quotaVersion)
    }

    /// One poll. `quotas` also refreshes the subscription quotas, `usage` today's usage.
    func collect(quotas: Bool, usage: Bool) -> MagpieSnapshot {
        let config = MagpieConfig.configuration()
        let gen = config.generation
        var refreshQuotas = quotas, refreshUsage = usage
        if gen != generation {
            // New gateway / key: nothing from the old one may leak into the display
            generation = gen
            routesByID = [:]; lastSeq = nil; cachedQuotas = []; quotasRead = false; usageSeen = [:]; cachedToday = nil
            traceTick += 1
            quotaVersion += 1
            traceForbidden = false
            access = .gateway; webCookie = nil
            refreshQuotas = true
            refreshUsage = true
        }
        let base = config.baseURL, key = config.apiKey

        var trace: [String: Any]?
        if !traceForbidden || refreshQuotas {
            let query = lastSeq.map { "?after=\($0)" } ?? ""
            switch request(base: base, .trace, query: query, key: key) {
            case .success(let t):
                trace = t as? [String: Any]
                traceForbidden = false
            case .failure(let err) where err.status == 403:
                if !traceForbidden { traceTick += 1 }
                traceForbidden = true
                routesByID = [:]; lastSeq = nil
            case .failure(let err):
                lastSeq = nil   // resync in full once it's back
                return offline(err.message)
            }
        }
        if let trace, mergeTrace(trace) { traceTick += 1 }

        if refreshQuotas || !quotasRead {
            quotasRead = true   // none, or none readable, waits for its cadence: not a fetch a second
            switch request(base: base, .quotas, key: key) {
            case .success(let q):
                let updated = parseQuotas(q)
                if updated != cachedQuotas { quotaVersion += 1 }
                cachedQuotas = updated
            case .failure(let err):
                // Neither endpoint answers: this key really can't read the gateway
                if traceForbidden { return offline(err.message) }
            }
        }
        if refreshUsage {
            // "today" in this computer's zone, as the usage page asks for it
            let tz = TimeZone.current.identifier.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if case .success(let u) = request(base: base, .usage, query: "?period=today&tz=" + tz, key: key),
               let d = u as? [String: Any] {
                cachedToday = MagpieToday(calls: d["calls"] as? Int ?? 0, input: d["input"] as? Int ?? 0,
                                          output: d["output"] as? Int ?? 0,
                                          cacheRead: d["cache_read"] as? Int ?? 0, cacheWrite: d["cache_write"] as? Int ?? 0,
                                          cost: Self.double(d["cost"]),
                                          unpriced: d["unpriced"] as? Int ?? 0)
            }
        }
        let today = cachedToday.map { "\($0.calls)|\($0.tokens)|\($0.cost ?? -1)|\($0.unpriced)" } ?? ""
        return MagpieSnapshot(
            generation: generation, online: true, error: nil,
            routingNote: traceForbidden ? Self.routingLocalOnly : nil,
            routes: routesByID.values.sorted { $0.seq < $1.seq },
            quotas: cachedQuotas,
            today: cachedToday,
            version: stamp("online|\(traceForbidden)|\(traceTick)|\(quotaVersion)|" + today),
            quotaVersion: quotaVersion)
    }

    /// Fold a trace response in; true when it changed what is kept.
    private func mergeTrace(_ trace: [String: Any]) -> Bool {
        let seq = trace["seq"] as? Int
        let before = routesByID.count
        var changed = false
        // Full response, or the gateway restarted (seq went backwards): start over
        if lastSeq == nil || (seq != nil && seq! < lastSeq!) { routesByID = [:]; changed = true }
        // Only the newest requests are ever shown; skip parsing (dates!) the rest
        for r in (trace["routes"] as? [[String: Any]] ?? []).suffix(Self.keepRoutes) {
            if let route = parseRoute(r) { routesByID[route.id] = route; changed = true }
        }
        // Drop requests that left the gateway's window, then keep only the newest
        if let ids = trace["ids"] as? [Int] {
            let live = Set(ids)
            routesByID = routesByID.filter { live.contains($0.key) }
        }
        if routesByID.count != before { changed = true }
        if routesByID.count > Self.keepRoutes {
            let keep = routesByID.values.sorted { $0.seq > $1.seq }.prefix(Self.keepRoutes)
            routesByID = Dictionary(uniqueKeysWithValues: keep.map { ($0.id, $0) })
        }
        lastSeq = seq ?? lastSeq
        return changed
    }

    /// Settings → 测试连接: probe a gateway without touching the saved config.
    static func probe(url: String, apiKey: String) -> String {
        let c = MagpieCollector()
        let base = MagpieConfig.normalize(url.isEmpty ? MagpieConfig.defaultURL : url)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trace = c.request(base: base, .trace, query: "?after=0", key: key)
        let quotas = c.request(base: base, .quotas, key: key)
        let subscriptions: String
        if case .success(let q) = quotas {
            subscriptions = "\(quotaItems(q).count) 个订阅"
        } else {
            subscriptions = "订阅不可读"
        }
        let via = c.access == .web ? "（网页 Key）" : ""
        switch (trace, quotas) {
        case (.success(let t), _):
            let n = ((t as? [String: Any])?["totals"] as? [String: Any])?["requests"] as? Int ?? 0
            return "✓ 已连接\(via) · 累计 \(n) 次请求 · \(subscriptions)"
        case (.failure(let err), .success) where err.status == 403:
            return "✓ 已连接 · \(subscriptions) · \(routingLocalOnly)"
        case (.failure(let err), _):
            return "✗ " + err.message
        }
    }

    // MARK: - HTTP

    struct FetchError: Error {
        let message: String
        var status: Int?
    }

    /// GET an endpoint the way `access` says. A 401 with a key means it isn't a
    /// gateway key, or the web cookie expired: sign in as the web page and retry.
    private func request(base: String, _ e: Endpoint, query: String = "",
                         key: String) -> Result<Any, FetchError> {
        let first = fetchJSON(base: base, path: path(e) + query, key: key)
        guard case .failure(let err) = first, err.status == 401, !key.isEmpty,
              base.hasPrefix("http"), signIn(base: base, key: key) else { return first }
        access = .web
        return fetchJSON(base: base, path: path(e) + query, key: key)
    }

    /// Open the page's sign-in link (/?k=<key>) and keep the cookie it sets.
    private func signIn(base: String, key: String) -> Bool {
        var comps = URLComponents(string: base + "/")
        comps?.queryItems = [URLQueryItem(name: "k", value: key)]
        guard let url = comps?.url else { return false }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var cookie: String?
        session.dataTask(with: url) { _, resp, _ in
            defer { sem.signal() }
            guard let http = resp as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { return }
            var fields: [String: String] = [:]
            for (k, v) in http.allHeaderFields { fields["\(k)"] = "\(v)" }
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            if !cookies.isEmpty { cookie = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ") }
        }.resume()
        sem.wait()
        webCookie = cookie
        if cookie != nil { log("[Magpie] Signed in to \(base) with its web key") }
        return cookie != nil
    }

    private func fetchJSON(base: String, path: String, key: String) -> Result<Any, FetchError> {
        guard let url = URL(string: base + path) else {
            return .failure(FetchError(message: "地址无效：\(base)"))
        }
        var req = URLRequest(url: url)
        if access == .web, let webCookie {
            req.setValue(webCookie, forHTTPHeaderField: "Cookie")
        } else if !key.isEmpty, url.scheme?.hasPrefix("http") == true {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<Any, FetchError> =
            .failure(FetchError(message: "无法连接"))
        let task = session.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err = err as? URLError {
                result = .failure(FetchError(message: err.code == .timedOut ? "连接超时" : "无法连接"))
                return
            }
            // file:// base URLs (canned trace/quotas for testing) have no HTTP status
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                let msg: String
                switch http.statusCode {
                case 401: msg = key.isEmpty ? "需要 API Key（HTTP 401）" : "API Key 无效（HTTP 401）"
                case 403: msg = "API Key 无权访问（HTTP 403）"
                case 404: msg = "不是 magpie 网关（HTTP 404）"
                default:  msg = "网关返回 HTTP \(http.statusCode)"
                }
                result = .failure(FetchError(message: msg, status: http.statusCode))
                return
            }
            guard let data, let obj = try? JSONSerialization.jsonObject(with: data),
                  obj is [String: Any] || obj is [Any]
            else {
                result = .failure(FetchError(message: "响应不是 magpie 数据"))
                return
            }
            result = .success(obj)
        }
        task.resume()
        sem.wait()
        return result
    }

    // MARK: - Parsing

    private func parseRoute(_ r: [String: Any]) -> MagpieRoute? {
        guard let id = r["id"] as? Int, let seq = r["seq"] as? Int,
              let time = Self.date(r["time"]) else { return nil }
        let group = r["group"] as? [String: Any]
        let members = (r["order"] as? [[String: Any]] ?? []).map(Self.member)
        let left = (r["left"] as? [[String: Any]] ?? []).map(Self.member)
        let tries = (r["tries"] as? [[String: Any]] ?? []).map { t in
            MagpieTry(
                id: t["id"] as? String ?? "",
                done: t["done"] as? Bool ?? false,
                status: t["status"] as? Int,
                ms: t["ms"] as? Int,
                ttft: t["ttft"] as? Int,
                start: Self.date(t["start"]),
                error: Self.errorText(t["error"]),
                fail: t["fail"] as? String,
                rest: Self.rest(t["rest"]),
                again: t["again"] as? Bool ?? false,
                credits: t["credits"] as? Bool ?? false,
                earlier: t["earlier"] as? Bool ?? false,
                served: (t["served"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        return MagpieRoute(
            id: id, seq: seq, time: time,
            agent: r["agent"] as? String ?? "?",
            model: r["model"] as? String ?? "",
            provider: r["provider"] as? String ?? "",
            groupID: group?["id"] as? String,
            groupRef: group?["ref"] as? String,
            groupName: group?["name"] as? String,
            routing: group?["routing"] as? String,
            members: members, left: left,
            groupMembers: group?["members"] as? [String] ?? [],
            tries: tries,
            phase: r["phase"] as? String,
            error: Self.errorText(r["error"]),
            done: r["done"] as? Bool ?? false,
            status: r["status"] as? Int,
            ms: r["ms"] as? Int,
            tokens: r["tokens"] as? Int,
            out: r["out"] as? Int,
            folder: r["folder"] as? String)
    }

    private static func member(_ o: [String: Any]) -> MagpieMember {
        let renews = (o["renews"] as? [String]) ?? []
        return MagpieMember(
            id: o["id"] as? String ?? "",
            kind: o["kind"] as? String ?? "",
            provider: o["provider"] as? String ?? "",
            name: o["name"] as? String ?? (o["id"] as? String ?? "?"),
            icon: o["icon"] as? String,
            who: o["who"] as? String,
            plan: o["plan"] as? String,
            model: o["model"] as? String ?? "",
            routing: o["routing"] as? String ?? "",
            known: o["known"] as? Bool ?? false,
            usedPercent: double(o["used"]),
            due: date(o["due"]),
            // the window "used" is of; without it only a one-window account says when
            renews: date(o["usedRenews"]) ?? (renews.count == 1 ? date(renews[0]) : nil),
            credits: o["credits"] as? Bool ?? false,
            creditsLast: o["creditsLast"] as? Bool ?? false,
            rest: rest(o["rest"]),
            unlisted: o["unlisted"] as? Bool ?? false,
            held: o["held"] as? Bool ?? false,
            noCredits: o["noCredits"] as? Bool ?? false,
            capped: o["capped"] as? Int,
            barred: o["barred"] as? Bool ?? false,
            window: o["window"] as? Int,
            fallback: o["fallback"] as? Bool ?? false,
            aside: o["aside"] as? Bool ?? false)
    }

    private static func rest(_ v: Any?) -> MagpieRest? {
        guard let d = v as? [String: Any], let until = date(d["until"]) else { return nil }
        return MagpieRest(why: d["why"] as? String ?? "other", status: d["status"] as? Int, until: until)
    }

    /// The gateway wraps quotas as {"data": [...]}; the web page's endpoint is a bare array.
    private static func quotaItems(_ q: Any) -> [[String: Any]] {
        (q as? [[String: Any]]) ?? ((q as? [String: Any])?["data"] as? [[String: Any]]) ?? []
    }

    private func parseQuotas(_ q: Any) -> [MagpieQuota] {
        let now = Date()
        return Self.quotaItems(q).map { d in
            let provider = d["provider"] as? String ?? ""
            let plan = d["plan"] as? String, user = d["user"] as? String
            let windows = (d["windows"] as? [[String: Any]] ?? []).map { w in
                MagpieQuotaWindow(name: w["name"] as? String ?? "",
                                  usedPercent: Self.double(w["used"]) ?? 0,
                                  resetsAt: Self.date(w["resetsAt"]))
            }
            // Usage rising since the last refresh = this account is being used now
            let key = "\(provider)|\(user ?? "")|\(plan ?? "")"
            let total = windows.reduce(0) { $0 + $1.usedPercent }
            var roseAt = usageSeen[key]?.roseAt
            if let prev = usageSeen[key], total > prev.total + 0.01 { roseAt = now }
            usageSeen[key] = (total, roseAt)
            let served = Self.date(d["lastServedAt"])
            return MagpieQuota(
                provider: provider,
                name: d["name"] as? String ?? "",
                plan: plan, user: user, windows: windows,
                error: d["error"] as? String,
                balance: d["balance"] as? String,
                lastServedAt: served,
                activeAt: [served, roseAt].compactMap { $0 }.max())
        }
    }

    private static func errorText(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let d = v as? [String: Any] { return d["message"] as? String }
        return nil
    }

    private static func double(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    // magpie mixes "…20:22:55.746581+08:00" and "…16:10:00Z"
    nonisolated(unsafe) private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }
}

/// Hands 3xx responses back instead of following them, so the web sign-in's
/// Set-Cookie (on the 303) can be read.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
