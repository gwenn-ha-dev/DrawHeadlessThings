import Foundation
import HTTPTypes
import ModelZoo
import XCTest

@testable import dht_server

/// Pure-helper tests — no engine, no SDK Configuration. Covers logic that
/// runs before request validation reaches the engine boundary, plus the
/// EngineError → TypedError mapping that translates engine failures to
/// HTTP error codes.
final class HelperTests: XCTestCase {

  // MARK: GenerationParams.validate

  private func params(
    width: Int = 512, height: Int = 512, steps: Int = 8,
    cfgScale: Float? = nil, batchSize: Int? = nil, batchCount: Int? = nil,
    controlnets: [ControlNetRef]? = nil,
    upscaler: UpscalerParams? = nil
  ) -> GenerationParams {
    GenerationParams(
      prompt: "x", negativePrompt: nil, baseModelId: "m",
      width: width, height: height, steps: steps,
      cfgScale: cfgScale, seed: nil, seedMode: nil, sampler: nil,
      clipSkip: nil, outputFormat: nil,
      batchSize: batchSize, batchCount: batchCount, runId: nil,
      loras: nil, controlnets: controlnets,
      referenceImage: nil, depthImage: nil,
      hiresFix: nil, refiner: nil, upscaler: upscaler,
      tiling: nil, flowMatch: nil,
      sdxlConditioning: nil, textEncoders: nil, cascade: nil,
      imagePrior: nil, sharpness: nil, extensions: nil)
  }

  func testValidateAcceptsHappyShape() throws {
    XCTAssertNoThrow(try params().validate())
  }

  func testValidateRejectsNonMultipleOf64Width() {
    XCTAssertThrowsError(try params(width: 500).validate()) { error in
      XCTAssertEqual((error as? ValidationError)?.detail.contains("width"), true)
    }
  }

  func testValidateRejectsStepsAboveMax() {
    XCTAssertThrowsError(try params(steps: 999).validate())
  }

  func testValidateRejectsNonFiniteCfg() {
    XCTAssertThrowsError(try params(cfgScale: .infinity).validate())
  }

  func testValidateRejectsBatchSizeBelowOne() {
    XCTAssertThrowsError(try params(batchSize: 0).validate())
  }

  func testValidateAcceptsControlNetInRange() {
    let cn = ControlNetRef(
      modelId: "any", weight: 0.5, guidanceStart: 0.1, guidanceEnd: 0.8,
      controlMode: nil, inputTypeOverride: nil, noPrompt: nil,
      globalAveragePooling: nil, downSamplingRate: nil, targetBlocks: nil)
    XCTAssertNoThrow(try params(controlnets: [cn]).validate())
  }

  func testValidateRejectsControlNetEmptyModelId() {
    let cn = ControlNetRef(
      modelId: "", weight: nil, guidanceStart: nil, guidanceEnd: nil,
      controlMode: nil, inputTypeOverride: nil, noPrompt: nil,
      globalAveragePooling: nil, downSamplingRate: nil, targetBlocks: nil)
    XCTAssertThrowsError(try params(controlnets: [cn]).validate())
  }

  func testValidateRejectsControlNetInvertedGuidanceRange() {
    let cn = ControlNetRef(
      modelId: "any", weight: nil, guidanceStart: 0.8, guidanceEnd: 0.2,
      controlMode: nil, inputTypeOverride: nil, noPrompt: nil,
      globalAveragePooling: nil, downSamplingRate: nil, targetBlocks: nil)
    XCTAssertThrowsError(try params(controlnets: [cn]).validate())
  }

  // MARK: GenerationParams.effectiveSeed

  func testValidateRejectsUpscalerEmptyModelId() {
    let u = UpscalerParams(modelId: "", scaleFactor: 4)
    XCTAssertThrowsError(try params(upscaler: u).validate())
  }

  func testValidateRejectsUpscalerScaleOutOfRange() {
    let u = UpscalerParams(modelId: "x", scaleFactor: 16)
    XCTAssertThrowsError(try params(upscaler: u).validate()) { error in
      XCTAssertEqual((error as? ValidationError)?.detail.contains("scale_factor"), true)
    }
  }

  func testValidateAcceptsUpscalerInRange() {
    let u = UpscalerParams(modelId: "real-esrgan-x4", scaleFactor: 4)
    XCTAssertNoThrow(try params(upscaler: u).validate())
  }

  // MARK: EditingMode mapping

