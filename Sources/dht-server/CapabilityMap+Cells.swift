// MARK: - Capability map cells (v0 hand-transcribed)
//
// Source of truth for `(BehaviorClass, Modifier) → [Operation: ContractTemplate]`.
// `accepted` declares the canonical knobs and their constraints. `silent_drops`
// only enumerates fields a caller might *plausibly* try to send but that the
// engine ignores for this cell — it is not exhaustive. `refused` enumerates
// field-level typed-400 conditions; op-level refusals (e.g. `/v1/edit` on a
// non-instruction-edit model) are handled by the op not appearing in this
// cell's operation set.

// MARK: - Field-constraint shorthands

private enum F {
  // Required text + identity
  static let prompt = FieldConstraint.string(required: true)
  static let promptOpt = FieldConstraint.string()
  static let negativePrompt = FieldConstraint.string()
  static let baseModelId = FieldConstraint.string(required: true)

  // Required image-output geometry
  static let widthHW = FieldConstraint.int(
    min: 64, max: 4096, multipleOf: 64, required: true)
  static let heightHW = FieldConstraint.int(
    min: 64, max: 4096, multipleOf: 64, required: true)
  static let steps = FieldConstraint.int(min: 1, max: 200, required: false)
  static let cfgScale = FieldConstraint.float(
    min: 0, max: 30, exclusiveMin: true)

  // Sampling controls
  static let seed = FieldConstraint.int64()
  static let seedMode = FieldConstraint.string()
  static let sampler = FieldConstraint.string()
  static let outputFormat = FieldConstraint.string()
  static let videoFormat = FieldConstraint.string()
  static let clipSkip = FieldConstraint.int(min: 1, max: 12)
  static let runId = FieldConstraint.string()

  // Batching (cap-aware, see notes per cell)
  static let batchCount = FieldConstraint.int(min: 1, max: 16)
  static func batchSize(max: Int = 16) -> FieldConstraint {
    .int(min: 1, max: max)
  }

  // Renoise / edit / inpaint extras
  static let sourceImage = FieldConstraint.base64(required: true)
  static let mask = FieldConstraint.base64(required: true)
  static let editImage = FieldConstraint.base64(required: true)
  static let restoreImageIn = FieldConstraint.base64(required: true)
  static let denoisingStrength = FieldConstraint.float(
    min: 0, max: 1, required: true)

  // Optional images for hint routing
  static let referenceImage = FieldConstraint.base64()
  static let depthImage = FieldConstraint.base64()

  // Sub-objects
  static let loras = FieldConstraint.array(itemsRef: "LoRARef")
  static let controlnets = FieldConstraint.array(itemsRef: "ControlNetRef")
  static let hiresFix = FieldConstraint.object(ref: "HiresFixParams")
  static let refiner = FieldConstraint.object(ref: "RefinerParams")
  static let upscaler = FieldConstraint.object(ref: "UpscalerParams")
  static let tiling = FieldConstraint.object(ref: "TilingParams")
  static let extensions = FieldConstraint.object(ref: "Extensions")
  static let flowMatch = FieldConstraint.object(ref: "FlowMatchParams")
  static let sdxlConditioning = FieldConstraint.object(ref: "SDXLConditioningParams")
  static let textEncoders = FieldConstraint.object(ref: "TextEncodersParams")
  static let cascade = FieldConstraint.object(ref: "CascadeParams")
  static let imagePrior = FieldConstraint.object(ref: "ImagePriorParams")

  static let sharpness = FieldConstraint.float()

  // Video-specific
  static let numFrames = FieldConstraint.int(min: 1, max: 256, required: true)
  static let fps = FieldConstraint.int(min: 1, max: 120)
  static let conditioningImage = FieldConstraint.base64(required: true)
  static let conditioningStrength = FieldConstraint.float(min: 0, max: 1)
  static let motion = FieldConstraint.object(ref: "VideoMotionParams")
}

// MARK: - Field bundles

private enum FieldBundle {
  /// Universal scalar fields for image-generation operations. `clip_skip` is
  /// included; cells whose text encoder is not CLIP-based override it via
  /// a `silent_drops` entry.
  static let universalImageScalars: [String: FieldConstraint] = [
    "prompt": F.prompt,
    "negative_prompt": F.negativePrompt,
    "base_model_id": F.baseModelId,
    "width": F.widthHW,
    "height": F.heightHW,
    "steps": F.steps,
    "cfg_scale": F.cfgScale,
    "seed": F.seed,
    "seed_mode": F.seedMode,
    "sampler": F.sampler,
    "clip_skip": F.clipSkip,
    "output_format": F.outputFormat,
    "batch_size": F.batchSize(),
    "batch_count": F.batchCount,
    "run_id": F.runId,
    "extensions": F.extensions,
    "sharpness": F.sharpness,
  ]

  /// Generic sub-objects every modern image arch can consume.
  static let commonImageSubObjects: [String: FieldConstraint] = [
    "loras": F.loras,
    "controlnets": F.controlnets,
    "reference_image": F.referenceImage,
    "depth_image": F.depthImage,
    "upscaler": F.upscaler,
    "tiling": F.tiling,
  ]

  /// Video-specific top-level fields (txt2vid). img2vid extends with
  /// conditioning_image + conditioning_strength.
  static let videoExtras: [String: FieldConstraint] = [
    "num_frames": F.numFrames,
    "fps": F.fps,
    "video_format": F.videoFormat,
    "motion": F.motion,
  ]
}

// MARK: - Shared silent-drop entries

