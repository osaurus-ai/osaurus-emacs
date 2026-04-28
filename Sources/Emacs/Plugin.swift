import Foundation

// MARK: - Emacs Tool Implementation
private struct ExecuteElispTool {
  let name = "execute_emacs_lisp_code"
  let description = "Execute Emacs Lisp code in a running Emacs instance via emacsclient"
  private let timeoutSeconds: TimeInterval = 10
  private let maxOutputBytes = 65_536

  struct Args: Decodable {
    let code: String
    let emacsclient_path: String?
  }

  func run(args: String) -> String {
    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      return jsonError("Invalid arguments: expected 'code' field")
    }

    let emacsclientPath = input.emacsclient_path ?? findEmacsclient()

    guard let path = emacsclientPath else {
      return jsonError(
        "Could not find emacsclient. Please provide emacsclient_path or ensure it's in PATH.")
    }

    return executeElisp(code: input.code, emacsclientPath: path)
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
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    process.arguments = ["emacsclient"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
      process.waitUntilExit()

      if process.terminationStatus == 0 {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(
          in: .whitespacesAndNewlines),
          !path.isEmpty
        {
          return path
        }
      }
    } catch {
      // Ignore errors
    }

    return nil
  }

  private func executeElisp(code: String, emacsclientPath: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: emacsclientPath)
    process.arguments = ["--eval", code]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
      let group = DispatchGroup()
      group.enter()
      process.terminationHandler = { _ in group.leave() }
      try process.run()

      if group.wait(timeout: .now() + timeoutSeconds) == .timedOut {
        process.terminate()
        _ = group.wait(timeout: .now() + 1)
        return jsonError("emacsclient timed out after \(Int(timeoutSeconds)) seconds")
      }

      let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
      let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

      let stdout = boundedString(stdoutData)
      let stderr = boundedString(stderrData)

      if process.terminationStatus != 0 {
        let errorMessage =
          stderr.isEmpty ? "emacsclient exited with code \(process.terminationStatus)" : stderr
        return jsonError(errorMessage.trimmingCharacters(in: .whitespacesAndNewlines))
      }

      return jsonResult(stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    } catch {
      return jsonError("Failed to execute emacsclient: \(error.localizedDescription)")
    }
  }

  private func boundedString(_ data: Data) -> String {
    guard data.count > maxOutputBytes else {
      return String(data: data, encoding: .utf8) ?? ""
    }
    let prefix = data.prefix(maxOutputBytes)
    let value = String(data: prefix, encoding: .utf8) ?? ""
    return value + "\n[truncated after \(maxOutputBytes) bytes]"
  }

  private func jsonError(_ message: String) -> String {
    let escaped =
      message
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
    return "{\"error\": \"\(escaped)\"}"
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
    // Manifest JSON matching new spec
    let manifest = """
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
                    "description": "Optional path to emacsclient binary. Auto-detected if not provided."
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
    return makeCString(manifest)
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

    return makeCString("{\"error\": \"Unknown capability\"}")
  }

  return api
}()

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
  return UnsafeRawPointer(&api)
}
