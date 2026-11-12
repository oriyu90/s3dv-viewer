import XCTest
@testable import S3DVControl

/// The control line is the only interface `s3dvctl` and a human with `nc -U`
/// share, so its parsing rules are pinned here.
final class ControlProtocolTests: XCTestCase {
    func testJSONRequestBecomesCommandAndArguments() throws {
        let request = try XCTUnwrap(ControlRequest.parse(#"{"cmd":"seek","t":12.5}"#))
        XCTAssertEqual(request.cmd, "seek")
        XCTAssertEqual(request.double("t"), 12.5)
    }

    func testCommandIsCaseInsensitive() throws {
        let request = try XCTUnwrap(ControlRequest.parse(#"{"cmd":"STATUS"}"#))
        XCTAssertEqual(request.cmd, "status")
    }

    func testTextRequestWithKeyValuePairs() throws {
        let request = try XCTUnwrap(ControlRequest.parse("open path=/tmp/a.s3dv flag=on"))
        XCTAssertEqual(request.cmd, "open")
        XCTAssertEqual(request.string("path"), "/tmp/a.s3dv")
        XCTAssertEqual(request.flag("flag"), true)
    }

    func testBareTokensBecomePositionalArguments() throws {
        let request = try XCTUnwrap(ControlRequest.parse("rate 0.5"))
        XCTAssertEqual(request.double("arg0"), 0.5)
        let two = try XCTUnwrap(ControlRequest.parse("set rate 0.5"))
        XCTAssertEqual(two.string("arg0"), "rate")
        XCTAssertEqual(two.string("arg1"), "0.5")
    }

    func testFlagSpellings() throws {
        for (text, expected) in [("on", true), ("true", true), ("1", true), ("yes", true),
                                 ("off", false), ("false", false), ("0", false), ("no", false)] {
            let request = try XCTUnwrap(ControlRequest.parse("loop \(text)"))
            XCTAssertEqual(request.flag("arg0"), expected, "loop \(text)")
        }
        let unknown = try XCTUnwrap(ControlRequest.parse("loop maybe"))
        XCTAssertNil(unknown.flag("arg0"))
    }

    func testMalformedInputIsRejected() {
        XCTAssertNil(ControlRequest.parse(""))
        XCTAssertNil(ControlRequest.parse("   \n"))
        XCTAssertNil(ControlRequest.parse(#"{"cmd":}"#))
        XCTAssertNil(ControlRequest.parse(#"{"nope":"seek"}"#))
        XCTAssertNil(ControlRequest.parse(#"{"cmd":""}"#))
    }

    func testEmptyStringArgumentsReadAsNil() throws {
        let request = try XCTUnwrap(ControlRequest.parse(#"{"cmd":"open","path":""}"#))
        XCTAssertNil(request.string("path"))
    }

    func testSocketPathHonoursEnvironmentOverride() {
        let override = ControlPath.socketURL(environment: [ControlPath.socketEnvironmentKey: "/tmp/x.sock"])
        XCTAssertEqual(override.path, "/tmp/x.sock")
        let fallback = ControlPath.socketURL(environment: [:])
        XCTAssertTrue(fallback.path.hasSuffix("/S3DV viewer/control.sock"))
    }

    func testJSONReplyIsSortedAndParseable() throws {
        let text = ControlJSON.encode(["ok": true, "chunks": 8, "name": "a b"])
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["chunks"] as? Int, 8)
        XCTAssertTrue(text.hasPrefix("{"))
        XCTAssertFalse(text.contains("\n"), "compact replies stay on one line")
    }

    func testErrorReplyShape() throws {
        let text = ControlJSON.error("boom")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["error"] as? String, "boom")
    }
}
