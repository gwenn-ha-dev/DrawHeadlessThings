import Foundation
import ModelZoo
import XCTest

@testable import dht_server

/// Structural + completeness tests for the capability map. No engine boundary
/// crossed: these only verify the in-memory data structure agrees with the
/// catalog and that the wire shape round-trips.
final class CapabilityMapTests: XCTestCase {

  // MARK: - Architecture → BehaviorClass coverage

  /// Every `Architecture` case must resolve via the exhaustive switch in
  /// `Architecture.behaviorClass` (compile-time guaranteed); this test just
  /// asserts the runtime non-crash plus the documented set of `nil`
  /// (non-publicly-callable) cases stays in sync with the user-agreed list.
  func testArchitectureBehaviorClassMapping() {
    let nonCallable: Set<Architecture> = [.sdxlRefiner, .wurstchenStageB]
    for arch in Architecture.allCases {
      let cls = arch.behaviorClass
      if nonCallable.contains(arch) {
        XCTAssertNil(
          cls, "\(arch.rawValue) should not have a public BehaviorClass")
      } else {
        XCTAssertNotNil(
          cls,
          "\(arch.rawValue) must resolve to a BehaviorClass (or be added to the nonCallable set)")
      }
    }
  }

  // MARK: - BehaviorClass cells coverage

  /// Every `BehaviorClass` listed in the enum must have at least one cell in
  /// the map. Catches a class added without any operation defined.
  func testEveryBehaviorClassHasAtLeastOneCell() {
    for cls in BehaviorClass.allCases {
      let anyCell = CapabilityMap.cells.contains { key, ops in
        key.behaviorClass == cls && !ops.isEmpty
      }
      XCTAssertTrue(
        anyCell, "BehaviorClass.\(cls.rawValue) has no cells in CapabilityMap")
    }
  }

  /// Every cell must define at least one operation. An empty `[Operation:
  /// ContractTemplate]` is meaningless — guard against accidental empty dict.
  func testNoEmptyOperationSet() {
    for (key, ops) in CapabilityMap.cells {
      XCTAssertFalse(
        ops.isEmpty,
        "Cell (\(key.behaviorClass.rawValue), \(key.modifier.rawValue)) defines no operations")
    }
  }

  // MARK: - Modifier mirror parity

  /// Every modifier case must round-trip via raw String — the mirror's job is
  /// to stay 1:1 with the SDK's `SamplerModifier` raw values.
  func testModifierRoundtripsViaRawValue() {
    for m in Modifier.allCases {
      XCTAssertEqual(
        Modifier(rawValue: m.rawValue), m,
        "Modifier.\(m.rawValue) does not round-trip via rawValue")
    }
    XCTAssertEqual(Modifier.from(rawValue: nil), .none)
    XCTAssertEqual(Modifier.from(rawValue: "unknown_future_modifier"), .none)
  }

  // MARK: - FieldConstraint Codable

  /// FieldConstraint encodes to a discriminated JSON object and round-trips
  /// for every kind. If a new kind is added without updating Codable, this
  /// catches it.
  func testFieldConstraintCodableRoundtrip() throws {
    let cases: [FieldConstraint] = [
      .bool(required: true),
      .int(min: 0, max: 100, multipleOf: 8, required: true),
      .int(),
      .int64(min: 0, max: .max, required: false),
      .float(min: 0, max: 1, exclusiveMin: true, exclusiveMax: false, required: true),
      .float(),
      .string(maxLength: 256, enumValues: ["a", "b"], required: true),
      .string(),
      .base64(required: true),
      .array(itemsRef: "LoRARef", required: false),
      .object(ref: "Extensions", required: false),
    ]
    let enc = JSONEncoder()
    let dec = JSONDecoder()
    for value in cases {
      let data = try enc.encode(value)
      let back = try dec.decode(FieldConstraint.self, from: data)
      XCTAssertEqual(value, back, "round-trip mismatch for \(value)")
    }
  }

  /// Sample serialized form: a width constraint should produce the agreed
  /// wire shape.
  func testFieldConstraintWireShape() throws {
    let width = FieldConstraint.int(min: 64, max: 4096, multipleOf: 64, required: true)
    let data = try JSONEncoder().encode(width)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    XCTAssertEqual(json?["type"] as? String, "int")
    XCTAssertEqual(json?["min"] as? Int, 64)
    XCTAssertEqual(json?["max"] as? Int, 4096)
    XCTAssertEqual(json?["multiple_of"] as? Int, 64)
    XCTAssertEqual(json?["required"] as? Bool, true)
  }

  // MARK: - Contract / SilentDrop / Refused JSON keys

