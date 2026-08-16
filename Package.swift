// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "DrawHeadlessThings",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "dht-server", targets: ["dht-server"]),
    // Menu-bar agent app that wraps and supervises the dht-server process.
    // Assembled into DHTServer.app by scripts/make-app.sh.
    .executable(name: "dht-menubar", targets: ["dht-menubar"]),
  ],
  dependencies: [
    // Local clone, patched to expose ModelZoo and Downloader as library
    // products, to add MediaGenerationPipeline.Result.encodedData(type:), and
    // to add the _MediaGenerationKit.BaseModelImporter facade (local
    // base-model import).
    // See scripts/setup-dev.sh and scripts/dtc-products.patch.
    // The clone lives in-tree (gitignored) at .sdk-src/draw-things-community
    // at SHA bc3970cd24568d71e1d6a1543658fae54c136307.
    .package(path: ".sdk-src/draw-things-community"),
    // s4nnc, pinned to the same revision the (patched) draw-things-community
    // clone resolves, so SwiftPM unifies the two on one version. NOTE: this is
    // deliberately ONE deps-pin BEHIND the revision the engine itself pins
    // (349a4d9): that one pulls ccv 9008b47, whose last four Metal-kernel
    // commits break Z-Image Turbo denoising (blue square blobs on every
    // image). 5a84c2e is identical s4nnc source and pulls the last-known-good
    // ccv 0e61707 — dtc-products.patch applies the same re-pin inside the
    // clone. Revisit at the next engine bump. We depend on s4nnc directly only
    // to `import NNC` for the one `DynamicGraph.flags` call in DHTServer.swift
    // — that is what lets the patch above stay additive-only (no need to
    // `@_exported import NNC` inside the engine source).
    .package(
      url: "https://github.com/liuliu/s4nnc.git",
      revision: "5a84c2e98e44a569c9ab97bb1b281adfd171122d"),
    .package(
      url: "https://github.com/hummingbird-project/hummingbird.git",
      from: "2.23.0"
    ),
  ],
  targets: [
    .executableTarget(
      name: "dht-server",
      dependencies: [
        .product(name: "_MediaGenerationKit", package: "draw-things-community"),
        .product(name: "ModelZoo", package: "draw-things-community"),
        .product(name: "Downloader", package: "draw-things-community"),
        .product(name: "NNC", package: "s4nnc"),
        .product(name: "Hummingbird", package: "hummingbird"),
      ],
      path: "Sources/dht-server",
      resources: [
        .copy("Resources/swagger-ui"),
        .copy("Resources/openapi.yaml"),
      ]
    ),
    // Pure-SwiftUI menu-bar app. Deliberately depends on nothing: it does
    // not link the engine, it spawns the dht-server binary as a child.
    .executableTarget(
      name: "dht-menubar",
      path: "Sources/dht-menubar"
    ),
    .testTarget(
      name: "DHTServerTests",
      dependencies: [
        "dht-server",
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "HummingbirdTesting", package: "hummingbird"),
      ],
      path: "Tests/DHTServerTests"
    ),
  ]
)