private enum Drops {
  static let sdxlConditioning = SilentDrop(
    field: "sdxl_conditioning",
    reason: "SDXL-only micro-conditioning fields")
  static let textEncodersMulti = SilentDrop(
    field: "text_encoders",
    reason: "Multi-encoder fan-out (CLIP-L/G, T5) — applies to SDXL/SD3/FLUX")
  static let cascade = SilentDrop(
    field: "cascade",
    reason: "Stable Cascade two-stage settings only")
  static let imagePrior = SilentDrop(
    field: "image_prior",
    reason: "Kandinsky 2.1-only image-prior step settings")
  static let flowMatchOnDdpmEdm = SilentDrop(
    field: "flow_match",
    reason: "Flow-matching params apply to RF archs (SD3/FLUX/Z-Image/Qwen-Image/etc); ignored on DDPM/EDM archs")
  static let preserveOrigAfterInpaintOnNonInpainting = SilentDrop(
    field: "extensions.draw_things.preserve_original_after_inpaint",
    reason: "Only honored by base models whose modifier is 'inpainting'")
  static let teaCacheOnNonTransformer = SilentDrop(
    field: "extensions.draw_things.tea_cache",
    reason: "TeaCache applies to flow-matching transformer architectures")
  static let causalInferenceOnNonVideo = SilentDrop(
    field: "extensions.draw_things.causal_inference",
    reason: "Causal inference padding applies to video architectures")
  static let guidanceEmbedOnNonGuidanceEmbed = SilentDrop(
    field: "extensions.draw_things.guidance_embed",
    reason: "Only applies to guidance-embed models (FLUX dev, Cosmos)")
  static let clipSkipOnNonClip = SilentDrop(
    field: "clip_skip",
    reason: "This architecture's text encoder is not CLIP-based")
  static let videoExtrasOnImage = SilentDrop(
    field: "num_frames",
    reason: "Video-only field; image generation ignores it")
}

// Boilerplate silent-drop sets reused across cohorts.
private let classicImageDrops: [SilentDrop] = [
  Drops.sdxlConditioning,
  Drops.textEncodersMulti,
  Drops.cascade,
  Drops.imagePrior,
  Drops.flowMatchOnDdpmEdm,
  Drops.preserveOrigAfterInpaintOnNonInpainting,
  Drops.teaCacheOnNonTransformer,
  Drops.causalInferenceOnNonVideo,
  Drops.guidanceEmbedOnNonGuidanceEmbed,
]

private let inpaintingImageDrops: [SilentDrop] = [
  Drops.sdxlConditioning,
  Drops.textEncodersMulti,
  Drops.cascade,
  Drops.imagePrior,
  Drops.flowMatchOnDdpmEdm,
  Drops.teaCacheOnNonTransformer,
  Drops.causalInferenceOnNonVideo,
  Drops.guidanceEmbedOnNonGuidanceEmbed,
]

private let sdxlDrops: [SilentDrop] = [
  Drops.cascade,
  Drops.imagePrior,
  Drops.flowMatchOnDdpmEdm,
  Drops.preserveOrigAfterInpaintOnNonInpainting,
  Drops.teaCacheOnNonTransformer,
  Drops.causalInferenceOnNonVideo,
  Drops.guidanceEmbedOnNonGuidanceEmbed,
]

private let sdxlInpaintingDrops: [SilentDrop] = [
  Drops.cascade,
  Drops.imagePrior,
  Drops.flowMatchOnDdpmEdm,
  Drops.teaCacheOnNonTransformer,
  Drops.causalInferenceOnNonVideo,
  Drops.guidanceEmbedOnNonGuidanceEmbed,
]

/// Modern RF (flow-matching) transformer image archs: flow_match accepted,
/// tea_cache accepted; sdxl_conditioning/cascade/image_prior dropped.
private let modernRfImageDrops: [SilentDrop] = [
  Drops.sdxlConditioning,
  Drops.cascade,
  Drops.imagePrior,
  Drops.preserveOrigAfterInpaintOnNonInpainting,
  Drops.causalInferenceOnNonVideo,
  Drops.guidanceEmbedOnNonGuidanceEmbed,
]

/// Same as `modernRfImageDrops` but the text encoder has no CLIP — `clip_skip`
/// is silent-dropped (FLUX2 / Z-Image / Qwen-Image / Ernie-Image / Cosmos2).
private let modernRfNoClipImageDrops: [SilentDrop] = [
  Drops.clipSkipOnNonClip,
  Drops.sdxlConditioning,
  Drops.cascade,
  Drops.imagePrior,
  Drops.preserveOrigAfterInpaintOnNonInpainting,
  Drops.causalInferenceOnNonVideo,
  Drops.guidanceEmbedOnNonGuidanceEmbed,
]

private let videoDrops: [SilentDrop] = [
  Drops.sdxlConditioning,
  Drops.textEncodersMulti,
  Drops.cascade,
  Drops.imagePrior,
  Drops.preserveOrigAfterInpaintOnNonInpainting,
  Drops.guidanceEmbedOnNonGuidanceEmbed,
]

// MARK: - Cell helpers

private func merging(
  _ a: [String: FieldConstraint],
  _ b: [String: FieldConstraint]
) -> [String: FieldConstraint] {
  a.merging(b) { _, rhs in rhs }
}

private func merging(
  _ a: [String: FieldConstraint],
  _ b: [String: FieldConstraint],
  _ c: [String: FieldConstraint]
) -> [String: FieldConstraint] {
  merging(merging(a, b), c)
}

private func merging(
  _ a: [String: FieldConstraint],
  _ b: [String: FieldConstraint],
  _ c: [String: FieldConstraint],
  _ d: [String: FieldConstraint]
) -> [String: FieldConstraint] {
  merging(merging(merging(a, b), c), d)
}

/// Img2img extras layered on top of image scalars.
private let img2imgExtras: [String: FieldConstraint] = [
  "source_image": F.sourceImage,
  "denoising_strength": F.denoisingStrength,
]

