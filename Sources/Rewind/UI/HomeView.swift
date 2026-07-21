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
								ClipCard(clip: clip, onFavorite: {
									appState.clipLibrary.toggleFavorite(clip: clip)
								}, onDelete: {
									if selectedClip?.id == clip.id {
										selectedClip = nil
									}
									Task { await appState.clipLibrary.deleteClip(clip) }
									appState.clipWasDeleted(clip)
								})
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
				TrimEditorView(clip: clip, appState: appState)
					.id(clip.id)
			} else {
				Text("Select a clip to view and edit.")
					.foregroundStyle(.secondary)
			}
		}
		.onChange(of: appState.clipToOpen?.id) { _ in
			openRequestedClip()
		}
		.onAppear {
			openRequestedClip()
		}
	}

	private func openRequestedClip() {
		guard let clip = appState.clipToOpen else { return }
		selectedCategory = "all"
		selectedClip = clip
		appState.clipToOpen = nil
	}
}

struct ClipCard: View {
	let clip: Clip
	let onFavorite: () -> Void
	let onDelete: () -> Void
	@State private var thumbnail: NSImage?
	@State private var showDeleteConfirmation = false

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

				HStack(spacing: 6) {
					Button(action: onFavorite) {
						Image(systemName: clip.isFavorite ? "heart.fill" : "heart")
							.foregroundStyle(clip.isFavorite ? .red : .white)
							.padding(6)
							.background(Color.black.opacity(0.5))
							.clipShape(Circle())
					}
					.buttonStyle(.plain)

					Button {
						showDeleteConfirmation = true
					} label: {
						Image(systemName: "trash")
							.foregroundStyle(.white)
							.padding(6)
							.background(Color.black.opacity(0.5))
							.clipShape(Circle())
					}
					.buttonStyle(.plain)
				}
				.padding(8)
			}
			.aspectRatio(16/9, contentMode: .fit)
			.cornerRadius(8)

			Text(clip.createdAt, style: .date)
				.font(.caption)
		}
		.confirmationDialog("Delete this clip?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
			Button("Delete", role: .destructive, action: onDelete)
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("This permanently deletes the clip file from disk.")
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
	@ObservedObject var appState: AppState
	@State private var playerView = AVPlayerView()
	@State private var isUploading = false
	@State private var uploadSuccess = false
	@State private var uploadFailed = false
	@State private var isTrimming = false
	@AppStorage("litterboxExpiration") private var litterboxExpiration = "72h"
	@State private var uploadTask: URLSessionUploadTask?
	@State private var uploadProgressObs: NSKeyValueObservation?
	@State private var uploadProgress: Double = 0.0
	@State private var showProgressPopover = false

	var body: some View {
		VStack {
			NativeVideoPlayerWrapper(playerView: playerView)
		}
		.toolbar {
			ToolbarItem {
				Button("Trim") {
					if playerView.canBeginTrimming {
						playerView.beginTrimming { result in
							if result == .okButton {
								Task { @MainActor in
									saveTrimmedClip()
								}
							}
						}
					}
				}
				.disabled(isTrimming)
			}
			ToolbarItem {
				HStack {
					Menu {
						Button("Copy to clipboard") {
							copyClipToPasteboard(clip.url)
						}

						if appState.catboxEnabled {
							Button("Upload to Catbox.moe") {
								uploadClip(clip.url, provider: "catbox")
							}
						}
						
						if appState.litterboxEnabled {
							Menu("Upload to Litterbox") {
								Picker("Expiration", selection: $litterboxExpiration) {
									Text("1 Hour").tag("1h")
									Text("12 Hours").tag("12h")
									Text("24 Hours").tag("24h")
									Text("72 Hours").tag("72h")
								}
								Button("Upload") {
									uploadClip(clip.url, provider: "litterbox")
								}
							}
						}
						
					} label: {
						Label("Share", systemImage: "square.and.arrow.up")
					}
					.disabled(isUploading)
					.popover(isPresented: $showProgressPopover, arrowEdge: .bottom) {
						VStack(spacing: 16) {
							if uploadSuccess {
								Image(systemName: "checkmark.circle.fill")
									.resizable()
									.frame(width: 32, height: 32)
									.foregroundStyle(.green)
								Text("Upload Successful!")
									.font(.headline)
								Text("Link copied to clipboard.")
									.font(.subheadline)
									.foregroundStyle(.secondary)
							} else if uploadFailed {
								Image(systemName: "exclamationmark.triangle.fill")
									.resizable()
									.frame(width: 32, height: 32)
									.foregroundStyle(.orange)
								Text("Oops! Upload failed.")
									.font(.headline)
								Text("The clip couldn't be uploaded.")
									.font(.subheadline)
									.foregroundStyle(.secondary)
									.multilineTextAlignment(.center)
							} else {
								Text("Uploading...")
									.font(.headline)
								ProgressView(value: uploadProgress)
									.progressViewStyle(.linear)
								HStack {
									Text("\(Int(uploadProgress * 100))%")
										.font(.caption)
										.foregroundStyle(.secondary)
									Spacer()
									Button("Cancel") {
										uploadTask?.cancel()
										isUploading = false
										showProgressPopover = false
									}
								}
							}
						}
						.padding()
						.frame(width: 250)
					}
				}
			}
		}
		.onAppear {
			playerView.player = AVPlayer(url: clip.url)
			playerView.showsSharingServiceButton = true
			playerView.showsFullScreenToggleButton = true
		}
	}

	private func saveTrimmedClip() {
		guard let currentItem = playerView.player?.currentItem else { return }
		let asset = currentItem.asset
		
		var start = currentItem.reversePlaybackEndTime
		var end = currentItem.forwardPlaybackEndTime
		
		isTrimming = true
		Task {
			if !start.isValid { start = .zero }
			if !end.isValid { 
				end = (try? await asset.load(.duration)) ?? .zero
			}
			
			let timeRange = CMTimeRange(start: start, end: end)
			
			guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { 
				isTrimming = false
				return 
			}
			
			let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(clip.url.pathExtension)
			
			exportSession.outputURL = tempURL
			exportSession.outputFileType = clip.url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
			exportSession.timeRange = timeRange
			
			await exportSession.export()
			if exportSession.status == .completed {
				do {
					try? FileManager.default.removeItem(at: clip.url)
					try FileManager.default.moveItem(at: tempURL, to: clip.url)
				} catch {
					print("Error saving trimmed clip: \(error)")
				}
			}
			isTrimming = false
		}
	}

	private func copyClipToPasteboard(_ url: URL) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.writeObjects([url as NSURL])
	}

	private func showUploadFailure() {
		isUploading = false
		uploadSuccess = false
		uploadFailed = true
		Task {
			try? await Task.sleep(nanoseconds: 5_000_000_000)
			uploadFailed = false
			showProgressPopover = false
		}
	}

	private func uploadClip(_ url: URL, provider: String) {
		isUploading = true
		uploadSuccess = false
		uploadFailed = false
		showProgressPopover = true
		uploadProgress = 0.0
		
		Task {
			let apiURL = provider == "catbox" 
				? URL(string: "https://catbox.moe/user/api.php")!
				: URL(string: "https://litterbox.catbox.moe/resources/internals/api.php")!
				
			var request = URLRequest(url: apiURL)
			request.httpMethod = "POST"
			let boundary = UUID().uuidString
			request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

			var data = Data()
			data.append("--\(boundary)\r\n".data(using: .utf8)!)
			data.append("Content-Disposition: form-data; name=\"reqtype\"\r\n\r\nfileupload\r\n".data(using: .utf8)!)
			
			if provider == "litterbox" {
				data.append("--\(boundary)\r\n".data(using: .utf8)!)
				data.append("Content-Disposition: form-data; name=\"time\"\r\n\r\n\(litterboxExpiration)\r\n".data(using: .utf8)!)
			}
			
			let isMP4 = url.pathExtension.lowercased() == "mp4"
			let filename = isMP4 ? "clip.mp4" : "clip.mov"
			let contentType = isMP4 ? "video/mp4" : "video/quicktime"
			
			data.append("--\(boundary)\r\n".data(using: .utf8)!)
			data.append("Content-Disposition: form-data; name=\"fileToUpload\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
			data.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
			
			guard let fileData = try? Data(contentsOf: url) else {
				self.isUploading = false
				self.showProgressPopover = false
				return
			}
			data.append(fileData)
			data.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

			let task = URLSession.shared.uploadTask(with: request, from: data) { resData, response, error in
				DispatchQueue.main.async {
					self.uploadProgressObs?.invalidate()
					self.uploadProgressObs = nil
					
					if let error = error as NSError? {
						if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
							// user cancelled
							self.isUploading = false
							self.showProgressPopover = false
						} else {
							print("Upload error: \(error)")
							self.showUploadFailure()
						}
						return
					}

					let status = (response as? HTTPURLResponse)?.statusCode ?? 0
					let body = String(data: resData ?? Data(), encoding: .utf8)?
						.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
					let uploadedURL = body.hasPrefix("https://") ? URL(string: body) : nil

					if (200..<300).contains(status), let uploadedURL {
						NSPasteboard.general.clearContents()
						NSPasteboard.general.setString(uploadedURL.absoluteString, forType: .string)
						self.uploadSuccess = true
						Task {
							try? await Task.sleep(nanoseconds: 2_500_000_000)
							self.uploadSuccess = false
							self.isUploading = false
							self.showProgressPopover = false
						}
					} else {
						print("Upload failed. status: \(status), body: \(body)")
						self.showUploadFailure()
					}
				}
			}
			
			DispatchQueue.main.async {
				self.uploadTask = task
				self.uploadProgressObs = task.progress.observe(\.fractionCompleted) { progress, _ in
					DispatchQueue.main.async {
						self.uploadProgress = progress.fractionCompleted
					}
				}
				task.resume()
			}
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
