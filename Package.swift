// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MacTR",
    platforms: [
        .macOS("15.0")
    ],
    targets: [
        .systemLibrary(
            name: "CLibUSB",
            pkgConfig: "libusb-1.0",
            providers: [.brew(["libusb"])]
        ),
        .executableTarget(
            name: "MacTR",
            dependencies: [
                "CLibUSB",
            ],
            path: "Sources/MacTR",
            swiftSettings: [
                .unsafeFlags(["-I/opt/homebrew/include/libusb-1.0"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/lib"]),
                .linkedLibrary("usb-1.0"),
            ]
        ),
        .testTarget(name: "MacTRTests", dependencies: ["MacTR"]),
    ]
)