/// Inpaint extras layered on top of image scalars.
private let inpaintExtras: [String: FieldConstraint] = [
  "source_image": F.sourceImage,
  "mask": F.mask,
  "denoising_strength": F.denoisingStrength,
]

private let instructionEditExtras: [String: FieldConstraint] = [
  "image": F.editImage,
]

private let img2vidExtras: [String: FieldConstraint] = [
  "conditioning_image": F.conditioningImage,
  "conditioning_strength": F.conditioningStrength,
]

// Classic image cohort: SD1.x / SDXL inpainting + refiner.
private let classicExtraSubObjects: [String: FieldConstraint] = [
  "hires_fix": F.hiresFix,
  "refiner": F.refiner,
]

// SDXL exposes the micro-conditioning struct + multi-encoder fan-out.
private let sdxlExtraSubObjects: [String: FieldConstraint] = [
  "hires_fix": F.hiresFix,
  "refiner": F.refiner,
  "sdxl_conditioning": F.sdxlConditioning,
  "text_encoders": F.textEncoders,
]

// Modern RF image cohort: flow_match accepted; no hires_fix (less common).
private let modernRfExtraSubObjects: [String: FieldConstraint] = [
  "flow_match": F.flowMatch,
  "hires_fix": F.hiresFix,
]

// MARK: - The cells dict

