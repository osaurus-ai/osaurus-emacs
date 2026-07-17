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

  func testManifestVersionMatchesReleasedVersion() throws {
    let data = Data(emacsManifestJSON.utf8)
    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let manifest = try XCTUnwrap(root)
    XCTAssertEqual(manifest["version"] as? String, "1.0.3")
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
    XCTAssertEqual(obj["retryable"] as? Bool, false)
  }

  func testFailureEnvelopeDefaultRetryablePerKind() throws {
    func retryable(_ json: String) throws -> Bool {
      let obj = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
      return try XCTUnwrap(obj["retryable"] as? Bool)
    }

    XCTAssertFalse(try retryable(Envelope.failure(.invalidArgs, "x")))
    XCTAssertTrue(try retryable(Envelope.failure(.executionError, "x")))
    XCTAssertTrue(try retryable(Envelope.failure(.unavailable, "x")))
    XCTAssertFalse(try retryable(Envelope.failure(.notFound, "x")))
    XCTAssertTrue(try retryable(Envelope.failure(.timeout, "x")))
  }

  func testFailureEnvelopeEscapesSpecialCharacters() throws {
    let message = "line1\nline2\t\"quoted\" \\backslash"
    let json = Envelope.failure(.executionError, message)
    let obj = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    XCTAssertEqual(obj["message"] as? String, message)
  }

  // MARK: - Fixtures

  /// Writes a fake emacsclient shell script into a fresh temp directory and
  /// returns its absolute path. The fixture stands in for a real Emacs.
  private func makeStub(
    body: String, name: String = "emacsclient", executable: Bool = true
  ) throws -> String {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("emacs-plugin-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent(name)
    try ("#!/bin/sh\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
    if executable {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    return file.path
  }

  private func runTool(_ code: String, path: String, timeout: TimeInterval = 30) throws
    -> [String: Any]
  {
    let tool = ExecuteElispTool(timeout: timeout)
    let args = try JSONSerialization.data(
      withJSONObject: ["code": code, "emacsclient_path": path])
    let response = tool.run(args: String(decoding: args, as: UTF8.self))
    let obj = try JSONSerialization.jsonObject(with: Data(response.utf8))
    return try XCTUnwrap(obj as? [String: Any])
  }

  // MARK: - emacsclient_path validation

  func testRejectsRelativeEmacsclientPath() throws {
    let result = try runTool("(+ 1 2)", path: "emacsclient")
    XCTAssertEqual(result["ok"] as? Bool, false)
    XCTAssertEqual(result["kind"] as? String, "invalid_args")
    XCTAssertEqual(result["retryable"] as? Bool, false)
  }

  func testRejectsNonexistentEmacsclientPath() throws {
    let result = try runTool("(+ 1 2)", path: "/nonexistent/dir/emacsclient")
    XCTAssertEqual(result["kind"] as? String, "invalid_args")
  }

  func testRejectsEmacsclientPathWithWrongBasename() throws {
    let stub = try makeStub(body: "echo ok", name: "not-emacsclient")
    let result = try runTool("(+ 1 2)", path: stub)
    XCTAssertEqual(result["kind"] as? String, "invalid_args")
  }

  func testRejectsNonExecutableEmacsclientPath() throws {
    let stub = try makeStub(body: "echo ok", executable: false)
    let result = try runTool("(+ 1 2)", path: stub)
    XCTAssertEqual(result["kind"] as? String, "invalid_args")
  }

  func testRejectsDirectoryEmacsclientPath() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("emacs-plugin-tests-\(UUID().uuidString)")
      .appendingPathComponent("emacsclient")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    let result = try runTool("(+ 1 2)", path: dir.path)
    XCTAssertEqual(result["kind"] as? String, "invalid_args")
  }

  // MARK: - Subprocess execution via stub

  func testStubEmacsclientSuccess() throws {
    let stub = try makeStub(body: "echo '3'")
    let result = try runTool("(+ 1 2)", path: stub)
    XCTAssertEqual(result["result"] as? String, "3")
  }

  func testStubEmacsclientTimesOut() throws {
    let stub = try makeStub(body: "sleep 30")
    let start = Date()
    let result = try runTool("(+ 1 2)", path: stub, timeout: 1)
    XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    XCTAssertEqual(result["ok"] as? Bool, false)
    XCTAssertEqual(result["kind"] as? String, "timeout")
    XCTAssertEqual(result["retryable"] as? Bool, true)
  }

  func testStubEmacsclientLargeOutputDoesNotDeadlock() throws {
    // 2 MB is far beyond the 64 KB pipe buffer that deadlocks a
    // wait-then-read implementation.
    let stub = try makeStub(body: "head -c 2000000 /dev/zero | tr '\\0' 'x'")
    let result = try runTool("(+ 1 2)", path: stub, timeout: 30)
    let output = try XCTUnwrap(result["result"] as? String)
    XCTAssertEqual(output.count, 2_000_000)
  }

  func testStubEmacsclientServerUnavailableStderr() throws {
    let stub = try makeStub(body: "echo \"can't find socket\" >&2; exit 1")
    let result = try runTool("(+ 1 2)", path: stub)
    XCTAssertEqual(result["ok"] as? Bool, false)
    XCTAssertEqual(result["kind"] as? String, "unavailable")
  }

  // MARK: - ProcessRunner

  func testProcessRunnerCapsCapturedOutput() throws {
    let output = try ProcessRunner.run(
      executable: "/bin/sh",
      arguments: ["-c", "head -c 100000 /dev/zero | tr '\\0' 'x'"],
      timeout: 30,
      maxOutputBytes: 1000)
    XCTAssertEqual(output.exitStatus, 0)
    XCTAssertEqual(output.stdout.count, 1000)
  }

  func testProcessRunnerReportsTimeout() throws {
    let output = try ProcessRunner.run(
      executable: "/bin/sh", arguments: ["-c", "sleep 30"], timeout: 1)
    XCTAssertTrue(output.timedOut)
  }
}
