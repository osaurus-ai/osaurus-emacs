import XCTest

@testable import Emacs

final class EmacsTests: XCTestCase {

  // MARK: - Manifest

  func testManifestParsesAndDescribesTool() throws {
    let data = Data(emacsManifestJSON.utf8)
    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let manifest = try XCTUnwrap(root, "manifest should decode to a JSON object")

    XCTAssertEqual(manifest["plugin_id"] as? String, "osaurus.emacs")

    let capabilities = try XCTUnwrap(manifest["capabilities"] as? [String: Any])
    let tools = try XCTUnwrap(capabilities["tools"] as? [[String: Any]])
    XCTAssertEqual(tools.count, 1)

    let tool = try XCTUnwrap(tools.first)
    let id = try XCTUnwrap(tool["id"] as? String)
    let description = try XCTUnwrap(tool["description"] as? String)
    XCTAssertFalse(id.isEmpty, "tool id must be non-empty")
    XCTAssertFalse(description.isEmpty, "tool description must be non-empty")
    XCTAssertEqual(id, "execute_emacs_lisp_code")
  }

  // MARK: - Envelope

  func testFailureEnvelopeRoundTrip() throws {
    let json = Envelope.failure(.invalidArgs, "Missing or empty 'code' argument")
    let data = Data(json.utf8)
    let obj = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertEqual(obj["ok"] as? Bool, false)
    XCTAssertEqual(obj["kind"] as? String, "invalid_args")
    XCTAssertEqual(obj["message"] as? String, "Missing or empty 'code' argument")
    XCTAssertEqual(obj["retryable"] as? Bool, true)
  }

  func testFailureEnvelopeDefaultRetryablePerKind() throws {
    func retryable(_ json: String) throws -> Bool {
      let obj = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
      return try XCTUnwrap(obj["retryable"] as? Bool)
    }

    XCTAssertTrue(try retryable(Envelope.failure(.invalidArgs, "x")))
    XCTAssertTrue(try retryable(Envelope.failure(.executionError, "x")))
    XCTAssertTrue(try retryable(Envelope.failure(.unavailable, "x")))
    XCTAssertFalse(try retryable(Envelope.failure(.notFound, "x")))
  }

  func testFailureEnvelopeEscapesSpecialCharacters() throws {
    let message = "line1\nline2\t\"quoted\" \\backslash"
    let json = Envelope.failure(.executionError, message)
    let obj = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    XCTAssertEqual(obj["message"] as? String, message)
  }
}