let capabilityCells: [CapabilityMap.Key: [Operation: ContractTemplate]] = [

  // =====================================================================
  // SD 1.x / 2.x family
  // =====================================================================

  // (sd1x, .none) — vanilla T2I + img2img
  .init(behaviorClass: .sd1x, modifier: .none): [
    .txt2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        classicExtraSubObjects),
      silentDrops: classicImageDrops,
      notes: [
        "SD 1.x / 2.x vanilla T2I. CFG-based; negative_prompt and clip_skip are first-class.",
        "reference_image / depth_image route to typed inputs only if a matching controlnets[] entry is present (input_type_override=shuffle for reference, =depth for depth). Otherwise silently ignored (REFERENCE_IMAGE_UNUSED / DEPTH_IMAGE_UNUSED warning).",
      ]),
    .img2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        classicExtraSubObjects,
        img2imgExtras),
      silentDrops: classicImageDrops,
      notes: [
        "SD 1.x / 2.x renoise from source_image at denoising_strength (latent-space). Output width/height should normally match source_image dimensions; mismatched values trigger an engine-side resample on the source before encoding.",
      ]),
  ],

  // (sd1x, .inpainting) — dedicated inpaint fine-tunes (SD-Inpaint variants)
  .init(behaviorClass: .sd1x, modifier: .inpainting): [
    .inpaint: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        classicExtraSubObjects,
        inpaintExtras),
      silentDrops: inpaintingImageDrops,
      notes: [
        "SD 1.x / 2.x inpaint fine-tune. mask non-zero pixels mark the region to regenerate.",
        "extensions.draw_things.preserve_original_after_inpaint is honored on this modifier (regenerates only the masked region, leaves the rest pixel-for-pixel).",
      ]),
  ],

  // (sd1x, .depth) — depth-conditioned base
  .init(behaviorClass: .sd1x, modifier: .depth): [
    .txt2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        classicExtraSubObjects),
      silentDrops: classicImageDrops,
      notes: [
        "Depth-conditioned SD 1.x base. Provide a depth map via depth_image (routed to a .depth typed input) or via a controlnets[] entry with input_type_override='depth'. Without a hint the engine falls back to a degraded vanilla generation.",
      ]),
    .img2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        classicExtraSubObjects,
        img2imgExtras),
      silentDrops: classicImageDrops,
      notes: [
        "Depth-conditioned img2img. source_image is treated as the depth hint, not as a renoise init.",
      ]),
  ],

  // (sd1x, .canny) — canny-conditioned base (img2img canonical)
  .init(behaviorClass: .sd1x, modifier: .canny): [
    .img2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        classicExtraSubObjects,
        img2imgExtras),
      silentDrops: classicImageDrops,
      notes: [
        "Canny-conditioned SD 1.x base. source_image is the canny edge map. Alternatively use a controlnets[] entry with input_type_override='canny'.",
      ]),
  ],

  // (sd1x, .editing) — instruct-pix2pix on SD 1.x (img2img with prompt-as-instruction)
  .init(behaviorClass: .sd1x, modifier: .editing): [
    .img2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        classicExtraSubObjects,
        img2imgExtras),
      silentDrops: classicImageDrops,
      notes: [
        "Legacy instruction-edit on SD 1.x (instruct-pix2pix-style). source_image is the edit target; prompt is the natural-language instruction.",
        "extensions.draw_things.image_guidance_scale controls instruction adherence (instruct-pix2pix has dual classifier-free guidance over text + image).",
      ]),
  ],

  // =====================================================================
  // SDXL family (sdxlBase, ssd1b; sdxlRefiner has no public ops via Architecture.behaviorClass=nil)
  // =====================================================================

  .init(behaviorClass: .sdxl, modifier: .none): [
    .txt2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        sdxlExtraSubObjects),
      silentDrops: sdxlDrops,
      notes: [
        "SDXL Base or SSD-1B. Multi-encoder (CLIP-L + OpenCLIP-G); both encoders accept clip_skip individually via text_encoders.",
        "sdxl_conditioning controls the micro-conditioning vector (target/original size, crop, aesthetic score). refiner chains an sdxlRefiner asset for late-stage denoising.",
      ]),
    .img2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        sdxlExtraSubObjects,
        img2imgExtras),
      silentDrops: sdxlDrops,
      notes: [
        "SDXL renoise from source_image at denoising_strength.",
      ]),
  ],

  .init(behaviorClass: .sdxl, modifier: .inpainting): [
    .inpaint: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        sdxlExtraSubObjects,
        inpaintExtras),
      silentDrops: sdxlInpaintingDrops,
      notes: [
        "SDXL inpaint fine-tune. mask non-zero pixels mark the region to regenerate.",
        "extensions.draw_things.preserve_original_after_inpaint is honored on this modifier.",
      ]),
  ],

  // =====================================================================
  // Stable Cascade (wurstchenStageC only; wurstchenStageB is non-callable)
  // =====================================================================

  .init(behaviorClass: .stableCascade, modifier: .none): [
    .txt2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        ["cascade": F.cascade]),
      silentDrops: [
        Drops.sdxlConditioning,
        Drops.textEncodersMulti,
        Drops.imagePrior,
        Drops.flowMatchOnDdpmEdm,
        Drops.preserveOrigAfterInpaintOnNonInpainting,
        Drops.teaCacheOnNonTransformer,
        Drops.causalInferenceOnNonVideo,
        Drops.guidanceEmbedOnNonGuidanceEmbed,
      ],
      notes: [
        "Stable Cascade (Würstchen). Pick the StageC model_id; the engine chains StageB internally as the decoder.",
        "cascade.stage2_* controls the StageB pass (steps, guidance, shift).",
      ]),
  ],

  // =====================================================================
  // Kandinsky 2.1
  // =====================================================================

  .init(behaviorClass: .kandinsky21, modifier: .none): [
    .txt2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        ["image_prior": F.imagePrior]),
      silentDrops: [
        Drops.sdxlConditioning,
        Drops.textEncodersMulti,
        Drops.cascade,
        Drops.flowMatchOnDdpmEdm,
        Drops.preserveOrigAfterInpaintOnNonInpainting,
        Drops.teaCacheOnNonTransformer,
        Drops.causalInferenceOnNonVideo,
        Drops.guidanceEmbedOnNonGuidanceEmbed,
      ],
      notes: [
        "Kandinsky 2.1. Two-stage: a CLIP-based image prior (image_prior.*) then the diffusion decoder.",
      ]),
    .img2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        ["image_prior": F.imagePrior],
        img2imgExtras),
      silentDrops: [
        Drops.sdxlConditioning,
        Drops.textEncodersMulti,
        Drops.cascade,
        Drops.flowMatchOnDdpmEdm,
        Drops.preserveOrigAfterInpaintOnNonInpainting,
        Drops.teaCacheOnNonTransformer,
        Drops.causalInferenceOnNonVideo,
        Drops.guidanceEmbedOnNonGuidanceEmbed,
      ],
      notes: ["Kandinsky 2.1 img2img renoise from source_image."]),
  ],

  // =====================================================================
  // Modern flow-matching image archs (transformer DiT, RF noise)
  // =====================================================================

  // SD3 / SD3-Large
  .init(behaviorClass: .sd3, modifier: .none): [
    .txt2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        modernRfExtraSubObjects,
        ["text_encoders": F.textEncoders]),
      silentDrops: modernRfImageDrops,
      notes: [
        "SD3 / SD3-Large. Flow matching (RF). Multi-encoder (CLIP-L + CLIP-G + T5); text_encoders allows separate prompts per encoder.",
      ]),
    .img2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        modernRfExtraSubObjects,
        merging(["text_encoders": F.textEncoders], img2imgExtras)),
      silentDrops: modernRfImageDrops,
      notes: ["SD3 img2img renoise from source_image."]),
  ],

  // PixArt
  .init(behaviorClass: .pixart, modifier: .none): [
    .txt2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        ["hires_fix": F.hiresFix]),
      silentDrops: [
        Drops.clipSkipOnNonClip,
        Drops.sdxlConditioning,
        Drops.textEncodersMulti,
        Drops.cascade,
        Drops.imagePrior,
        Drops.flowMatchOnDdpmEdm,
        Drops.preserveOrigAfterInpaintOnNonInpainting,
        Drops.teaCacheOnNonTransformer,
        Drops.causalInferenceOnNonVideo,
        Drops.guidanceEmbedOnNonGuidanceEmbed,
      ],
      notes: ["PixArt-α. T5-only text encoder (no CLIP); DDPM noise."]),
    .img2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        merging(["hires_fix": F.hiresFix], img2imgExtras)),
      silentDrops: [
        Drops.clipSkipOnNonClip,
        Drops.sdxlConditioning,
        Drops.textEncodersMulti,
        Drops.cascade,
        Drops.imagePrior,
        Drops.flowMatchOnDdpmEdm,
        Drops.preserveOrigAfterInpaintOnNonInpainting,
        Drops.teaCacheOnNonTransformer,
        Drops.causalInferenceOnNonVideo,
        Drops.guidanceEmbedOnNonGuidanceEmbed,
      ],
      notes: ["PixArt-α img2img renoise."]),
  ],

  // AuraFlow
  .init(behaviorClass: .auraflow, modifier: .none): [
    .txt2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        modernRfExtraSubObjects),
      silentDrops: modernRfNoClipImageDrops,
      notes: ["AuraFlow. T5/UMT5 text encoder (no CLIP); flow matching."]),
    .img2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        modernRfExtraSubObjects,
        img2imgExtras),
      silentDrops: modernRfNoClipImageDrops,
      notes: ["AuraFlow img2img renoise."]),
  ],

  // FLUX.1 (Schnell + dev). CLIP-L + T5; flow matching.
  .init(behaviorClass: .flux1, modifier: .none): [
    .txt2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        modernRfExtraSubObjects,
        ["text_encoders": F.textEncoders]),
      silentDrops: modernRfImageDrops,
      notes: [
        "FLUX.1 [schnell or dev]. Flow matching; CLIP-L + T5XXL encoders.",
        "FLUX dev honors extensions.draw_things.guidance_embed (distilled guidance value).",
      ]),
    .img2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        modernRfExtraSubObjects,
        merging(["text_encoders": F.textEncoders], img2imgExtras)),
      silentDrops: modernRfImageDrops,
      notes: ["FLUX.1 img2img renoise from source_image."]),
  ],

  // FLUX.1 Kontext — instruction edit
  .init(behaviorClass: .flux1, modifier: .kontext): [
    .edit: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        merging(["loras": F.loras, "upscaler": F.upscaler], [:]),
        merging(modernRfExtraSubObjects, ["text_encoders": F.textEncoders]),
        merging(instructionEditExtras, ["reference_image": F.referenceImage])),
      silentDrops: modernRfImageDrops + [
        SilentDrop(
          field: "controlnets",
          reason: "Kontext edit consumes the target via the kontext reference path; controlnets are not engaged"),
        SilentDrop(
          field: "depth_image",
          reason: "Not used in the Kontext edit path"),
      ],
      notes: [
        "FLUX.1 Kontext — instruction-edit. `image` is the edit target (routed as a kontext reference via moodboard). `prompt` is the natural-language edit instruction.",
        "Extra reference images go via `reference_image` (base64).",
      ]),
  ],

  // (flux1, .kontext_kv) — KV-cache variant, same wire
  .init(behaviorClass: .flux1, modifier: .kontextKv): [
    .edit: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        merging(["loras": F.loras, "upscaler": F.upscaler], [:]),
        merging(modernRfExtraSubObjects, ["text_encoders": F.textEncoders]),
        merging(instructionEditExtras, ["reference_image": F.referenceImage])),
      silentDrops: modernRfImageDrops + [
        SilentDrop(field: "controlnets", reason: "Kontext edit path does not engage controlnets"),
        SilentDrop(field: "depth_image", reason: "Not used in the Kontext edit path"),
      ],
      notes: [
        "FLUX.1 Kontext (KV-cache variant). Same wire as .kontext.",
      ]),
  ],

  // FLUX.2 (flux2 + flux2_9b + flux2_4b). Qwen3 encoder, no CLIP.
  .init(behaviorClass: .flux2, modifier: .none): [
    .txt2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        modernRfExtraSubObjects),
      silentDrops: modernRfNoClipImageDrops,
      notes: [
        "FLUX.2 family (flux2 / 9b / 4b). Flow matching; Qwen3 text encoder (no CLIP).",
      ]),
    .img2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        modernRfExtraSubObjects,
        img2imgExtras),
      silentDrops: modernRfNoClipImageDrops,
      notes: ["FLUX.2 img2img renoise from source_image."]),
  ],

  // FLUX.2 Kontext (KV-cache)
  .init(behaviorClass: .flux2, modifier: .kontextKv): [
    .edit: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        merging(["loras": F.loras, "upscaler": F.upscaler], [:]),
        modernRfExtraSubObjects,
        merging(instructionEditExtras, ["reference_image": F.referenceImage])),
      silentDrops: modernRfNoClipImageDrops + [
        SilentDrop(field: "controlnets", reason: "Kontext edit path does not engage controlnets"),
        SilentDrop(field: "depth_image", reason: "Not used in the Kontext edit path"),
      ],
      notes: ["FLUX.2 Kontext instruction-edit. Same wire as FLUX.1 Kontext."]),
  ],

  // FLUX.2 Klein with modifier=.kontext (non-KV variant shipped in the catalog)
  .init(behaviorClass: .flux2, modifier: .kontext): [
    .edit: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        merging(["loras": F.loras, "upscaler": F.upscaler], [:]),
        modernRfExtraSubObjects,
        merging(instructionEditExtras, ["reference_image": F.referenceImage])),
      silentDrops: modernRfNoClipImageDrops + [
        SilentDrop(field: "controlnets", reason: "Kontext edit path does not engage controlnets"),
        SilentDrop(field: "depth_image", reason: "Not used in the Kontext edit path"),
      ],
      notes: [
        "FLUX.2 Klein / Klein-Base 4B (instruction-edit). Same wire as FLUX.1 Kontext; this variant uses modifier='kontext' rather than 'kontext_kv'.",
      ]),
  ],

  // HiDream-E1 — instruction-edit variant (modifier='editing')
  .init(behaviorClass: .hidream, modifier: .editing): [
    .edit: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        merging(["loras": F.loras, "upscaler": F.upscaler], [:]),
        merging(modernRfExtraSubObjects, ["text_encoders": F.textEncoders]),
        merging(instructionEditExtras, ["reference_image": F.referenceImage])),
      silentDrops: modernRfImageDrops + [
        SilentDrop(field: "controlnets", reason: "Instruction-edit path does not engage controlnets"),
        SilentDrop(field: "depth_image", reason: "Not used"),
      ],
      notes: [
        "HiDream-E1 instruction-edit variant. `image` is the edit target; `prompt` is the instruction.",
      ]),
  ],

  // HiDream-I1
  .init(behaviorClass: .hidream, modifier: .none): [
    .txt2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        modernRfExtraSubObjects,
        ["text_encoders": F.textEncoders]),
      silentDrops: modernRfImageDrops,
      notes: [
        "HiDream-I1. Flow matching; complex multi-encoder mix (CLIP-L/G + T5 + Llama).",
      ]),
    .img2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        modernRfExtraSubObjects,
        merging(["text_encoders": F.textEncoders], img2imgExtras)),
      silentDrops: modernRfImageDrops,
      notes: ["HiDream-I1 img2img renoise."]),
  ],

  // Qwen-Image — vanilla T2I + I2I
  .init(behaviorClass: .qwenImage, modifier: .none): [
    .txt2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        modernRfExtraSubObjects),
      silentDrops: modernRfNoClipImageDrops,
      notes: ["Qwen-Image. Flow matching; Qwen2.5-VL text encoder (no CLIP)."]),
    .img2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        modernRfExtraSubObjects,
        img2imgExtras),
      silentDrops: modernRfNoClipImageDrops,
      notes: ["Qwen-Image img2img renoise."]),
  ],

  // Qwen-Image Edit Plus — instruction edit
  .init(behaviorClass: .qwenImage, modifier: .qwenimageEditPlus): [
    .edit: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        merging(["loras": F.loras, "upscaler": F.upscaler], [:]),
        modernRfExtraSubObjects,
        merging(instructionEditExtras, ["reference_image": F.referenceImage])),
      silentDrops: modernRfNoClipImageDrops + [
        SilentDrop(field: "controlnets", reason: "Instruction-edit path does not engage controlnets"),
        SilentDrop(field: "depth_image", reason: "Not used in the Qwen-Image-Edit path"),
      ],
      notes: [
        "Qwen-Image-Edit-Plus (instruction-based). `image` is the edit target; `prompt` is the natural-language instruction.",
        "Multiple reference images supported via `reference_image` (base64).",
      ]),
  ],

  // Qwen-Image Edit 2511 — same wire, different recommended steps
  .init(behaviorClass: .qwenImage, modifier: .qwenimageEdit2511): [
    .edit: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        merging(["loras": F.loras, "upscaler": F.upscaler], [:]),
        modernRfExtraSubObjects,
        merging(instructionEditExtras, ["reference_image": F.referenceImage])),
      silentDrops: modernRfNoClipImageDrops + [
        SilentDrop(field: "controlnets", reason: "Instruction-edit path does not engage controlnets"),
        SilentDrop(field: "depth_image", reason: "Not used in the Qwen-Image-Edit path"),
      ],
      notes: [
        "Qwen-Image-Edit-2511. Same wire as the Plus variant; recommended ~40 steps for best output.",
      ]),
  ],

  // Qwen-Image-Edit 1.0 — ships with modifier='kontext' (not the newer
  // qwenimage_edit_* family). Same instruction-edit wire shape.
  .init(behaviorClass: .qwenImage, modifier: .kontext): [
    .edit: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        merging(["loras": F.loras, "upscaler": F.upscaler], [:]),
        modernRfExtraSubObjects,
        merging(instructionEditExtras, ["reference_image": F.referenceImage])),
      silentDrops: modernRfNoClipImageDrops + [
        SilentDrop(field: "controlnets", reason: "Instruction-edit path does not engage controlnets"),
        SilentDrop(field: "depth_image", reason: "Not used"),
      ],
      notes: [
        "Qwen-Image-Edit 1.0 (kontext-style instruction-edit). The 1.0 variant uses modifier='kontext'; later Edit-Plus / Edit-2511 use their own qwenimage_edit_* modifiers.",
      ]),
  ],

  // Qwen-Image Layered — single-canvas img2img variant (NOT an edit op)
  .init(behaviorClass: .qwenImage, modifier: .qwenimageLayered): [
    .img2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        modernRfExtraSubObjects,
        img2imgExtras),
      silentDrops: modernRfNoClipImageDrops,
      notes: [
        "Qwen-Image Layered (single-canvas variant). Pass the canvas as `source_image` on /v1/img2img. Layer references are not exposed via the public SDK in v0.",
      ]),
  ],

  // Z-Image
  .init(behaviorClass: .zImage, modifier: .none): [
    .txt2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        modernRfExtraSubObjects),
      silentDrops: modernRfNoClipImageDrops,
      notes: [
        "Z-Image. Flow matching; Qwen3 text encoder (no CLIP). Engine does NOT cap batch_size on this arch.",
      ]),
    .img2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        modernRfExtraSubObjects,
        img2imgExtras),
      silentDrops: modernRfNoClipImageDrops,
      notes: ["Z-Image img2img renoise."]),
  ],

  // Ernie-Image
  .init(behaviorClass: .ernieImage, modifier: .none): [
    .txt2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        modernRfExtraSubObjects),
      silentDrops: modernRfNoClipImageDrops,
      notes: ["Ernie-Image. Flow matching; Ernie text encoder (no CLIP)."]),
    .img2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        modernRfExtraSubObjects,
        img2imgExtras),
      silentDrops: modernRfNoClipImageDrops,
      notes: ["Ernie-Image img2img renoise."]),
  ],

  // Cosmos 2.5 2B — image-domain T2I per SDK isVideoModel=false. v0 claims
  // txt2img only (img2img unverified, deferred per user direction).
  .init(behaviorClass: .cosmos2, modifier: .none): [
    .txt2img: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.commonImageSubObjects,
        modernRfExtraSubObjects),
      silentDrops: modernRfNoClipImageDrops,
      notes: [
        "Cosmos 2.5 2B. Image-generation T2I (NVIDIA Cosmos family, image variant). Flow matching; Qwen3 + T5XXL conditioning, no CLIP.",
        "v0 claims txt2img only — img2img is not validated yet; revisit after empirical probe.",
      ]),
  ],

  // =====================================================================
  // SeedVR2 — image super-resolution / restoration (new op)
  // =====================================================================

  .init(behaviorClass: .seedvr2, modifier: .none): [
    .restore: seedVR2RestoreTemplate(modifierNote: nil),
  ],

  // SeedVR2 variants shipped with modifier='inpainting' — same restoration
  // wire in v0 (modifier likely signals an internal VAE/encoder variant; the
  // user-facing op stays `restore`). Probe in phase 5 to confirm.
  .init(behaviorClass: .seedvr2, modifier: .inpainting): [
    .restore: seedVR2RestoreTemplate(
      modifierNote: "SeedVR2 variant shipped with modifier='inpainting'. v0 claims the same restore wire as the .none variant; semantics may differ slightly — verify in phase 5."),
  ],

  // =====================================================================
  // Video models
  // =====================================================================

  // SVD i2v — img2vid only (txt2vid unsupported: needs init image conditioning)
  .init(behaviorClass: .svdI2v, modifier: .none): [
    .img2vid: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.videoExtras,
        ["loras": F.loras, "upscaler": F.upscaler],
        img2vidExtras),
      silentDrops: videoDrops + [
        Drops.flowMatchOnDdpmEdm,
        SilentDrop(field: "controlnets", reason: "Video archs don't engage ControlNet"),
        SilentDrop(field: "reference_image", reason: "Use conditioning_image for the init frame"),
        SilentDrop(field: "depth_image", reason: "Video archs don't engage depth hints"),
        SilentDrop(field: "tiling", reason: "Video archs don't tile decode"),
        Drops.teaCacheOnNonTransformer,
      ],
      notes: [
        "Stable Video Diffusion (image-to-video). Pass the init frame as `conditioning_image` (base64). motion.motion_scale controls movement intensity.",
        "No txt2vid path on this arch: the engine requires a conditioning image for SVD inference.",
        "batch_size is capped to 1 engine-side.",
      ]),
  ],

  // Hunyuan Video
  .init(behaviorClass: .hunyuanVideo, modifier: .none): [
    .txt2vid: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.videoExtras,
        ["loras": F.loras, "upscaler": F.upscaler],
        ["flow_match": F.flowMatch]),
      silentDrops: videoDrops + [
        Drops.clipSkipOnNonClip,
        SilentDrop(field: "controlnets", reason: "Video archs don't engage ControlNet"),
        SilentDrop(field: "reference_image", reason: "Not used for txt2vid"),
        SilentDrop(field: "depth_image", reason: "Not used for txt2vid"),
      ],
      notes: ["Hunyuan Video txt2vid. Flow matching; LLaMA-based text encoder."]),
    .img2vid: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.videoExtras,
        merging(["loras": F.loras, "upscaler": F.upscaler], img2vidExtras),
        ["flow_match": F.flowMatch]),
      silentDrops: videoDrops + [
        Drops.clipSkipOnNonClip,
        SilentDrop(field: "controlnets", reason: "Video archs don't engage ControlNet"),
        SilentDrop(field: "reference_image", reason: "Use conditioning_image for the init frame"),
        SilentDrop(field: "depth_image", reason: "Not used"),
      ],
      notes: ["Hunyuan Video img2vid. conditioning_image is the init frame."]),
  ],

  // Wan 2.1 (1.3B + 14B)
  .init(behaviorClass: .wan21, modifier: .none): [
    .txt2vid: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.videoExtras,
        ["loras": F.loras, "upscaler": F.upscaler],
        ["flow_match": F.flowMatch]),
      silentDrops: videoDrops + [
        Drops.clipSkipOnNonClip,
        SilentDrop(field: "controlnets", reason: "Video archs don't engage ControlNet"),
        SilentDrop(field: "reference_image", reason: "Not used for txt2vid"),
        SilentDrop(field: "depth_image", reason: "Not used for txt2vid"),
      ],
      notes: ["Wan 2.1 txt2vid. Flow matching. UMT5 text encoder (no CLIP)."]),
    .img2vid: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.videoExtras,
        merging(["loras": F.loras, "upscaler": F.upscaler], img2vidExtras),
        ["flow_match": F.flowMatch]),
      silentDrops: videoDrops + [
        Drops.clipSkipOnNonClip,
        SilentDrop(field: "controlnets", reason: "Video archs don't engage ControlNet"),
        SilentDrop(field: "reference_image", reason: "Use conditioning_image for the anchor frame"),
        SilentDrop(field: "depth_image", reason: "Not used"),
      ],
      notes: [
        "Wan 2.1 img2vid. conditioning_image is the anchor frame; motion.guiding_frame_noise / motion.start_frame_guidance shape the temporal coherence.",
      ]),
  ],

  // Wan 2.1 i2v fine-tunes — ship with modifier='inpainting' (engine uses
  // the channel-concat i2v path for these variants). User-facing op is still
  // img2vid; the modifier is engine-side plumbing.
  .init(behaviorClass: .wan21, modifier: .inpainting): [
    .img2vid: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.videoExtras,
        merging(["loras": F.loras, "upscaler": F.upscaler], img2vidExtras),
        ["flow_match": F.flowMatch]),
      silentDrops: videoDrops + [
        Drops.clipSkipOnNonClip,
        SilentDrop(field: "controlnets", reason: "Video archs don't engage ControlNet"),
        SilentDrop(field: "reference_image", reason: "Use conditioning_image for the anchor frame"),
        SilentDrop(field: "depth_image", reason: "Not used"),
      ],
      notes: [
        "Wan 2.1 (or 2.2 a14b) i2v fine-tune. conditioning_image is the anchor frame; modifier='inpainting' is engine-side plumbing (channel-concat path), exposed to the API as the standard img2vid op.",
      ]),
  ],

  // Wan 2.2 (5B)
  .init(behaviorClass: .wan22, modifier: .none): [
    .txt2vid: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.videoExtras,
        ["loras": F.loras, "upscaler": F.upscaler],
        ["flow_match": F.flowMatch]),
      silentDrops: videoDrops + [
        Drops.clipSkipOnNonClip,
        SilentDrop(field: "controlnets", reason: "Video archs don't engage ControlNet"),
        SilentDrop(field: "reference_image", reason: "Not used for txt2vid"),
        SilentDrop(field: "depth_image", reason: "Not used for txt2vid"),
      ],
      notes: ["Wan 2.2 txt2vid. Flow matching."]),
    .img2vid: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.videoExtras,
        merging(["loras": F.loras, "upscaler": F.upscaler], img2vidExtras),
        ["flow_match": F.flowMatch]),
      silentDrops: videoDrops + [
        Drops.clipSkipOnNonClip,
        SilentDrop(field: "controlnets", reason: "Video archs don't engage ControlNet"),
        SilentDrop(field: "reference_image", reason: "Use conditioning_image for the anchor frame"),
        SilentDrop(field: "depth_image", reason: "Not used"),
      ],
      notes: ["Wan 2.2 img2vid."]),
  ],

  // LTX-2 (ltx2 + ltx2.3)
  .init(behaviorClass: .ltx2, modifier: .none): [
    .txt2vid: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.videoExtras,
        ["loras": F.loras, "upscaler": F.upscaler],
        ["flow_match": F.flowMatch]),
      silentDrops: videoDrops + [
        Drops.clipSkipOnNonClip,
        SilentDrop(field: "controlnets", reason: "Video archs don't engage ControlNet"),
        SilentDrop(field: "reference_image", reason: "Not used for txt2vid"),
        SilentDrop(field: "depth_image", reason: "Not used for txt2vid"),
      ],
      notes: ["LTX-2 (ltx2 / ltx2.3) txt2vid. Flow matching; Gemma3 text encoder."]),
    .img2vid: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.videoExtras,
        merging(["loras": F.loras, "upscaler": F.upscaler], img2vidExtras),
        ["flow_match": F.flowMatch]),
      silentDrops: videoDrops + [
        Drops.clipSkipOnNonClip,
        SilentDrop(field: "controlnets", reason: "Video archs don't engage ControlNet"),
        SilentDrop(field: "reference_image", reason: "Use conditioning_image for the anchor frame"),
        SilentDrop(field: "depth_image", reason: "Not used"),
      ],
      notes: ["LTX-2 img2vid."]),
  ],

  // LTX-2 kontext fine-tunes — image-conditioned video gen with kontext-flavor
  // first-frame conditioning (see LocalImageGenerator.swift:3346-3360). The
  // user-facing op is still img2vid; the modifier is engine-side plumbing.
  .init(behaviorClass: .ltx2, modifier: .kontext): [
    .img2vid: ContractTemplate(
      accepted: merging(
        FieldBundle.universalImageScalars,
        FieldBundle.videoExtras,
        merging(["loras": F.loras, "upscaler": F.upscaler], img2vidExtras),
        ["flow_match": F.flowMatch]),
      silentDrops: videoDrops + [
        Drops.clipSkipOnNonClip,
        SilentDrop(field: "controlnets", reason: "Video archs don't engage ControlNet"),
        SilentDrop(field: "reference_image", reason: "Use conditioning_image for the first-frame reference"),
        SilentDrop(field: "depth_image", reason: "Not used"),
      ],
      notes: [
        "LTX-2 Kontext variant (modifier='kontext'). conditioning_image is encoded as the first-frame reference using the kontext path; the rest of the video is generated from prompt. User-facing op is img2vid; the kontext modifier is engine-side plumbing.",
      ]),
  ],
]

