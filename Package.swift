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
		.package(url: "https://github.com/CocoaLumberjack/CocoaLumberjack", from: "3.8.0"),
	],
	targets: [
		.target(
			name: "RewindObjCSupport",
			path: "Sources/RewindObjCSupport"
		),
		.executableTarget(
			name: "Rewind",
			dependencies: [
				.product(name: "Sparkle", package: "Sparkle"),
				.product(name: "CocoaLumberjackSwift", package: "CocoaLumberjack"),
				"RewindObjCSupport",
			],
			path: "Sources/Rewind",
			linkerSettings: [
				.linkedLibrary("sqlite3"),
				.unsafeFlags([
					"-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
					"-Xlinker", "-rpath", "-Xlinker", "@executable_path",
					"-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "13.0", "-Xlinker", "26.0",
				]),
			]
		),
		.testTarget(
			name: "RewindTests",
			dependencies: ["Rewind"],
			path: "Tests/RewindTests",
			linkerSettings: [
				.unsafeFlags([
					"-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../..",
				]),
			]
		),
	]
)
