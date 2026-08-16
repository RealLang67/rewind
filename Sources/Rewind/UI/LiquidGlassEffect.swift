import SwiftUI

extension View {
	@ViewBuilder
	func liquidGlassCard(cornerRadius: CGFloat = 12) -> some View {
		let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
		if #available(macOS 26.0, *) {
			glassEffect(.regular, in: shape)
		} else {
			background(shape.fill(.ultraThinMaterial))
				.overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
		}
	}

	@ViewBuilder
	func liquidGlassButtonStyle(prominent: Bool = false) -> some View {
		if #available(macOS 26.0, *) {
			if prominent {
				buttonStyle(.glassProminent)
			} else {
				buttonStyle(.glass)
			}
		} else {
			if prominent {
				buttonStyle(.borderedProminent)
			} else {
				buttonStyle(.bordered)
			}
		}
	}
}