// MARK: - SeedVR2 template helper

private func seedVR2RestoreTemplate(modifierNote: String?) -> ContractTemplate {
  var notes: [String] = [
    "Image super-resolution / restoration. Engine config: single-frame mode (frames=1) by default; output dimensions derived from image_in.",
    "Empirical sweet spot: 5-8 steps with the TCD sampler; cfg_scale near 1.0.",
    "batch_size is capped to 1 engine-side (per LocalImageGenerator dispatch guards).",
  ]
  if let modifierNote { notes.append(modifierNote) }
  return ContractTemplate(
    accepted: [
      "prompt": F.promptOpt,
      "negative_prompt": F.negativePrompt,
      "base_model_id": F.baseModelId,
      "steps": F.steps,
      "cfg_scale": F.cfgScale,
      "seed": F.seed,
      "seed_mode": F.seedMode,
      "sampler": F.sampler,
      "output_format": F.outputFormat,
      "batch_size": F.batchSize(max: 1),
      "batch_count": F.batchCount,
      "run_id": F.runId,
      "image_in": F.restoreImageIn,
      "loras": F.loras,
      "extensions": F.extensions,
    ],
    silentDrops: [
      SilentDrop(field: "width", reason: "Output dimensions derived from image_in"),
      SilentDrop(field: "height", reason: "Output dimensions derived from image_in"),
      SilentDrop(field: "clip_skip", reason: "SeedVR2 doesn't use a CLIP-style text encoder"),
      SilentDrop(field: "sharpness", reason: "Not consumed by the SeedVR2 restoration path"),
      Drops.sdxlConditioning,
      Drops.textEncodersMulti,
      Drops.cascade,
      Drops.imagePrior,
      Drops.flowMatchOnDdpmEdm,
      Drops.preserveOrigAfterInpaintOnNonInpainting,
      SilentDrop(field: "controlnets", reason: "No ControlNet support for SeedVR2"),
      SilentDrop(field: "reference_image", reason: "Restore consumes image_in only"),
      SilentDrop(field: "depth_image", reason: "Restore consumes image_in only"),
      SilentDrop(field: "hires_fix", reason: "Restore is the upscale; hires_fix would chain unexpectedly"),
      SilentDrop(field: "refiner", reason: "No refiner path for SeedVR2"),
      SilentDrop(field: "upscaler", reason: "Restore is the upscale; upscaler chain redundant"),
      SilentDrop(field: "tiling", reason: "Engine-side tiling is implicit; explicit tiling ignored"),
      Drops.teaCacheOnNonTransformer,
      Drops.causalInferenceOnNonVideo,
      Drops.guidanceEmbedOnNonGuidanceEmbed,
    ],
    notes: notes)
}
