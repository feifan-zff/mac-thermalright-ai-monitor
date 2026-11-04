import AppKit
import ImageIO
import XCTest
@testable import MacTR

final class RegressionTests: XCTestCase {
    func testSameAccountInTwoModelsKeepsSeparateRows() {
        let members = [member("a", model: "first"), member("a", model: "second")]
        let rows = RoutingGroup.rows(route(members: members), now: Date(), mask: { $0 })
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
        XCTAssertEqual(Set(rows.map(\.member.model)), ["first", "second"])
    }

    func testFoldsForTwoModelsKeepTheirOwnChildren() {
        let members = ["first", "second"].flatMap { model in
            ["a", "b", "c"].map { member($0, model: model) }
        }
        let rows = RoutingGroup.stage([route(members: members)], headed: true, now: Date(), mask: { $0 })
        let folds = rows.filter(\.isFold)
        XCTAssertEqual(folds.count, 2)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        for fold in folds {
            let children = rows.filter { $0.parent == fold.id }
            XCTAssertEqual(children.count, 3)
            XCTAssertTrue(children.allSatisfy { $0.member.model == fold.member.model })
        }
    }

    func testStreamingFailureAfterHTTP200IsNotSuccess() {
        let broken = attempt(status: 200, fail: "offline")
        XCTAssertTrue(route(tries: [broken], done: true, status: 200).failed)
        XCTAssertTrue(route(done: true, status: 200, error: "stream interrupted").failed)
        XCTAssertFalse(route(tries: [broken], done: false, status: 200).failed)
    }

    func testRecoveredRetryStillCountsAsSuccess() {
        let failed = attempt(status: 429, fail: "rate")
        let succeeded = attempt(status: 200)
        XCTAssertFalse(route(tries: [failed, succeeded], done: true, status: 200).failed)
    }

    func testGatewayResetForgetsFlightsAndSeenRequestIDs() {
        let director = FlightDirector()
        let now = Date().timeIntervalSince1970
        director.update([route(done: true, status: 200)], now: now)
        XCTAssertFalse(director.isPlaying(1))
        director.reset()
        director.update([route()], now: now)
        XCTAssertTrue(director.isPlaying(1))
        director.reset()
        XCTAssertFalse(director.isPlaying(1))
        XCTAssertNil(director.frameRate(now: now))
    }

    func testQuotaMetadataChangesAreVisible() {
        func quota(name: String = "Original", plan: String = "Basic") -> MagpieQuota {
            MagpieQuota(provider: "test", name: name, plan: plan, user: "account",
                        windows: [MagpieQuotaWindow(name: "5 hours", usedPercent: 42, resetsAt: nil)],
                        error: nil, balance: nil, lastServedAt: nil, activeAt: nil)
        }
        let original = [quota()]
        XCTAssertEqual(original, [quota()])
        XCTAssertNotEqual(original, [quota(name: "Renamed")])
        XCTAssertNotEqual(original, [quota(plan: "Pro")])
    }

