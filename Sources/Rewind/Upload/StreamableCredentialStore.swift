import Foundation
import Security

/// A validated Streamable sign-in. The password is intentionally kept out of
/// error descriptions and is persisted only as Keychain secret data.
struct StreamableCredentials: Equatable, Sendable {
	enum ValidationError: LocalizedError, Equatable, Sendable {
		case emailRequired
		case invalidEmail
		case passwordRequired

		var errorDescription: String? {
			switch self {
			case .emailRequired:
				return "Enter the email address for your Streamable account."
			case .invalidEmail:
				return "Enter a valid email address for your Streamable account."
			case .passwordRequired:
				return "Enter the password for your Streamable account."
			}
		}
	}

	let email: String
	let password: String

	init(email: String, password: String) throws {
		self.email = try Self.normalizedEmail(email)
		guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			throw ValidationError.passwordRequired
		}
		self.password = password
	}

	fileprivate static func normalizedEmail(_ email: String) throws -> String {
		let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !normalized.isEmpty else {
			throw ValidationError.emailRequired
		}

		let parts = normalized.split(separator: "@", omittingEmptySubsequences: false)
		guard parts.count == 2,
		      !parts[0].isEmpty,
		      !parts[1].isEmpty,
		      !normalized.contains(":"),
		      !normalized.contains(where: { $0.isWhitespace })
		else {
			throw ValidationError.invalidEmail
		}
		return normalized
	}
}

enum StreamableCredentialStoreError: LocalizedError, Equatable, Sendable {
	enum Operation: String, Equatable, Sendable {
		case save = "save"
		case read = "read"
		case delete = "delete"
	}

	case invalidStoredCredentials
	case keychain(operation: Operation, status: OSStatus)

	var errorDescription: String? {
		switch self {
		case .invalidStoredCredentials:
			return "The Streamable credentials in Keychain are damaged. Save them again."
		case let .keychain(operation, status):
			let action: String
			switch operation {
			case .save: action = "save"
			case .read: action = "read"
			case .delete: action = "delete"
			}

			let systemMessage = SecCopyErrorMessageString(status, nil) as String?
			let detail = systemMessage.map { " \($0)" } ?? ""
			return "Couldn't \(action) Streamable credentials in Keychain.\(detail) (OSStatus \(status))"
		}
	}
}

protocol StreamableCredentialStoring: Sendable {
	func save(_ credentials: StreamableCredentials) async throws
	func load() async throws -> StreamableCredentials?
	func accountEmail() async throws -> String?
	func delete() async throws
}

/// Persists the single Streamable account used for cloud uploads.
///
/// This deliberately uses the regular generic-password Keychain without an
/// access group or `kSecUseDataProtectionKeychain`, so development and ad-hoc
/// signed builds can use it too.
actor StreamableCredentialStore: StreamableCredentialStoring {
	static let shared = StreamableCredentialStore()

	private let service: String

	init(service: String = "com.rewind.app.streamable-upload") {
		self.service = service
	}

	func save(_ credentials: StreamableCredentials) throws {
		guard let passwordData = credentials.password.data(using: .utf8) else {
			// Swift strings normally always encode as UTF-8, but keep a safe failure
			// path in case that invariant ever changes.
			throw StreamableCredentialStoreError.invalidStoredCredentials
		}

		let query = baseQuery()
		let values: [String: Any] = [
			kSecAttrAccount as String: credentials.email,
			kSecValueData as String: passwordData,
		]
		let updateStatus = SecItemUpdate(query as CFDictionary, values as CFDictionary)

		switch updateStatus {
		case errSecSuccess:
			return
		case errSecItemNotFound:
			var item = query
			item[kSecAttrAccount as String] = credentials.email
			item[kSecValueData as String] = passwordData
			item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

			let addStatus = SecItemAdd(item as CFDictionary, nil)
			if addStatus == errSecSuccess {
				return
			}

			// Another process may have inserted the item between the update and
			// add. In that case, update the item that won the race.
			if addStatus == errSecDuplicateItem {
				let retryStatus = SecItemUpdate(query as CFDictionary, values as CFDictionary)
				guard retryStatus == errSecSuccess else {
					throw keychainError(operation: .save, status: retryStatus)
				}
				return
			}
			throw keychainError(operation: .save, status: addStatus)
		default:
			throw keychainError(operation: .save, status: updateStatus)
		}
	}

	func load() throws -> StreamableCredentials? {
		var query = baseQuery()
		query[kSecReturnAttributes as String] = true
		query[kSecReturnData as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne

		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		if status == errSecItemNotFound {
			return nil
		}
		guard status == errSecSuccess else {
			throw keychainError(operation: .read, status: status)
		}

		guard let attributes = result as? NSDictionary,
		      let email = attributes[kSecAttrAccount] as? String,
		      let passwordData = attributes[kSecValueData] as? Data,
		      let password = String(data: passwordData, encoding: .utf8)
		else {
			throw StreamableCredentialStoreError.invalidStoredCredentials
		}

		do {
			return try StreamableCredentials(email: email, password: password)
		} catch {
			throw StreamableCredentialStoreError.invalidStoredCredentials
		}
	}

	/// Returns the saved account without requesting the Keychain secret data.
	func accountEmail() throws -> String? {
		var query = baseQuery()
		query[kSecReturnAttributes as String] = true
		query[kSecMatchLimit as String] = kSecMatchLimitOne

		var result: CFTypeRef?
		let status = SecItemCopyMatching(query as CFDictionary, &result)
		if status == errSecItemNotFound {
			return nil
		}
		guard status == errSecSuccess else {
			throw keychainError(operation: .read, status: status)
		}
		guard let attributes = result as? NSDictionary,
		      let email = attributes[kSecAttrAccount] as? String
		else {
			throw StreamableCredentialStoreError.invalidStoredCredentials
		}

		do {
			return try StreamableCredentials.normalizedEmail(email)
		} catch {
			throw StreamableCredentialStoreError.invalidStoredCredentials
		}
	}

	func delete() throws {
		let status = SecItemDelete(baseQuery() as CFDictionary)
		guard status == errSecSuccess || status == errSecItemNotFound else {
			throw keychainError(operation: .delete, status: status)
		}
	}

	private func baseQuery() -> [String: Any] {
		[
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
		]
	}

	private func keychainError(
		operation: StreamableCredentialStoreError.Operation,
		status: OSStatus
	) -> StreamableCredentialStoreError {
		.keychain(operation: operation, status: status)
	}
}
