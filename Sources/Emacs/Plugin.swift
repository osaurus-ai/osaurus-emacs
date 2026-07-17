import Foundation

// MARK: - Manifest

// Manifest JSON matching the Osaurus plugin spec. Kept at file scope so it can
// be referenced from the C ABI surface and exercised in tests.
let emacsManifestJSON = """
  {
    "plugin_id": "osaurus.emacs",
    "name": "Emacs",
    "description": "Execute Emacs Lisp code in a running Emacs instance",
    "license": "MIT",
    "authors": ["Dinoki Labs"],
    "min_macos": "13.0",
    "min_osaurus": "0.5.0",
    "capabilities": {
      "tools": [
        {
          "id": "execute_emacs_lisp_code",
          "description": "Execute Emacs Lisp code in a running Emacs instance via emacsclient. Requires Emacs server to be running (M-x server-start).",
          "parameters": {
            "type": "object",
            "properties": {
              "code": {
                "type": "string",
                "description": "The Emacs Lisp code to execute"
              },
              "emacsclient_path": {
                "type": "string",
                "description": "Optional absolute path to the emacsclient binary; it must be an existing executable file named 'emacsclient'. Auto-detected if not provided."
              }
            },
            "required": ["code"]
          },
          "requirements": [],
          "permission_policy": "ask"
        }
      ]
    }
  }
  """

// MARK: - Emacs Tool Implementation
struct ExecuteElispTool {
  let name = "execute_emacs_lisp_code"
  let description = "Execute Emacs Lisp code in a running Emacs instance via emacsclient"
  var timeout: TimeInterval = 30

  struct Args: Decodable {
    let code: String?
    let emacsclient_path: String?
  }

  func run(args: String) -> String {
    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      return Envelope.failure(.invalidArgs, "Invalid arguments: expected a JSON object with a 'code' field")
    }

