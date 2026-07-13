// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "Rewind",
	platforms: [.macOS(.v13)],
	products: [
		.executable(name: "Rewind", targets: ["Rewind"]),
	],
	dependencies: [
		.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.2"),
	],
	targets: [
		.executableTarget(
			name: "Rewind",
			dependencies: [
				.product(name: "Sparkle", package: "Sparkle"),
			],
			path: "Sources/Rewind",
			linkerSettings: [
				.linkedLibrary("sqlite3"),
				.unsafeFlags([
					"-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
					"-Xlinker", "-rpath", "-Xlinker", "@executable_path",
				]),
			]
		),
		.testTarget(
			name: "RewindTests",
			dependencies: ["Rewind"],
			path: "Tests/RewindTests"
		),
	]
)