  func testEditingModeNilForVanillaModel() {
    XCTAssertNil(EditingMode(modifier: nil))
    XCTAssertNil(EditingMode(modifier: "none"))
  }

  func testEditingModeRecognizesQwenEditVariants() {
    XCTAssertEqual(EditingMode(modifier: "qwenimage_edit_2511"), .instructionEdit)
    XCTAssertEqual(EditingMode(modifier: "qwenimage_edit_plus"), .instructionEdit)
  }

  func testEditingModeRecognizesFluxKontext() {
    XCTAssertEqual(EditingMode(modifier: "kontext"), .instructionEdit)
    XCTAssertEqual(EditingMode(modifier: "kontext_kv"), .instructionEdit)
  }

  func testEditingModeRecognizesInpainting() {
    XCTAssertEqual(EditingMode(modifier: "inpainting"), .inpainting)
  }

  func testEditingModeRecognizesHintConditioned() {
    XCTAssertEqual(EditingMode(modifier: "depth"), .hintConditioned)
    XCTAssertEqual(EditingMode(modifier: "canny"), .hintConditioned)
  }

  func testEditingModeRecognizesLayered() {
    XCTAssertEqual(EditingMode(modifier: "qwenimage_layered"), .layeredEdit)
  }

  func testEditingModeFallsBackToOther() {
    XCTAssertEqual(EditingMode(modifier: "editing"), .other)
    XCTAssertEqual(EditingMode(modifier: "double"), .other)
    XCTAssertEqual(EditingMode(modifier: "totally_made_up"), .other)
  }

  // MARK: VideoMotionParams.validate

  func testVideoMotionAcceptsInRange() throws {
    let m = VideoMotionParams(
      motionScale: 127, guidingFrameNoise: 0.5, startFrameGuidance: 1.0)
    XCTAssertNoThrow(try m.validate())
  }

  func testVideoMotionRejectsNegativeNoise() {
    let m = VideoMotionParams(
      motionScale: nil, guidingFrameNoise: -0.1, startFrameGuidance: nil)
    XCTAssertThrowsError(try m.validate())
  }

  func testVideoMotionRejectsNonFiniteGuidance() {
    let m = VideoMotionParams(
      motionScale: nil, guidingFrameNoise: nil, startFrameGuidance: .nan)
    XCTAssertThrowsError(try m.validate())
  }

  func testEffectiveSeedReturnsRequestedWhenPositive() {
    var p = params()
    p = GenerationParams(
      prompt: p.prompt, negativePrompt: p.negativePrompt,
      baseModelId: p.baseModelId, width: p.width, height: p.height,
      steps: p.steps, cfgScale: nil, seed: 12345, seedMode: nil,
      sampler: nil, clipSkip: nil, outputFormat: nil, batchSize: nil,
      batchCount: nil, runId: nil, loras: nil, controlnets: nil,
      referenceImage: nil, depthImage: nil, hiresFix: nil, refiner: nil,
      upscaler: nil, tiling: nil, flowMatch: nil, sdxlConditioning: nil,
      textEncoders: nil, cascade: nil, imagePrior: nil, sharpness: nil,
      extensions: nil)
    XCTAssertEqual(p.effectiveSeed(), UInt32(12345))
  }

  func testEffectiveSeedRandomizesNegativeOne() {
    let p = GenerationParams(
      prompt: "x", negativePrompt: nil, baseModelId: "m",
      width: 64, height: 64, steps: 1,
      cfgScale: nil, seed: -1, seedMode: nil, sampler: nil,
      clipSkip: nil, outputFormat: nil, batchSize: nil, batchCount: nil,
      runId: nil, loras: nil, controlnets: nil,
      referenceImage: nil, depthImage: nil,
      hiresFix: nil, refiner: nil, upscaler: nil, tiling: nil,
      flowMatch: nil, sdxlConditioning: nil, textEncoders: nil,
      cascade: nil, imagePrior: nil, sharpness: nil, extensions: nil)
    // Highly unlikely two consecutive draws collide (≈ 2^-32) — repeat
    // a couple times for safety, the test is still effectively flake-free.
    let draws = (0..<3).map { _ in p.effectiveSeed() }
    XCTAssertGreaterThan(Set(draws).count, 1)
  }

  // MARK: TypedError.from(engineError:)

  func testTypedErrorMapsBaseModelNotInstalledTo400() {
    let typed = TypedError.from(engineError: .baseModelNotInstalled(id: "x"))
    XCTAssertEqual(typed.status, .badRequest)
    XCTAssertEqual(typed.errorCode, "MODEL_NOT_INSTALLED")
    XCTAssertEqual(typed.detail?.contains("'x'"), true)
  }

