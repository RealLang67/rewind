import SwiftUI
import AVKit

struct HomeView: View {
	@ObservedObject var appState: AppState
	@State private var selectedClip: Clip?
	@State private var selectedCategory: String? = "all"

	let columns = [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 16)]

	var filteredClips: [Clip] {
		switch selectedCategory {
		case "favorites":
			return appState.clipLibrary.clips.filter { $0.isFavorite }
		default:
			return appState.clipLibrary.clips
		}
	}

	var body: some View {
		NavigationSplitView {
			List(selection: $selectedCategory) {
				NavigationLink(value: "all") {
					Label("All Clips", systemImage: "square.grid.2x2")
				}
				NavigationLink(value: "favorites") {
					Label("Favorites", systemImage: "heart")
				}
			}
			.navigationTitle("Library")
			.frame(minWidth: 150)
		} content: {
			ScrollView {
				if filteredClips.isEmpty {
					Text(selectedCategory == "favorites" ? "No favorites yet." : "No clips yet.")
						.foregroundStyle(.secondary)
						.padding()
				} else {
					LazyVGrid(columns: columns, spacing: 16) {
						ForEach(filteredClips) { clip in
							Button {
								selectedClip = clip
							} label: {
								ClipCard(clip: clip) {
									appState.clipLibrary.toggleFavorite(clip: clip)
								}
								.overlay(
									RoundedRectangle(cornerRadius: 8)
										.stroke(selectedClip?.id == clip.id ? Color.accentColor : Color.clear, lineWidth: 3)
								)
							}
							.buttonStyle(.plain)
						}
					}
					.padding()
				}
			}
			.navigationTitle(selectedCategory == "favorites" ? "Favorites" : "All Clips")
			.frame(minWidth: 300)
		} detail: {
			if let clip = selectedClip {
				TrimEditorView(clip: clip)
					.id(clip.id)
			} else {
				Text("Select a clip to view and edit.")
					.foregroundStyle(.secondary)
			}
		}
	}
}

struct ClipCard: View {
	let clip: Clip
	let onFavorite: () -> Void
	@State private var thumbnail: NSImage?

	var body: some View {
		VStack {
			ZStack(alignment: .bottomTrailing) {
				if let thumbnail = thumbnail {
					Image(nsImage: thumbnail)
						.resizable()
						.aspectRatio(contentMode: .fill)
						.frame(maxWidth: .infinity, maxHeight: .infinity)
						.clipped()
				} else {
					Color.black.opacity(0.1)
					Image(systemName: "video")
						.font(.largeTitle)
						.foregroundStyle(.secondary)
				}

				Button(action: onFavorite) {
					Image(systemName: clip.isFavorite ? "heart.fill" : "heart")
						.foregroundStyle(clip.isFavorite ? .red : .white)
						.padding(6)
						.background(Color.black.opacity(0.5))
						.clipShape(Circle())
				}
				.buttonStyle(.plain)
				.padding(8)
			}
			.aspectRatio(16/9, contentMode: .fit)
			.cornerRadius(8)

			Text(clip.createdAt, style: .date)
				.font(.caption)
		}
		.task(id: clip.id) {
			if thumbnail == nil {
				thumbnail = await generateThumbnail(for: clip.url)
			}
		}
	}

	private func generateThumbnail(for url: URL) async -> NSImage? {
		let asset = AVURLAsset(url: url)
		let generator = AVAssetImageGenerator(asset: asset)
		generator.appliesPreferredTrackTransform = true
		generator.maximumSize = CGSize(width: 480, height: 270)

		do {
			let cgImage = try await generator.image(at: .zero).image
			return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
		} catch {
			return nil
		}
	}
}

struct TrimEditorView: View {
	let clip: Clip
	@State private var playerView = AVPlayerView()
	@State private var isUploading = false

	var body: some View {
		VStack {
			NativeVideoPlayerWrapper(playerView: playerView)
		}
		.toolbar {
			ToolbarItem {
				Button("Trim") {
					if playerView.canBeginTrimming {
						playerView.beginTrimming { _ in
						}
					}
				}
			}
			ToolbarItem {
				Button(isUploading ? "Uploading..." : "Upload to Cloud") {
					uploadClip(clip.url)
				}
				.disabled(isUploading)
			}
		}
		.onAppear {
			playerView.player = AVPlayer(url: clip.url)
			playerView.showsSharingServiceButton = true
			playerView.showsFullScreenToggleButton = true
		}
	}

	private func uploadClip(_ url: URL) {
		isUploading = true
		Task {
			var request = URLRequest(url: URL(string: "https://litterbox.catbox.moe/resources/internals/api.php")!)
			request.httpMethod = "POST"
			let boundary = UUID().uuidString
			request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

			var data = Data()
			data.append("--\(boundary)\r\n".data(using: .utf8)!)
			data.append("Content-Disposition: form-data; name=\"reqtype\"\r\n\r\nfileupload\r\n".data(using: .utf8)!)
			data.append("--\(boundary)\r\n".data(using: .utf8)!)
			data.append("Content-Disposition: form-data; name=\"time\"\r\n\r\n72h\r\n".data(using: .utf8)!)
			data.append("--\(boundary)\r\n".data(using: .utf8)!)
			data.append("Content-Disposition: form-data; name=\"fileToUpload\"; filename=\"clip.mov\"\r\n".data(using: .utf8)!)
			data.append("Content-Type: video/quicktime\r\n\r\n".data(using: .utf8)!)
			data.append(try! Data(contentsOf: url))
			data.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

			do {
				let (resData, _) = try await URLSession.shared.upload(for: request, from: data)
				if let string = String(data: resData, encoding: .utf8) {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(string, forType: .string)
				}
			} catch {}
			isUploading = false
		}
	}
}

struct NativeVideoPlayerWrapper: NSViewRepresentable {
	let playerView: AVPlayerView

	func makeNSView(context: Context) -> AVPlayerView {
		playerView
	}

	func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}