  /// The wire-facing `Contract` must use the snake_case keys agreed in
  /// the plan. Catches a CodingKeys regression.
  func testContractUsesSnakeCaseKeys() throws {
    let c = Contract(
      modelId: "m",
      operation: .txt2img,
      engineVersion: "1.x",
      behaviorClass: .sd1x,
      modifier: "none",
      accepted: ["prompt": .string(required: true)],
      silentDrops: [SilentDrop(field: "x", reason: "y")],
      refused: [Refused(field: "z", errorCode: "E")],
      notes: ["n"],
      example: nil)
    let data = try JSONEncoder().encode(c)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    XCTAssertNotNil(json?["model_id"])
    XCTAssertNotNil(json?["engine_version"])
    XCTAssertNotNil(json?["behavior_class"])
    XCTAssertNotNil(json?["silent_drops"])
    XCTAssertNotNil(json?["operation"])
    XCTAssertNotNil(json?["modifier"])
    XCTAssertNotNil(json?["accepted"])
    XCTAssertNotNil(json?["refused"])
    XCTAssertNotNil(json?["notes"])

    let drops = json?["silent_drops"] as? [[String: Any]]
    XCTAssertEqual(drops?.first?["field"] as? String, "x")
    XCTAssertEqual(drops?.first?["reason"] as? String, "y")

    let refused = json?["refused"] as? [[String: Any]]
    XCTAssertEqual(refused?.first?["error_code"] as? String, "E")
  }

  // MARK: - example field (R6)

  /// Every Operation must have a hand-written example. Catches a regression
  /// where a new Operation is added to the enum without the matching entry
  /// in `CapabilityMap.examplesByOperation`.
  func testEveryOperationHasAnExample() {
    for op in Operation.allCases {
      XCTAssertNotNil(
        CapabilityMap.example(for: op),
        "missing example for Operation.\(op.rawValue)")
    }
  }

  /// Each example points at the semantic-API endpoint expected for that
  /// Operation. Catches a copy-paste mistake (e.g. an inpaint example
  /// pointing at `/v1/compose`).
  func testExampleEndpointMatchesOperationSemantics() {
    let expected: [dht_server.Operation: String] = [
      .txt2img: "/v1/compose",
      .img2img: "/v1/compose",
      .txt2vid: "/v1/compose",
      .img2vid: "/v1/compose",
      .edit: "/v1/edit",
      .inpaint: "/v1/edit",
      .restore: "/v1/restore",
    ]
    for (op, endpoint) in expected {
      XCTAssertEqual(
        CapabilityMap.example(for: op)?.endpoint, endpoint,
        "wrong endpoint on example for Operation.\(op.rawValue)")
    }
  }

  /// The example's body must round-trip as the verb's request type. This
  /// is the contract guarantee — agents can copy the example, substitute
  /// the placeholders, and the resulting JSON decodes cleanly.
  func testComposeExampleBodyDecodesAsComposeRequest() throws {
    let example = try XCTUnwrap(CapabilityMap.example(for: .txt2img))
    let bodyData = try JSONEncoder().encode(example.body)
    let req = try JSONDecoder().decode(ComposeRequest.self, from: bodyData)
    XCTAssertFalse(req.model.isEmpty)
    XCTAssertFalse(req.prompt.isEmpty)
    XCTAssertNotNil(req.params)
  }

  func testEditExampleBodyDecodesAsEditRequest() throws {
    let example = try XCTUnwrap(CapabilityMap.example(for: .edit))
    let bodyData = try JSONEncoder().encode(example.body)
    let req = try JSONDecoder().decode(EditRequest.self, from: bodyData)
    XCTAssertFalse(req.model.isEmpty)
    XCTAssertFalse(req.instruction.isEmpty)
  }

  func testRestoreExampleBodyDecodesAsRestoreRequest() throws {
    let example = try XCTUnwrap(CapabilityMap.example(for: .restore))
    let bodyData = try JSONEncoder().encode(example.body)
    let req = try JSONDecoder().decode(RestoreRequest.self, from: bodyData)
    XCTAssertFalse(req.model.isEmpty)
  }

  /// Contract serialisation includes the example when one exists for the
  /// op. Wire shape: `{ endpoint: "...", body: {...} }`.
  func testContractWireCarriesExample() throws {
    let c = Contract(
      modelId: "m", operation: .txt2img, engineVersion: "1.x",
      behaviorClass: .sd1x, modifier: "none",
      accepted: [:], silentDrops: [], refused: [], notes: [],
      example: CapabilityMap.example(for: .txt2img))
    let data = try JSONEncoder().encode(c)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let example = try XCTUnwrap(json?["example"] as? [String: Any])
    XCTAssertEqual(example["endpoint"] as? String, "/v1/compose")
    XCTAssertNotNil(example["body"] as? [String: Any])
  }

  // MARK: - assertSupported

