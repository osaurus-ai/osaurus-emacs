import OsaurusPluginKit
import OsaurusPluginTestSupport
import XCTest

@testable import Emacs

/// SDK conformance checks: registry manifest rules, the ABI contract of the
/// real entry pointers, and the canonical failure-envelope shape.
final class ConformanceTests: XCTestCase {

  func testManifestConformance() throws {
    try ManifestConformance.assertConformant(emacsManifestJSON)
  }

  func testEntryV2ABIConformance() throws {
    try ABIConformance.assertEntryConformance(
      osaurus_plugin_entry_v2(nil), manifestJSON: emacsManifestJSON)
  }

  func testLegacyEntryABIConformance() throws {
    try ABIConformance.assertEntryConformance(
      osaurus_plugin_entry(), manifestJSON: emacsManifestJSON)
  }

  func testCanonicalFailureShape() throws {
    try assertCanonicalFailure(
      Envelope.failure(.invalidArgs, "Missing or empty required argument: code"),
      kind: .invalidArgs)
  }
}
