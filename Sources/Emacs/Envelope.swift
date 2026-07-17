import Foundation
import OsaurusPluginKit

/// Plugin-specific extension of the SDK failure envelope.
///
/// This plugin's wire contract includes an extra `unavailable` kind
/// (emacsclient not found, or the Emacs server not running) that is not
/// part of the SDK's canonical set. It keeps its wave-1 wire shape and
/// default retryable policy (true — the user can start the server and
/// retry). All canonical kinds render through `Envelope.failure` directly.
extension Envelope {
  static func unavailable(_ message: String, retryable: Bool = true) -> String {
    "{\"ok\":false,\"kind\":\"unavailable\",\"message\":\"\(escape(message))\",\"retryable\":\(retryable)}"
  }
}
