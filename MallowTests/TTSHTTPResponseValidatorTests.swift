import XCTest
@testable import Mallow

final class TTSHTTPResponseValidatorTests: XCTestCase {
    func testRetryableStatusClassifiesTransientFailure() throws {
        let response = try makeResponse(statusCode: 503, contentType: "text/plain")

        let failure = try XCTUnwrap(TTSHTTPResponseValidator.failure(for: response, data: nil))

        XCTAssertEqual(failure.disposition, .transient)
        XCTAssertTrue(failure.message.contains("503"))
    }

    func testNonAudioSuccessClassifiesContentFailure() throws {
        let response = try makeResponse(statusCode: 200, contentType: "application/json")
        let body = Data("{\"error\":\"not audio\"}".utf8)

        let failure = try XCTUnwrap(TTSHTTPResponseValidator.failure(for: response, data: body))

        XCTAssertEqual(failure.disposition, .content)
        XCTAssertTrue(failure.message.contains("not audio"))
    }

    private func makeResponse(statusCode: Int, contentType: String) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(
            url: XCTUnwrap(URL(string: "http://localhost:9880/tts")),
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        ))
    }
}
