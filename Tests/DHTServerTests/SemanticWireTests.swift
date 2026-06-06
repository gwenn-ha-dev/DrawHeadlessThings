import Foundation
import XCTest

@testable import dht_server

/// Decoding / round-trip tests for the semantic-API wire types. Covers the
/// polymorphic `FromSource`
/// (image / sub-recipe / `$ref` / nil), the `Recipe` discriminator, and the
/// pipeline-step shape. No engine touched — JSON in, JSON out.
final class SemanticWireTests: XCTestCase {

  private let decoder = JSONDecoder()
  private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return e
  }()

  // MARK: FromSource decoding

  func testFromSourceImageDecodes() throws {
    let json = #"{"image":"AAAA"}"#.data(using: .utf8)!
    let from = try decoder.decode(FromSource.self, from: json)
    guard case .image(let bytes) = from else {
      return XCTFail("expected .image, got \(from)")
    }
    XCTAssertEqual(bytes, "AAAA")
  }

  func testFromSourceRefDecodes() throws {
    let json = #""$base""#.data(using: .utf8)!
    let from = try decoder.decode(FromSource.self, from: json)
    guard case .ref(let name) = from else {
      return XCTFail("expected .ref, got \(from)")
    }
    XCTAssertEqual(name, "base")
  }

  func testFromSourceBareStringWithoutDollarFails() {
    let json = #""base""#.data(using: .utf8)!
    XCTAssertThrowsError(try decoder.decode(FromSource.self, from: json))
  }

  func testFromSourceLoneDollarFails() {
    let json = #""$""#.data(using: .utf8)!
    XCTAssertThrowsError(try decoder.decode(FromSource.self, from: json))
  }

  func testFromSourceObjectWithoutImageOrViaFails() {
    let json = #"{"other":"x"}"#.data(using: .utf8)!
    XCTAssertThrowsError(try decoder.decode(FromSource.self, from: json))
  }

  func testFromSourceRecipeDecodes() throws {
    let json = #"""
    {"via":"compose","model":"sdxl","prompt":"a cat"}
    """#.data(using: .utf8)!
    let from = try decoder.decode(FromSource.self, from: json)
    guard case .recipe(.compose(let req)) = from else {
      return XCTFail("expected .recipe(.compose), got \(from)")
    }
    XCTAssertEqual(req.model, "sdxl")
    XCTAssertEqual(req.prompt, "a cat")
    XCTAssertNil(req.from)
  }

  // MARK: FromSource round-trips

  func testFromSourceImageRoundTrip() throws {
    let original = FromSource.image("ZZ==")
    let json = try encoder.encode(original)
    XCTAssertEqual(String(decoding: json, as: UTF8.self), #"{"image":"ZZ=="}"#)
    let decoded = try decoder.decode(FromSource.self, from: json)
    guard case .image(let bytes) = decoded, bytes == "ZZ==" else {
      return XCTFail("round-trip mismatch: \(decoded)")
    }
  }

  func testFromSourceRefRoundTrip() throws {
    let original = FromSource.ref("step1")
    let json = try encoder.encode(original)
    XCTAssertEqual(String(decoding: json, as: UTF8.self), #""$step1""#)
    let decoded = try decoder.decode(FromSource.self, from: json)
    guard case .ref(let name) = decoded, name == "step1" else {
      return XCTFail("round-trip mismatch: \(decoded)")
    }
  }

  // MARK: Verb bodies

  func testComposeMinimalDecodes() throws {
    let json = #"""
    {"model":"sdxl","prompt":"a fox"}
    """#.data(using: .utf8)!
    let req = try decoder.decode(ComposeRequest.self, from: json)
    XCTAssertEqual(req.model, "sdxl")
    XCTAssertEqual(req.prompt, "a fox")
    XCTAssertNil(req.from)
    XCTAssertNil(req.guides)
    XCTAssertNil(req.params)
    XCTAssertNil(req.runId)
  }

  func testEditWithMaskDecodes() throws {
    let json = #"""
    {
      "model": "flux_kontext_dev",
      "from": {"image":"AAA="},
      "instruction": "remove the text",
      "mask": "BBB=",
      "references": [{"image":{"image":"CCC="},"role":"style"}]
    }
    """#.data(using: .utf8)!
    let req = try decoder.decode(EditRequest.self, from: json)
    XCTAssertEqual(req.model, "flux_kontext_dev")
    XCTAssertEqual(req.instruction, "remove the text")
    XCTAssertEqual(req.mask, "BBB=")
    XCTAssertEqual(req.references?.count, 1)
    XCTAssertEqual(req.references?.first?.role, .style)
    guard case .image("AAA=") = req.from else {
      return XCTFail("expected from.image=AAA=, got \(req.from)")
    }
  }

  func testRestoreDecodes() throws {
    let json = #"""
    {"model":"esrgan_4x","from":{"image":"XX=="}}
    """#.data(using: .utf8)!
    let req = try decoder.decode(RestoreRequest.self, from: json)
    XCTAssertEqual(req.model, "esrgan_4x")
    guard case .image("XX==") = req.from else {
      return XCTFail("expected from.image=XX==, got \(req.from)")
    }
  }

  // MARK: Nested recipe (compose whose `from` is an edit sub-recipe)

  func testNestedRecipeTwoLevelsDecode() throws {
    let json = #"""
    {
      "model": "sdxl_refiner",
      "prompt": "stylise the result",
      "from": {
        "via": "edit",
        "model": "flux_kontext_dev",
        "from": {"image":"INPUT"},
        "instruction": "remove the watermark"
      }
    }
    """#.data(using: .utf8)!
    let req = try decoder.decode(ComposeRequest.self, from: json)
    XCTAssertEqual(req.model, "sdxl_refiner")
    guard case .recipe(.edit(let inner)) = req.from else {
      return XCTFail("expected from.recipe(.edit), got \(String(describing: req.from))")
    }
    XCTAssertEqual(inner.model, "flux_kontext_dev")
    XCTAssertEqual(inner.instruction, "remove the watermark")
    guard case .image("INPUT") = inner.from else {
      return XCTFail("expected inner.from.image, got \(inner.from)")
    }
  }

  // MARK: Pipeline

  func testPipelineTwoStepsDecodes() throws {
    let json = #"""
    {
      "steps": [
        {"as":"base","via":"compose","model":"sdxl","prompt":"a portrait of a cat"},
        {"as":"edited","via":"edit","from":"$base","model":"flux_kontext_dev",
         "instruction":"make it black"}
      ],
      "return": ["edited"]
    }
    """#.data(using: .utf8)!
    let pipe = try decoder.decode(PipelineRequest.self, from: json)
    XCTAssertEqual(pipe.steps.count, 2)
    XCTAssertEqual(pipe.return, ["edited"])

    XCTAssertEqual(pipe.steps[0].as, "base")
    guard case .compose(let baseReq) = pipe.steps[0].recipe else {
      return XCTFail("step 0 expected compose")
    }
    XCTAssertEqual(baseReq.prompt, "a portrait of a cat")

    XCTAssertEqual(pipe.steps[1].as, "edited")
    guard case .edit(let editReq) = pipe.steps[1].recipe else {
      return XCTFail("step 1 expected edit")
    }
    guard case .ref("base") = editReq.from else {
      return XCTFail("step 1 expected from.ref(base), got \(editReq.from)")
    }
  }

  // MARK: GuideRef polymorphism (decision D2 — guides[].image accepts FromSource)

  func testGuideImageAcceptsRecipe() throws {
    let json = #"""
    {
      "kind": "depth",
      "image": {"via":"compose","model":"depthmaker","prompt":"depth of a room"},
      "weight": 0.7
    }
    """#.data(using: .utf8)!
    let guide = try decoder.decode(GuideRef.self, from: json)
    XCTAssertEqual(guide.kind, .depth)
    XCTAssertEqual(guide.weight, 0.7)
    guard case .recipe(.compose) = guide.image else {
      return XCTFail("expected guide.image as recipe.compose, got \(guide.image)")
    }
  }

  // MARK: EngineParams (R2 — params sub-object on every verb body)

  func testEngineParamsMinimalDecodes() throws {
    let json = #"""
    {"width":1024,"height":1024,"steps":30}
    """#.data(using: .utf8)!
    let p = try decoder.decode(EngineParams.self, from: json)
    XCTAssertEqual(p.width, 1024)
    XCTAssertEqual(p.height, 1024)
    XCTAssertEqual(p.steps, 30)
    XCTAssertNil(p.cfgScale)
    XCTAssertNil(p.denoisingStrength)
    XCTAssertNil(p.video)
  }

  func testEngineParamsRejectsBodyRootFields() {
    // `prompt` / `base_model_id` / `negative_prompt` / `run_id` belong at the
    // root of compose/edit/restore — they must NOT decode into EngineParams.
    // We assert by checking those keys are silently ignored (decoder ignores
    // unknown keys), and the required width/height/steps still drive decode.
    let json = #"""
    {
      "prompt": "ignored",
      "base_model_id": "ignored",
      "negative_prompt": "ignored",
      "run_id": "ignored",
      "width": 512, "height": 512, "steps": 8
    }
    """#.data(using: .utf8)!
    let p = try? decoder.decode(EngineParams.self, from: json)
    XCTAssertNotNil(p)
    XCTAssertEqual(p?.width, 512)
  }

  func testEngineParamsDecodesVideoSubObject() throws {
    let json = #"""
    {
      "width": 512, "height": 512, "steps": 24,
      "video": {"num_frames": 16, "fps": 12, "video_format": "mp4_hevc"}
    }
    """#.data(using: .utf8)!
    let p = try decoder.decode(EngineParams.self, from: json)
    XCTAssertEqual(p.video?.numFrames, 16)
    XCTAssertEqual(p.video?.effectiveFps, 12)
    XCTAssertEqual(p.video?.effectiveFormat, .mp4Hevc)
  }

  func testEngineParamsDecodesR2Strengths() throws {
    let json = #"""
    {
      "width": 512, "height": 512, "steps": 8,
      "denoising_strength": 0.55,
      "conditioning_strength": 0.9
    }
    """#.data(using: .utf8)!
    let p = try decoder.decode(EngineParams.self, from: json)
    XCTAssertEqual(p.denoisingStrength, 0.55)
    XCTAssertEqual(p.conditioningStrength, 0.9)
  }

  func testEngineParamsMaterializeOverlaysRootFields() throws {
    let json = #"""
    {
      "width": 768, "height": 768, "steps": 25,
      "cfg_scale": 6.5,
      "loras": [{"lora_id":"my_lora","weight":0.8}],
      "denoising_strength": 0.3
    }
    """#.data(using: .utf8)!
    let p = try decoder.decode(EngineParams.self, from: json)
    let g = p.materialize(
      model: "sdxl", prompt: "a fox", negativePrompt: "blurry", runId: "run-42")
    XCTAssertEqual(g.baseModelId, "sdxl")
    XCTAssertEqual(g.prompt, "a fox")
    XCTAssertEqual(g.negativePrompt, "blurry")
    XCTAssertEqual(g.runId, "run-42")
    XCTAssertEqual(g.width, 768)
    XCTAssertEqual(g.height, 768)
    XCTAssertEqual(g.steps, 25)
    XCTAssertEqual(g.cfgScale, 6.5)
    XCTAssertEqual(g.loras?.count, 1)
    XCTAssertEqual(g.loras?.first?.loraId, "my_lora")
    // R2-only fields (denoising_strength, conditioning_strength, video) don't
    // exist on GenerationParams — they're consumed by the adapter, not folded
    // into the materialized struct.
  }
}
