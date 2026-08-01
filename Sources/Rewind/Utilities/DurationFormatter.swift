import Foundation

extension Int {
	var formattedDuration: String {
		if self >= 60 && self % 60 == 0 {
			let minutes = self / 60
			return "\(minutes) minute\(minutes == 1 ? "" : "s")"
		} else if self > 60 {
			let minutes = Double(self) / 60.0
			let formatted = String(format: "%g", minutes)
			return "\(formatted) minutes"
		}
		return "\(self) seconds"
	}

	var formattedDurationShort: String {
		if self >= 60 && self % 60 == 0 {
			return "\(self / 60)m"
		} else if self > 60 {
			let minutes = Double(self) / 60.0
			let formatted = String(format: "%g", minutes)
			return "\(formatted)m"
		}
		return "\(self)s"
	}
}
