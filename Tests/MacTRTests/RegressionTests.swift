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

    private func member(_ id: String, model: String) -> MagpieMember {
        MagpieMember(id: id, kind: "account", provider: "test", name: "Test", icon: nil,
                     who: id, plan: nil, model: model, routing: "", known: false,
                     usedPercent: nil, due: nil, renews: nil, credits: false, creditsLast: false,
                     rest: nil, unlisted: false, held: false, noCredits: false, capped: nil,
                     barred: false, window: nil, fallback: false, aside: false)
    }

    private func attempt(status: Int, fail: String? = nil) -> MagpieTry {
        MagpieTry(id: "a", done: true, status: status, ms: 100, ttft: nil, start: nil,
                  error: nil, fail: fail, rest: nil, again: false, credits: false, earlier: false, served: nil)
    }

    private func route(members: [MagpieMember] = [], tries: [MagpieTry] = [],
                       done: Bool = false, status: Int? = nil, error: String? = nil) -> MagpieRoute {
        MagpieRoute(id: 1, seq: 1, time: Date(), agent: "test", model: "group", provider: "test",
                    groupID: "g", groupRef: "auto/test", groupName: "Test", routing: "order",
                    members: members, left: [], groupMembers: ["test/first", "test/second"],
                    tries: tries, phase: nil, error: error, done: done, status: status,
                    ms: nil, tokens: nil, out: nil, folder: nil)
    }
}