    guard let code = input.code, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return Envelope.failure(.invalidArgs, "Missing or empty 'code' argument")
    }

    if let userPath = input.emacsclient_path {
      if let problem = Self.validateEmacsclientPath(userPath) {
        return Envelope.failure(.invalidArgs, problem)
      }
    }

    let emacsclientPath = input.emacsclient_path ?? findEmacsclient()

    guard let path = emacsclientPath else {
      return Envelope.failure(
        .unavailable,
        "Could not find emacsclient. Install Emacs and ensure emacsclient is in PATH, or provide 'emacsclient_path'.")
    }

    return executeElisp(code: code, emacsclientPath: path)
  }

  // Policy: a caller-supplied emacsclient_path is only accepted when it is an
  // absolute path to an existing executable regular file whose basename is
  // exactly `emacsclient`. Anything else is rejected as invalid_args so the
  // tool cannot be pointed at arbitrary executables.
  static func validateEmacsclientPath(_ path: String) -> String? {
    guard path.hasPrefix("/") else {
      return "emacsclient_path must be an absolute path"
    }
    guard URL(fileURLWithPath: path).lastPathComponent == "emacsclient" else {
      return "emacsclient_path must point to a binary named 'emacsclient'"
    }
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    guard
      let type = (try? FileManager.default.attributesOfItem(atPath: resolved))?[.type]
        as? FileAttributeType, type == .typeRegular
    else {
      return "emacsclient_path does not exist or is not a regular file"
    }
    guard FileManager.default.isExecutableFile(atPath: resolved) else {
      return "emacsclient_path is not executable"
    }
    return nil
  }

  private func findEmacsclient() -> String? {
    // Common locations for emacsclient
    let commonPaths = [
      "/usr/local/bin/emacsclient",
      "/opt/homebrew/bin/emacsclient",
      "/usr/bin/emacsclient",
      "/Applications/Emacs.app/Contents/MacOS/bin/emacsclient",
    ]

    for path in commonPaths {
      if FileManager.default.fileExists(atPath: path) {
        return path
      }
    }

    // Try to find via which command
    if let output = try? ProcessRunner.run(
      executable: "/usr/bin/which", arguments: ["emacsclient"], timeout: 5),
      !output.timedOut, output.exitStatus == 0
    {
      let path = String(decoding: output.stdout, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !path.isEmpty {
        return path
      }
    }

    return nil
  }

  private func executeElisp(code: String, emacsclientPath: String) -> String {
    let output: ProcessRunner.Output
    do {
      output = try ProcessRunner.run(
        executable: emacsclientPath, arguments: ["--eval", code], timeout: timeout)
    } catch {
      // Launching emacsclient failed (e.g. binary missing or not executable).
      return Envelope.failure(
        .unavailable, "Failed to launch emacsclient: \(error.localizedDescription)")
    }

    if output.timedOut {
      return Envelope.failure(
        .timeout, "emacsclient timed out after \(Int(timeout))s and was terminated")
    }

    let stdout = String(decoding: output.stdout, as: UTF8.self)
    let stderr = String(decoding: output.stderr, as: UTF8.self)

    if output.exitStatus != 0 {
      let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      if Self.isServerUnavailable(stderr: trimmedStderr) {
        let detail = trimmedStderr.isEmpty ? "" : ": \(trimmedStderr)"
        return Envelope.failure(
          .unavailable,
          "Emacs server is not running. Start it with M-x server-start (or add (server-start) to your init file)\(detail)")
      }
      let errorMessage =
        trimmedStderr.isEmpty
        ? "emacsclient exited with code \(output.exitStatus)" : trimmedStderr
      return Envelope.failure(.executionError, errorMessage)
    }

    return jsonResult(stdout.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  // Detects the common emacsclient stderr messages that indicate the Emacs
  // server/daemon is not running (as opposed to a genuine lisp error).
  static func isServerUnavailable(stderr: String) -> Bool {
    let lower = stderr.lowercased()
    let markers = [
      "can't find socket",
      "no socket or alternate editor",
      "connection refused",
      "server is not running",
      "no such file or directory",
    ]
    return markers.contains { lower.contains($0) }
  }

  private func jsonResult(_ result: String) -> String {
    let escaped =
      result
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
    return "{\"result\": \"\(escaped)\"}"
  }
}

// MARK: - C ABI surface

// Opaque context
private typealias osr_plugin_ctx_t = UnsafeMutableRawPointer

// Function pointers
private typealias osr_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void
private typealias osr_init_t = @convention(c) () -> osr_plugin_ctx_t?
private typealias osr_destroy_t = @convention(c) (osr_plugin_ctx_t?) -> Void
private typealias osr_get_manifest_t = @convention(c) (osr_plugin_ctx_t?) -> UnsafePointer<CChar>?
private typealias osr_invoke_t =
  @convention(c) (
    osr_plugin_ctx_t?,
    UnsafePointer<CChar>?,  // type
    UnsafePointer<CChar>?,  // id
    UnsafePointer<CChar>?  // payload
  ) -> UnsafePointer<CChar>?

private struct osr_plugin_api {
  var free_string: osr_free_string_t?
  var `init`: osr_init_t?
  var destroy: osr_destroy_t?
  var get_manifest: osr_get_manifest_t?
  var invoke: osr_invoke_t?
}

// Context state (simple wrapper class to hold state)
private class PluginContext {
  let tool = ExecuteElispTool()
}

// Helper to return C strings
private func makeCString(_ s: String) -> UnsafePointer<CChar>? {
  guard let ptr = strdup(s) else { return nil }
  return UnsafePointer(ptr)
}

// API Implementation
private var api: osr_plugin_api = {
  var api = osr_plugin_api()

  api.free_string = { ptr in
    if let p = ptr { free(UnsafeMutableRawPointer(mutating: p)) }
  }

  api.`init` = {
    let ctx = PluginContext()
    return Unmanaged.passRetained(ctx).toOpaque()
  }

  api.destroy = { ctxPtr in
    guard let ctxPtr = ctxPtr else { return }
    Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
  }

  api.get_manifest = { ctxPtr in
    return makeCString(emacsManifestJSON)
  }

  api.invoke = { ctxPtr, typePtr, idPtr, payloadPtr in
    guard let ctxPtr = ctxPtr,
      let typePtr = typePtr,
      let idPtr = idPtr,
      let payloadPtr = payloadPtr
    else { return nil }

    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let type = String(cString: typePtr)
    let id = String(cString: idPtr)
    let payload = String(cString: payloadPtr)

    if type == "tool" && id == ctx.tool.name {
      let result = ctx.tool.run(args: payload)
      return makeCString(result)
    }

    return makeCString(
      Envelope.failure(.notFound, "Unknown capability: type=\(type) id=\(id)"))
  }

  return api
}()

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
  return UnsafeRawPointer(&api)
}
