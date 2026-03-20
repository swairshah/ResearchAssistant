// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ResearchReader",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "ResearchReader", targets: ["ResearchReader"]),
    ],
    targets: [
        .target(
            name: "COnnxRuntime",
            path: "Sources/COnnxRuntime",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "ResearchReader",
            dependencies: ["COnnxRuntime"],
            path: "Sources/ResearchReader",
            linkerSettings: [
                .unsafeFlags([
                    "-L", "../LocalTalker/vendor/onnxruntime/lib",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Users/swair/work/projects/LocalTalker/vendor/onnxruntime/lib",
                ]),
                .linkedLibrary("onnxruntime"),
                .linkedFramework("AppKit"),
                .linkedFramework("PDFKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate"),
            ]
        ),
    ]
)