    func testTemporaryConvertedPixelsSurviveJPEGEncoding() throws {
        // Grayscale forces rgbaBytes to allocate a temporary converted image.
        // Run with release optimization, where ARC can end a local's lifetime early.
        let oldHardware = JPEGEncoder.useHardware
        defer { JPEGEncoder.useHardware = oldHardware }
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 32,
                                             bitsPerComponent: 8, bytesPerRow: 64,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        context.setFillColor(gray: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        context.setFillColor(gray: 0.8, alpha: 1)
        context.fill(CGRect(x: 32, y: 0, width: 32, height: 32))
        let image = try XCTUnwrap(context.makeImage())
        for hardware in [false, true] {
            JPEGEncoder.useHardware = hardware
            for _ in 0..<8 {
                try autoreleasepool {
                    let data = try XCTUnwrap(JPEGEncoder.encode(image, brightness: 3, rotate180: true))
                    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                    let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                    XCTAssertEqual(decoded.width, 64)
                    XCTAssertEqual(decoded.height, 32)
                    let rgb = try XCTUnwrap(CGContext(data: nil, width: 64, height: 32,
                                                     bitsPerComponent: 8, bytesPerRow: 256,
                                                     space: CGColorSpaceCreateDeviceRGB(),
                                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    rgb.draw(decoded, in: CGRect(x: 0, y: 0, width: 64, height: 32))
                    let pixels = try XCTUnwrap(rgb.data).assumingMemoryBound(to: UInt8.self)
                    // Rotation puts the bright half on the left; inspect far from the JPEG seam.
                    XCTAssertGreaterThan(pixels[16 * 256 + 8 * 4], 190)
                    XCTAssertLessThan(pixels[16 * 256 + 56 * 4], 80)
                }
            }
        }
    }

    func testProviderRowSaysItsOutputSpeed() {
        let provider = member("us", model: "auto/glm", kind: "provider")
        // streamed: 100 tokens in the 1s window after its first token → 100 tok/s
        let streamed = attempt(status: 200, ms: 2000, ttft: 1000, served: "GLM-5.3")
        let r = route(members: [provider], tries: [streamed], done: true, status: 200, out: 100)
        let rows = RoutingGroup.rows(r, now: Date(), mask: { $0 })
        XCTAssertEqual(rows.first?.status, "100 tok/s")
    }

    func testRepliedInABurstTellsNoSpeed() {
        // a relay held the reply back and let it go at its end: a 10 ms window
        // says nothing; the words fall back to what they said before
        let provider = member("us", model: "auto/glm", kind: "provider")
        let burst = attempt(status: 200, ms: 2000, ttft: 1990, served: "GLM-5.3")
        let r = route(members: [provider], tries: [burst], done: true, status: 200, out: 100)
        XCTAssertEqual(RoutingGroup.rows(r, now: Date(), mask: { $0 }).first?.status, "GLM-5.3")
    }

    func testProviderRowWithoutTokensFallsBackToServedModel() {
        // the reply's tokens come with the route done; until then, the model says it
        let provider = member("us", model: "auto/glm", kind: "provider")
        let done = attempt(status: 200, served: "GLM-5.3")
        let r = route(members: [provider], tries: [done], done: true, status: 200, out: nil)
        XCTAssertEqual(RoutingGroup.rows(r, now: Date(), mask: { $0 }).first?.status, "GLM-5.3")
    }

    func testAccountRowSaysItsOutputSpeedToo() {
        // the routing group's rows are accounts; they say it as providers do
        let account = member("a", model: "auto/glm")
        let r = route(members: [account], tries: [attempt(status: 200, ms: 5000, ttft: 1000, id: "a")],
                      done: true, status: 200, out: 100)
        XCTAssertEqual(RoutingGroup.rows(r, now: Date(), mask: { $0 }).first?.status, "25 tok/s")
    }

    func testAnsweredRowWithoutTokensStillSaysAnswered() {
        // the reply's tokens come with the route done; until then, the words hold
        let account = member("a", model: "auto/glm")
        let r = route(members: [account], tries: [attempt(status: 200, id: "a")],
                      done: true, status: 200, out: nil)
        XCTAssertEqual(RoutingGroup.rows(r, now: Date(), mask: { $0 }).first?.status, "已回答")
    }

    func testRetrySpeedUsesOneTimingOrigin() {
        let provider = member("us", model: "auto/glm", kind: "provider")
        let tries = [attempt(status: 429, fail: "rate", ms: 5000),
                     attempt(status: 200, ms: 2000, ttft: 1000)]
        let fallback = route(members: [provider], tries: tries, done: true, status: 200, out: 100, ms: 7000)
        XCTAssertEqual(RoutingGroup.rows(fallback, now: Date(), mask: { $0 }).first?.status, "100 tok/s")
        let complete = route(members: [provider], tries: tries, done: true, status: 200,
                             out: 100, ms: 7000, ttft: 6000)
        XCTAssertEqual(RoutingGroup.rows(complete, now: Date(), mask: { $0 }).first?.status, "100 tok/s")
    }

    func testDecodeHandlesExtremeAndInvalidTraceNumbers() {
        XCTAssertNil(RoutingGroup.decode(out: Int.max, ms: 2000, ttft: 1000, firstText: nil,
                                        flow: nil, firstReasoning: nil, reasoning: nil, reasoningHidden: nil))
        let long = RoutingGroup.decode(out: 100, ms: Int.max, ttft: 1, firstText: nil,
                                       flow: Int.max, firstReasoning: nil, reasoning: nil, reasoningHidden: nil)
        XCTAssertEqual(long?.n, 100)
        XCTAssertEqual(long?.w, Int.max - 1)
        XCTAssertNil(RoutingGroup.decode(out: 100, ms: 2000, ttft: 1000, firstText: Int.min,
                                        flow: nil, firstReasoning: nil, reasoning: 10, reasoningHidden: true))
    }

    func testDecodeExcludesHiddenReasoningAndRejectsBufferedReplies() {
        let answer = RoutingGroup.decode(out: 600, ms: 5000, ttft: 1000, firstText: 4000,
                                         flow: 1000, firstReasoning: nil, reasoning: 500, reasoningHidden: true)
        XCTAssertEqual(answer?.n, 100)
        XCTAssertEqual(answer?.w, 1000)
        XCTAssertNil(RoutingGroup.decode(out: 100, ms: 2000, ttft: 1000, firstText: nil,
                                        flow: 10, firstReasoning: nil, reasoning: nil, reasoningHidden: nil))
    }

    func testBulkWriteFinishesShortTransfers() throws {
        var calls: [(Int, Int)] = []
        let total = try USBDevice.writeAll(count: 2048) { offset, remaining in
            calls.append((offset, remaining))
            return min(512, remaining)
        }
        XCTAssertEqual(total, 2048)
        XCTAssertEqual(calls.map(\.0), [0, 512, 1024, 1536])
        XCTAssertEqual(calls.map(\.1), [2048, 1536, 1024, 512])
    }

    func testBulkWriteRejectsNoProgressAndPropagatesFailure() {
        XCTAssertThrowsError(try USBDevice.writeAll(count: 512) { _, _ in 0 })
        XCTAssertThrowsError(try USBDevice.writeAll(count: 512) { _, _ in throw USBError.writeFailed(-7) })
    }

    func testOversizedFrameIsRejectedBeforeUSBAccess() {
        XCTAssertThrowsError(try LYProtocol.sendFrame(device: USBDevice(), jpegData: Data(count: 650_001))) { error in
            guard case LYError.frameTooLarge(650_001) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testJPEGNeverExceedsRequestedByteLimit() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 32,
                                             bitsPerComponent: 8, bytesPerRow: 256,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let oldHardware = JPEGEncoder.useHardware
        defer { JPEGEncoder.useHardware = oldHardware }
        for hardware in [false, true] {
            JPEGEncoder.useHardware = hardware
            XCTAssertNil(JPEGEncoder.encode(image, maxBytes: 1))
            let jpeg = try XCTUnwrap(JPEGEncoder.encode(image, maxBytes: 10_000))
            XCTAssertLessThanOrEqual(jpeg.count, 10_000)
        }
    }

    private func member(_ id: String, model: String, kind: String = "account") -> MagpieMember {
        MagpieMember(id: id, kind: kind, provider: "test", name: "Test", icon: nil,
                     who: id, plan: nil, model: model, routing: "", known: false,
                     usedPercent: nil, due: nil, renews: nil, credits: false, creditsLast: false,
                     rest: nil, unlisted: false, held: false, noCredits: false, capped: nil,
                     barred: false, window: nil, fallback: false, aside: false)
    }

    private func attempt(status: Int, fail: String? = nil, ms: Int = 100, ttft: Int? = nil,
                         served: String? = nil, id: String = "us") -> MagpieTry {
        MagpieTry(id: id, done: true, status: status, ms: ms, ttft: ttft, start: nil,
                  error: nil, fail: fail, rest: nil, again: false, credits: false, earlier: false, served: served)
    }

    private func route(members: [MagpieMember] = [], tries: [MagpieTry] = [],
                       done: Bool = false, status: Int? = nil, error: String? = nil,
                       out: Int? = nil, ms: Int? = nil, ttft: Int? = nil) -> MagpieRoute {
        MagpieRoute(id: 1, seq: 1, time: Date(), agent: "test", model: "group", provider: "test",
                    groupID: "g", groupRef: "auto/test", groupName: "Test", routing: "order",
                    members: members, left: [], groupMembers: ["test/first", "test/second"],
                    tries: tries, phase: nil, error: error, done: done, status: status,
                    ms: ms, tokens: nil, out: out, ttft: ttft, firstText: nil, flow: nil,
                    firstReasoning: nil, reasoning: nil, reasoningHidden: nil, folder: nil)
    }
}
