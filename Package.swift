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
    // Local sibling clone, patched to expose ModelZoo as a library product
    // and to add MediaGenerationPipeline.Result.encodedData(type:).
    // See scripts/setup-dev.sh and scripts/dtc-products.patch.
    // The clone must be at ../draw-things-community at SHA 9f3f04b7a0729a50384caf58179bed592044d64d.
    .package(path: "../draw-things-community"),
    // s4nnc, pinned to the exact revision draw-things-community resolves, so
    // SwiftPM unifies the two on one version. We depend on it directly only
    // to `import NNC` for the one `DynamicGraph.flags` call in DHTServer.swift
    // — that is what lets the patch above stay additive-only (no need to
    // `@_exported import NNC` inside the engine source).
    .package(
      url: "https://github.com/liuliu/s4nnc.git",
      revision: "594050126b5cee0dd18488dc05a57947df912878"),
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