  func testTypedErrorMapsControlnetNoPublicHintPathTo400() {
    let typed = TypedError.from(
      engineError: .controlnetNoPublicHintPath(
        id: "cn", modifier: "pose", index: 2))
    XCTAssertEqual(typed.status, .badRequest)
    XCTAssertEqual(typed.errorCode, "CONTROL_HAS_NO_PUBLIC_HINT_PATH")
    XCTAssertEqual(typed.detail?.contains("controlnets[2]"), true)
    XCTAssertEqual(typed.detail?.contains("pose"), true)
  }

  func testTypedErrorMapsDomainMismatchTo400() {
    let typed = TypedError.from(
      engineError: .domainMismatch(
        baseModelId: "wan", baseDomain: "video", requestedDomain: "image"))
    XCTAssertEqual(typed.status, .badRequest)
    XCTAssertEqual(typed.errorCode, "BASE_MODEL_DOMAIN_MISMATCH")
  }

  func testTypedErrorMapsInvalidImageDataTo400() {
    let typed = TypedError.from(engineError: .invalidImageData)
    XCTAssertEqual(typed.status, .badRequest)
    XCTAssertEqual(typed.errorCode, "INVALID_IMAGE_DATA")
  }

  // MARK: ModelSizeResolver

  func testSizeResolverOfflineModeSkipsCDN() async {
    // Offline mode + a file that's definitely not on disk → resolver
    // must not hang on a CDN HEAD (timeout would be 2s) and must
    // return nil quickly.
    let resolver = ModelSizeResolver(
      timeout: 0.1, offlineMode: true)
    let start = Date()
    let spec = ModelZoo.specificationForModel("z_image_turbo_1.0_q8p.ckpt")
    // No spec is fine — the resolver will fall back to resolving the
    // headline file directly. We just want to assert offline returns
    // promptly for absent files.
    if let spec {
      let size = await resolver.installSize(forBaseModel: spec)
      // If the test happens to run with the model on disk, we'll get
      // a real number; either way the call returns fast.
      _ = size
    }
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertLessThan(elapsed, 1.0, "offline resolver must not hang on network")
  }

  // MARK: AssetMutationError → TypedError

  func testTypedErrorMapsLargeDownloadTo412() {
    let typed = TypedError.from(
      mutationError: .largeDownloadNotConfirmed(
        bytes: 30_461_181_952, thresholdBytes: 5 * 1024 * 1024 * 1024))
    XCTAssertEqual(typed.status.code, 412)
    XCTAssertEqual(typed.errorCode, "LARGE_MODEL_DOWNLOAD")
    XCTAssertTrue(typed.title.contains("28.37 GB"))
    XCTAssertTrue(typed.detail?.contains("5.00 GB") ?? false)
    XCTAssertTrue(typed.detail?.contains("confirm_large_download") ?? false)
  }

  func testInstallRequestDecodesConfirmFlag() throws {
    let json = #"""
      {"source":{"type":"catalog","model":"x"},"confirm_large_download":true}
      """#
    let data = json.data(using: .utf8)!
    let req = try JSONDecoder().decode(InstallAssetRequest.self, from: data)
    XCTAssertEqual(req.confirmLargeDownload, true)
  }

  func testInstallRequestDecodesWithoutConfirmFlag() throws {
    let json = #"""
      {"source":{"type":"catalog","model":"x"}}
      """#
    let data = json.data(using: .utf8)!
    let req = try JSONDecoder().decode(InstallAssetRequest.self, from: data)
    XCTAssertNil(req.confirmLargeDownload)
  }

  func testTypedErrorMapsUpscalerNotInstalledTo400() {
    let typed = TypedError.from(engineError: .upscalerNotInstalled(id: "lanczos"))
    XCTAssertEqual(typed.status, .badRequest)
    XCTAssertEqual(typed.errorCode, "UPSCALER_NOT_INSTALLED")
    XCTAssertEqual(typed.detail?.contains("'lanczos'"), true)
  }

  func testTypedErrorMapsNoImageProducedTo500() {
    let typed = TypedError.from(engineError: .noImageProduced)
    XCTAssertEqual(typed.status, .internalServerError)
    XCTAssertEqual(typed.errorCode, "ENGINE_INTERNAL_ERROR")
  }
}
