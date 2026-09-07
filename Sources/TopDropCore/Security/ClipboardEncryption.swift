import CryptoKit
import Foundation
import OSLog
import Security

public protocol ClipboardEncryptionKeyProviding: Sendable {
    func encryptionKey() async throws -> SymmetricKey
}

/// The small persistence seam used by `KeychainClipboardKeyProvider`.
///
/// Keeping this synchronous is intentional: calls execute inside the provider
/// actor without an actor-reentrancy point, so concurrent key requests cannot
/// race past the in-memory cache and cause duplicate Keychain reads.
package protocol ClipboardKeyDataStoring: Sendable {
    func readKeyData(service: String, account: String) throws -> Data?
    func insertKeyData(_ data: Data, service: String, account: String) throws -> ClipboardKeyDataInsertResult
}

package enum ClipboardKeyDataInsertResult: Sendable {
    case inserted
    case duplicate
}

/// Stores the clipboard encryption key as a non-synchronizing generic-password
/// item in the current user's login Keychain.
package struct SystemKeychainClipboardKeyDataStore: ClipboardKeyDataStoring {
    package init() {}

    package func readKeyData(service: String, account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ClipboardSubsystemError.keychain(status: status)
        }
        return data
    }

    package func insertKeyData(
        _ data: Data,
        service: String,
        account: String
    ) throws -> ClipboardKeyDataInsertResult {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { return .duplicate }
        guard status == errSecSuccess else {
            throw ClipboardSubsystemError.keychain(status: status)
        }
        return .inserted
    }
}

/// A non-synchronizing Keychain item keeps clipboard history local to this Mac.
public actor KeychainClipboardKeyProvider: ClipboardEncryptionKeyProviding {
    private let service: String
    private let account: String
    private let keyDataStore: any ClipboardKeyDataStoring
    /// Intentionally lives only for this provider's process lifetime. The key
    /// remains persisted in Keychain, but normal archive loads and saves no
    /// longer ask Keychain to authorize every operation.
    private var cachedKey: SymmetricKey?

    public init(
        service: String = "com.personal.TopDrop.clipboard",
        account: String = "archive-key-v1"
    ) {
        self.service = service
        self.account = account
        self.keyDataStore = SystemKeychainClipboardKeyDataStore()
    }

    package init(
        service: String,
        account: String,
        keyDataStore: any ClipboardKeyDataStoring
    ) {
        self.service = service
        self.account = account
        self.keyDataStore = keyDataStore
    }

    public func encryptionKey() async throws -> SymmetricKey {
        if let cachedKey {
            return cachedKey
        }

        if let existing = try keyDataStore.readKeyData(service: service, account: account) {
            let key = try makeKey(from: existing)
            cachedKey = key
            return key
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard randomStatus == errSecSuccess else {
            throw ClipboardSubsystemError.keychain(status: randomStatus)
        }
        let data = Data(bytes)

        let key: SymmetricKey
        switch try keyDataStore.insertKeyData(data, service: service, account: account) {
        case .inserted:
            key = SymmetricKey(data: data)
        case .duplicate:
            guard let racedData = try keyDataStore.readKeyData(service: service, account: account) else {
                throw ClipboardSubsystemError.keychain(status: errSecDuplicateItem)
            }
            key = try makeKey(from: racedData)
        }
        cachedKey = key
        return key
    }

    private func makeKey(from data: Data) throws -> SymmetricKey {
        guard data.count == 32 else { throw ClipboardSubsystemError.invalidArchive }
        return SymmetricKey(data: data)
    }
}

public enum ClipboardCryptoBox {
    private static let header = Data("TOPDROP-CLIPBOARD-v1\0".utf8)

    public static func seal(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw ClipboardSubsystemError.encryptionFailed }
        return header + combined
    }

    public static func open(_ ciphertext: Data, using key: SymmetricKey) throws -> Data {
        guard ciphertext.starts(with: header) else { throw ClipboardSubsystemError.invalidArchive }
        do {
            let combined = ciphertext.dropFirst(header.count)
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key)
        } catch let error as ClipboardSubsystemError {
            throw error
        } catch {
            throw ClipboardSubsystemError.encryptionFailed
        }
    }
}

public protocol ClipboardHistoryPersisting: Sendable {
    func load() async throws -> [ClipboardItem]
    func save(_ items: [ClipboardItem]) async throws
}

public actor EncryptedClipboardHistoryStore: ClipboardHistoryPersisting {
    private struct Archive: Codable {
        let version: Int
        let items: [ClipboardItem]
    }

    private let fileURL: URL
    private let keyProvider: any ClipboardEncryptionKeyProviding
    private let logger = Logger(subsystem: TopDropCore.bundleIdentifier, category: "ClipboardStore")

    public init(fileURL: URL, keyProvider: any ClipboardEncryptionKeyProviding = KeychainClipboardKeyProvider()) {
        self.fileURL = fileURL
        self.keyProvider = keyProvider
    }

    public func load() async throws -> [ClipboardItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let encrypted = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let key = try await keyProvider.encryptionKey()
        let plaintext = try ClipboardCryptoBox.open(encrypted, using: key)
        let archive: Archive
        do {
            archive = try JSONDecoder().decode(Archive.self, from: plaintext)
        } catch {
            throw ClipboardSubsystemError.invalidArchive
        }
        guard archive.version == 1 else { throw ClipboardSubsystemError.invalidArchive }
        let items = Array(archive.items.prefix(TopDropCore.maximumClipboardItemCount))
        logger.info("Encrypted clipboard archive loaded; itemCount=\(items.count, privacy: .public)")
        return items
    }

    public func save(_ items: [ClipboardItem]) async throws {
        let bounded = Array(items.prefix(TopDropCore.maximumClipboardItemCount))
        let plaintext = try JSONEncoder().encode(Archive(version: 1, items: bounded))
        let key = try await keyProvider.encryptionKey()
        let encrypted = try ClipboardCryptoBox.seal(plaintext, using: key)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // The archive is already authenticated AES-GCM ciphertext. macOS can
        // make `.completeFileProtectionUnlessOpen` unreadable immediately when
        // the login keybag changes state, so use deterministic owner-only file
        // permissions for this desktop utility instead.
        try encrypted.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fileURL.path
        )
        logger.info("Encrypted clipboard archive saved; itemCount=\(bounded.count, privacy: .public)")
    }
}

public actor MemoryClipboardHistoryStore: ClipboardHistoryPersisting {
    private var items: [ClipboardItem]

    public init(items: [ClipboardItem] = []) {
        self.items = Array(items.prefix(TopDropCore.maximumClipboardItemCount))
    }

    public func load() async throws -> [ClipboardItem] { items }

    public func save(_ items: [ClipboardItem]) async throws {
        self.items = Array(items.prefix(TopDropCore.maximumClipboardItemCount))
    }
}
