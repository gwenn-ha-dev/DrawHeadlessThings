/// Hand-written minimal request bodies — one per `Operation`. Injected into
/// `Contract.example` by `CapabilityMap.response(forModelId:)`.
///
/// Each example points at the right semantic-API endpoint (`/v1/compose` for
/// txt2img / img2img / txt2vid / img2vid; `/v1/edit` for edit / inpaint;
/// `/v1/restore` for restore). Model ids are placeholders that match the
/// most common cell — agents substitute them for the actual installed
/// `model_id` driving the contract they're looking at.

extension CapabilityMap {
  /// Returns the canonical example for an Operation, or `nil` if none has
  /// been authored yet. One example per Operation (NOT per cell), per plan.
  static func example(for operation: Operation) -> ContractExample? {
    examplesByOperation[operation]
  }

  static let examplesByOperation: [Operation: ContractExample] = [
    .txt2img: ContractExample(
      endpoint: "/v1/compose",
      body: .object([
        "model": .string("<installed image base_model id>"),
        "prompt": .string("a serene mountain lake at sunrise, photorealistic"),
        "params": .object([
          "width": .int(1024),
          "height": .int(1024),
          "steps": .int(30),
        ]),
      ])),

    .img2img: ContractExample(
      endpoint: "/v1/compose",
      body: .object([
        "model": .string("<installed image base_model id>"),
        "prompt": .string("oil-painting style, warm light"),
        "from": .object([
          "image": .string("<base64 source image bytes>"),
        ]),
        "params": .object([
          "width": .int(1024),
          "height": .int(1024),
          "steps": .int(30),
          "denoising_strength": .double(0.65),
        ]),
      ])),

    .inpaint: ContractExample(
      endpoint: "/v1/edit",
      body: .object([
        "model": .string("<installed image base_model id>"),
        "from": .object(["image": .string("<base64 source image bytes>")]),
        "mask": .string("<base64 mask bytes — non-zero pixels = regenerate>"),
        "instruction": .string("a wooden park bench in the empty area"),
        "params": .object([
          "width": .int(1024),
          "height": .int(1024),
          "steps": .int(30),
        ]),
      ])),

    .edit: ContractExample(
      endpoint: "/v1/edit",
      body: .object([
        "model": .string("flux_kontext_dev"),
        "from": .object(["image": .string("<base64 source image bytes>")]),
        "instruction": .string("remove the text overlay, keep everything else intact"),
        "params": .object([
          "width": .int(1024),
          "height": .int(1024),
          "steps": .int(30),
        ]),
      ])),

    .restore: ContractExample(
      endpoint: "/v1/restore",
      body: .object([
        "model": .string("seedvr2_3b"),
        "from": .object(["image": .string("<base64 source image bytes>")]),
        "params": .object([
          "width": .int(1024),
          "height": .int(1024),
          "steps": .int(20),
        ]),
      ])),

    .txt2vid: ContractExample(
      endpoint: "/v1/compose",
      body: .object([
        "model": .string("<installed video base_model id>"),
        "prompt": .string("a slow drone shot over a snowy forest at dawn"),
        "params": .object([
          "width": .int(512),
          "height": .int(512),
          "steps": .int(30),
          "video": .object([
            "num_frames": .int(16),
            "fps": .int(8),
            "video_format": .string("mp4_h264"),
          ]),
        ]),
      ])),

    .img2vid: ContractExample(
      endpoint: "/v1/compose",
      body: .object([
        "model": .string("<installed image-to-video base_model id>"),
        "prompt": .string("camera slowly pans right"),
        "from": .object(["image": .string("<base64 anchor frame bytes>")]),
        "params": .object([
          "width": .int(512),
          "height": .int(512),
          "steps": .int(30),
          "conditioning_strength": .double(1.0),
          "video": .object([
            "num_frames": .int(16),
            "fps": .int(8),
          ]),
        ]),
      ])),
  ]
}
