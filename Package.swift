// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mnemosyne",
    defaultLocalization: "ru",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Mnemosyne", targets: ["Mnemosyne"]),
    ],
    dependencies: [
        // Диаризация и VAD на CoreML (Neural Engine), без токена Hugging Face.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3"),
    ],
    targets: [
        // Логика без UI: захват звука, устройства, хранение. Покрывается тестами.
        .target(
            name: "MnemosyneCore",
            path: "Sources/MnemosyneCore"
        ),
        // Обработка записи: VAD, диаризация (FluidAudio), транскрибация (mlx-whisper).
        .target(
            name: "MnemosynePipeline",
            dependencies: ["MnemosyneCore", .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/MnemosynePipeline"
        ),
        // Приложение: строка меню, поповер, хоткей.
        .executableTarget(
            name: "Mnemosyne",
            dependencies: ["MnemosyneCore", "MnemosynePipeline"],
            path: "Sources/Mnemosyne"
        ),
        .testTarget(
            name: "MnemosyneCoreTests",
            dependencies: ["MnemosyneCore"],
            path: "Tests/MnemosyneCoreTests"
        ),
    ]
)
