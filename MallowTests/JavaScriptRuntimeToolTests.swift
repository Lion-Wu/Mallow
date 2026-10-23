import XCTest
@testable import Mallow
#if canImport(CoreLocation) && canImport(Contacts) && canImport(MapKit)
import Contacts
import CoreLocation
import MapKit
#endif

final class JavaScriptRuntimeToolTests: XCTestCase {
    func testKeepsJSONNumbersAndBooleansDistinct() async throws {
        let result = try await run("({ zero: input.zero, one: input.one, enabled: input.enabled });", input: [
            "zero": 0,
            "one": 1,
            "enabled": true
        ])

        XCTAssertEqual(result.payload["result"], .object([
            "zero": .number(0),
            "one": .number(1),
            "enabled": .bool(true)
        ]))
    }

    func testBoundsLargeResultsAndReportsTruncation() async throws {
        let result = try await run("[range(1, 250), \"x\".repeat(70000)];")

        guard case let .array(values) = result.payload["result"],
              case let .array(numbers) = values.first,
              case let .string(text) = values.last else {
            return XCTFail("Expected bounded array and string output")
        }
        XCTAssertEqual(numbers.count, 200)
        XCTAssertEqual(text.count, 4_000)
        XCTAssertEqual(result.payload["truncated"], .bool(true))
    }

    func testDoesNotExposeNetworkFilesystemOrNativeBridgeGlobals() async throws {
        let result = try await run("""
        ({
            restricted: [
                typeof fetch,
                typeof XMLHttpRequest,
                typeof WebSocket,
                typeof webkit,
                typeof require,
                typeof process,
                typeof this.fetch,
                typeof this.webkit
            ],
            printType: typeof print,
            consoleLogType: typeof console.log
        });
        """)

        XCTAssertEqual(result.payload["result"], .object([
            "restricted": .array(Array(repeating: .string("undefined"), count: 8)),
            "printType": .string("function"),
            "consoleLogType": .string("function")
        ]))
    }

    func testRejectsDynamicCodeGeneration() async {
        await assertInvalidScript(#"(() => {})["constructor"]("return 7")();"#)
    }

    func testInfiniteLoopTimesOutAndNextExecutionStillWorks() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await JavaScriptRuntime.evaluate(
                code: "while (true) {}",
                input: [:],
                timeoutSeconds: 0.2
            )
            XCTFail("Expected timeout")
        } catch let error as ChatToolError {
            XCTAssertEqual(error.resultStatus, .failed)
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(3))

        let recovery = try await run("7;")
        XCTAssertEqual(recovery.payload["result"], .number(7))
    }

    func testRejectsOversizedCodeInputOrNonObjectInput() async throws {
        do {
            _ = try await run(String(repeating: "0;", count: 128_001))
            XCTFail("Expected oversized code error")
        } catch let error as ChatToolError {
            XCTAssertEqual(error.resultStatus, .invalidArguments)
        }

        let oversized = String(repeating: "x", count: 4_000_001)
        do {
            _ = try await run("input.value.length;", input: ["value": oversized])
            XCTFail("Expected oversized input error")
        } catch let error as ChatToolError {
            XCTAssertEqual(error.resultStatus, .invalidArguments)
        }

        do {
            let reader = try ChatToolArgumentReader(argumentsJSON: #"{"code":"1;","input":[]}"#)
            _ = try await SandboxedJavaScriptRuntimeTool().run(arguments: reader)
            XCTFail("Expected object input error")
        } catch let error as ChatToolError {
            XCTAssertEqual(error.resultStatus, .invalidArguments)
        }
    }

    #if canImport(CoreLocation) && canImport(Contacts) && canImport(MapKit)
    #endif

    private func run(
        _ code: String,
        input: [String: Any] = [:]
    ) async throws -> ChatToolExecutionPayload {
        let arguments: [String: Any] = ["code": code, "input": input]
        let data = try JSONSerialization.data(withJSONObject: arguments)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let reader = try ChatToolArgumentReader(argumentsJSON: json)
        return try await SandboxedJavaScriptRuntimeTool().run(arguments: reader)
    }

    private func assertInvalidScript(_ code: String, containing fragments: [String] = []) async {
        do {
            _ = try await run(code)
            XCTFail("Expected invalid arguments")
        } catch let error as ChatToolError {
            XCTAssertEqual(error.resultStatus, .invalidArguments)
            for fragment in fragments {
                XCTAssertTrue(error.localizedDescription.contains(fragment), error.localizedDescription)
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func jsonNodeCount(_ value: JSONValue?) -> Int {
        guard let value else { return 0 }
        switch value {
        case .string, .number, .bool, .null:
            return 1
        case let .array(values):
            return 1 + values.reduce(0) { $0 + jsonNodeCount($1) }
        case let .object(values):
            return 1 + values.values.reduce(0) { $0 + jsonNodeCount($1) }
        }
    }
}
