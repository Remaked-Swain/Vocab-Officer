import Foundation
import Security

struct VocabBootstrapToken: Codable, Equatable {
    let claimID: UUID
    let requestID: UUID

    var id: UUID { requestID }

    init(claimID: UUID = UUID(), requestID: UUID = UUID()) {
        self.claimID = claimID
        self.requestID = requestID
    }

    init(id: UUID) {
        claimID = id
        requestID = id
    }
}

protocol VocabBootstrapCredentialDataStoring {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

enum VocabBootstrapCredentialStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain:
            "iCloud 최초 동기화 보안 정보를 처리하지 못했습니다. Mac 로그인 상태를 확인한 뒤 다시 시도하세요."
        }
    }
}

struct VocabBootstrapCredentialKeychainStore: VocabBootstrapCredentialDataStoring {
    private let service = "com.swainyun.Vocab.bootstrap"
    private let account = "claim-credential-v1"

    func load() throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw VocabBootstrapCredentialStoreError.keychain(status)
        }
        return data
    }

    func save(_ data: Data) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw VocabBootstrapCredentialStoreError.keychain(addStatus)
            }
        } else if status != errSecSuccess {
            throw VocabBootstrapCredentialStoreError.keychain(status)
        }
    }
}

enum VocabBootstrapTokenStore {
    private static let claimKey = "vocabPendingBootstrapClaimID"
    private static let requestKey = "vocabPendingBootstrapRequestID"
    private static let migrationKey = "vocabBootstrapCredentialMigrationV1"

    struct Credential: Codable, Equatable {
        var token: VocabBootstrapToken
        var originDeviceID: String
        var request: VocabBootstrapClaimRequest?
    }

    static func load(
        defaults: UserDefaults = .standard,
        dataStore: any VocabBootstrapCredentialDataStoring = VocabBootstrapCredentialKeychainStore()
    ) throws -> Credential? {
        if let data = try dataStore.load() {
            return try JSONDecoder.vocabSnapshotDecoder.decode(Credential.self, from: data)
        }
        guard !defaults.bool(forKey: migrationKey) else { return nil }
        guard let token = legacyToken(defaults: defaults) else {
            defaults.set(true, forKey: migrationKey)
            return nil
        }
        let credential = Credential(token: token, originDeviceID: VocabDeviceIdentity.current, request: nil)
        try save(credential, to: dataStore)
        defaults.removeObject(forKey: claimKey)
        defaults.removeObject(forKey: requestKey)
        defaults.set(true, forKey: migrationKey)
        return credential
    }

    static func createAndPersist(
        defaults: UserDefaults = .standard,
        dataStore: any VocabBootstrapCredentialDataStoring = VocabBootstrapCredentialKeychainStore()
    ) throws -> Credential {
        if let existing = try load(defaults: defaults, dataStore: dataStore) { return existing }
        let credential = Credential(
            token: VocabBootstrapToken(),
            originDeviceID: VocabDeviceIdentity.current,
            request: nil
        )
        try save(credential, to: dataStore)
        return credential
    }

    static func persist(
        _ request: VocabBootstrapClaimRequest,
        dataStore: any VocabBootstrapCredentialDataStoring = VocabBootstrapCredentialKeychainStore()
    ) throws {
        try save(Credential(
            token: VocabBootstrapToken(claimID: request.claimID, requestID: request.requestID),
            originDeviceID: request.ownerDeviceID,
            request: request
        ), to: dataStore)
    }

    private static func legacyToken(defaults: UserDefaults) -> VocabBootstrapToken? {
        guard let claimRaw = defaults.string(forKey: claimKey),
              let requestRaw = defaults.string(forKey: requestKey),
              let claimID = UUID(uuidString: claimRaw),
              let requestID = UUID(uuidString: requestRaw) else { return nil }
        return VocabBootstrapToken(claimID: claimID, requestID: requestID)
    }

    private static func save(
        _ credential: Credential,
        to dataStore: any VocabBootstrapCredentialDataStoring
    ) throws {
        let data = try JSONEncoder.vocabSnapshotEncoder.encode(credential)
        try dataStore.save(data)
    }
}