  /// `assertSupported` on an unknown model throws `baseModelNotInstalled`,
  /// which the route layer maps to a 404 + `MODEL_NOT_INSTALLED`.
  func testAssertSupportedUnknownModelThrowsNotInstalled() {
    do {
      try CapabilityMap.assertSupported(
        modelId: "definitely-does-not-exist", operation: .txt2img)
      XCTFail("expected throw")
    } catch let e as EngineError {
      switch e {
      case .baseModelNotInstalled: break
      default: XCTFail("expected baseModelNotInstalled, got \(e)")
      }
    } catch {
      XCTFail("expected EngineError, got \(error)")
    }
  }

  /// On a catalog model whose `(class, modifier)` cell supports the requested
  /// operation, assertSupported returns successfully. We pick the model
  /// dynamically to stay robust against catalog changes.
  func testAssertSupportedSupportedOpReturnsCleanly() throws {
    guard let (spec, op) = ModelZoo.availableSpecifications.lazy
      .compactMap({ spec -> (ModelZoo.Specification, dht_server.Operation)? in
        guard let arch = Architecture(rawValue: spec.version.rawValue),
          let cls = arch.behaviorClass
        else { return nil }
        let modifier = Modifier.from(rawValue: spec.modifier?.rawValue)
        guard let firstOp = CapabilityMap.contracts(
          behaviorClass: cls, modifier: modifier).keys.first
        else { return nil }
        return (spec, firstOp)
      }).first
    else {
      throw XCTSkip("no catalog spec maps to a non-empty cell")
    }
    XCTAssertNoThrow(
      try CapabilityMap.assertSupported(
        modelId: spec.file, operation: op))
  }

  /// Catalog catalog drift: this picks a model and asks for an op that's
  /// NOT in its cell; assertSupported must throw one of the specific
  /// EngineError cases (domainMismatch / notAnInstructionEditModel /
  /// editingModelRequiresEditEndpoint / operationNotSupportedForModel).
  func testAssertSupportedUnsupportedOpThrowsTyped() throws {
    guard let (spec, unsupportedOp) = ModelZoo.availableSpecifications.lazy
      .compactMap({ spec -> (ModelZoo.Specification, dht_server.Operation)? in
        guard let arch = Architecture(rawValue: spec.version.rawValue),
          let cls = arch.behaviorClass
        else { return nil }
        let modifier = Modifier.from(rawValue: spec.modifier?.rawValue)
        let supported = Set(CapabilityMap.contracts(
          behaviorClass: cls, modifier: modifier).keys)
        guard let missing = dht_server.Operation.allCases.first(where: {
          !supported.contains($0)
        }) else { return nil }
        return (spec, missing)
      }).first
    else {
      throw XCTSkip("every catalog cell already supports every op")
    }
    do {
      try CapabilityMap.assertSupported(
        modelId: spec.file, operation: unsupportedOp)
      XCTFail("expected throw for unsupported op")
    } catch let e as EngineError {
      switch e {
      case .domainMismatch,
           .notAnInstructionEditModel,
           .editingModelRequiresEditEndpoint,
           .operationNotSupportedForModel:
        break  // expected one of the four
      default:
        XCTFail("expected one of the typed-op errors, got \(e)")
      }
    } catch {
      XCTFail("expected EngineError, got \(error)")
    }
  }

  // MARK: - Catalog coverage

  /// Every spec available in the catalog (builtins + locally-installed
  /// customs) must resolve to either:
  ///   - a `nil` BehaviorClass (deliberately non-callable arch), or
  ///   - a `(class, modifier)` cell with at least one operation.
  ///
  /// This is the v0 guardrail against catalog drift: the test fails if a new
  /// `(class, modifier)` pair appears in the catalog without a cell.
  func testCatalogSpecsAllResolveToKnownCells() {
    var orphans: [(model: String, arch: String, modifier: String)] = []
    for spec in ModelZoo.availableSpecifications {
      guard let arch = Architecture(rawValue: spec.version.rawValue) else {
        XCTFail(
          "Spec '\(spec.file)' has unknown architecture '\(spec.version.rawValue)' — Architecture enum is out of sync with the SDK")
        continue
      }
      guard let cls = arch.behaviorClass else { continue }  // non-callable arch is fine
      let modifier = Modifier.from(rawValue: spec.modifier?.rawValue)
      let key = CapabilityMap.Key(behaviorClass: cls, modifier: modifier)
      if CapabilityMap.cells[key]?.isEmpty ?? true {
        orphans.append((spec.file, arch.rawValue, modifier.rawValue))
      }
    }
    if !orphans.isEmpty {
      XCTFail(
        "Catalog specs resolve to (class, modifier) cells with no operations:\n"
          + orphans.map { "  - \($0.model) — \($0.arch) × \($0.modifier)" }.joined(separator: "\n"))
    }
  }
}
