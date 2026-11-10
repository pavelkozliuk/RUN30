import Foundation
import Combine
import Security
import Network

struct CloudEnvelope: Codable, Equatable {
    var data: JSONValue
    var deleted: Bool
}
struct CloudRow: Codable {
    var itemKey: String
    var value: CloudEnvelope
    var updatedAt: String
    enum CodingKeys: String, CodingKey { case itemKey = "item_key", value, updatedAt = "updated_at" }
}
struct PendingItem: Codable {
    var value: JSONValue
    var deleted: Bool
    var base: String?
    var nonce: String = UUID().uuidString
}
struct LocalCache: Codable {
    var userId: String? = nil
    var records: [String: RunRecord] = [:]
    var ready: [String: Bool] = [:]
    var startDate: String = TrainingPlan.nextMondayISO
    var pending: [String: PendingItem] = [:]
    var seen: [String: String] = [:]
}
struct SessionCredentials: Codable {
    var accessToken: String
    var refreshToken: String
    var userId: String
    var email: String
    var expiresAt: Date
}
struct AuthResponse: Decodable {
    struct AuthUser: Decodable { let id: String; let email: String? }
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let user: AuthUser?
}
struct UploadRow: Encodable {
    var userId: String
    var itemKey: String
    var value: CloudEnvelope
    enum CodingKeys: String, CodingKey { case userId = "user_id", itemKey = "item_key", value }
}

private enum SecureSession {
    static let service = "app.run30.native.supabase"
    static func load() -> SessionCredentials? {
        let q: [String: Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:service, kSecReturnData as String:true,
            kSecMatchLimit as String:kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let bytes = result as? Data else { return nil }
        return try? JSONDecoder().decode(SessionCredentials.self, from: bytes)
    }
    static func save(_ credentials: SessionCredentials?) {
        let q: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service]
        SecItemDelete(q as CFDictionary)
        guard let credentials, let bytes = try? JSONEncoder().encode(credentials) else { return }
        var new = q
        new[kSecValueData as String] = bytes
        new[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(new as CFDictionary, nil)
    }
}

@MainActor
final class CloudStore: ObservableObject {
    @Published private(set) var records: [String: RunRecord] = [:]
    @Published private(set) var ready: [String: Bool] = [:]
    @Published private(set) var startDate: String = TrainingPlan.nextMondayISO
    @Published private(set) var busy = false
    @Published private(set) var status = "Настрой подключение к облаку"
    @Published private(set) var errorText: String? = nil
    @Published private(set) var conflicts: [String: CloudRow] = [:]
    @Published private(set) var pendingCount = 0
    @Published private(set) var loggedInEmail: String? = nil
    @Published private(set) var projectURL = ""
    @Published private(set) var publishableKey = ""

    private var cache = LocalCache()
    private var credentials: SessionCredentials?
    private let session = URLSession(configuration: .default)
    private let connectionMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "app.run30.network")
    private let cacheURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appendingPathComponent("run30-native-data.json")
        if let bytes = try? Data(contentsOf: cacheURL), let c = try? JSONDecoder().decode(LocalCache.self, from: bytes) { cache = c }
        credentials = SecureSession.load()
        projectURL = UserDefaults.standard.string(forKey: "run30.projectURL") ?? ""
        publishableKey = UserDefaults.standard.string(forKey: "run30.publishableKey") ?? ""
        loggedInEmail = credentials?.email
        publish()
        if credentials != nil { status = "Нажми «Синхронизировать»" }
        connectionMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            DispatchQueue.main.async { [weak self] in
                Task { await self?.sync() }
            }
        }
        connectionMonitor.start(queue: monitorQueue)
    }

    deinit { connectionMonitor.cancel() }

    func configure(url: String, key: String) throws {
        let raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: raw), u.scheme == "https", u.user == nil,
              u.password == nil, u.query == nil, u.fragment == nil,
              let host = u.host?.lowercased(), host.hasSuffix(".supabase.co"),
              !host.dropLast(".supabase.co".count).isEmpty else {
            throw NSError(domain:"RUN30", code:1, userInfo:[NSLocalizedDescriptionKey:"Укажи HTTPS Project URL вида https://xxxxx.supabase.co"])
        }
        guard (k.hasPrefix("sb_publishable_") && k.count > 20) || isLegacyAnonJWT(k) else {
            throw NSError(domain:"RUN30",code:2,userInfo:[NSLocalizedDescriptionKey:"Нужен только Publishable key или публичный anon JWT, не secret/service_role."])
        }
        // Switching projects must never upload cached workouts to a different project/account.
        if !projectURL.isEmpty && projectURL != u.originString {
            signOut()
            cache = LocalCache()
            persist()
        }
        projectURL = u.originString
        publishableKey = k
        UserDefaults.standard.set(projectURL, forKey:"run30.projectURL")
        UserDefaults.standard.set(publishableKey, forKey:"run30.publishableKey")
        status = "Проект настроен. Войди в аккаунт RUN30."
    }

    private func isLegacyAnonJWT(_ value: String) -> Bool {
        let parts = value.split(separator:".")
        guard parts.count == 3 else { return false }
        var payload = String(parts[1]).replacingOccurrences(of:"-", with:"+").replacingOccurrences(of:"_", with:"/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let bytes = Data(base64Encoded: payload),
              let o = try? JSONSerialization.jsonObject(with: bytes) as? [String:Any] else { return false }
        return o["role"] as? String == "anon"
    }

    func login(email: String, password: String) async {
        guard !busy else { return }
        busy = true; errorText = nil
        defer { busy = false }
        do {
            let payload = try JSONSerialization.data(withJSONObject:["email":email,"password":password])
            let bytes = try await request("/auth/v1/token?grant_type=password", method:"POST", body:payload, authorized:false)
            let reply = try authDecoder().decode(AuthResponse.self, from: bytes)
            guard let user = reply.user else { throw CloudError.message("Supabase не вернул ID пользователя") }
            if cache.userId != nil && cache.userId != user.id { cache = LocalCache(); publish() }
            credentials = SessionCredentials(accessToken:reply.accessToken, refreshToken:reply.refreshToken,
                userId:user.id, email:user.email ?? email, expiresAt:Date().addingTimeInterval(TimeInterval(reply.expiresIn)))
            cache.userId = user.id
            SecureSession.save(credentials)
            loggedInEmail = credentials?.email
            persist()
            status = "Вход выполнен"
            busy = false
            await sync()
        } catch { errorText = error.localizedDescription; status = "Ошибка входа" }
    }

    func signOut() {
        credentials = nil
        SecureSession.save(nil)
        loggedInEmail = nil
        conflicts = [:]
        // Keep local data but prevent sync to a new account until that account is checked.
        status = "Выход выполнен. Локальные записи сохранены."
    }

    func updateStartDate(_ iso: String) {
        guard iso.range(of:"^\\d{4}-\\d{2}-\\d{2}$", options:.regularExpression) != nil else { return }
        startDate = iso
        enqueue("startDate", value:.string(iso))
    }
    func updateReady(week: Int, index: Int, value: Bool) {
        guard (1...26).contains(week), (0...4).contains(index) else { return }
        let k = "ready:\(week)-\(index)"
        ready["\(week)-\(index)"] = value
        enqueue(k, value:.bool(value))
    }
    func saveRecord(_ record: RunRecord, week: Int, day: Int) {
        guard (1...26).contains(week), (0...3).contains(day) else { return }
        let k = TrainingPlan.key(week,day)
        records[k] = record
        if let data = try? JSONValue.wrap(record) { enqueue("record:"+k, value:data) }
    }
    func deleteRecord(week: Int, day: Int) {
        let k = TrainingPlan.key(week, day)
        records.removeValue(forKey:k)
        enqueue("record:"+k, value:.null, deleted:true)
    }

    private func enqueue(_ key: String, value: JSONValue, deleted: Bool = false) {
        cache.pending[key] = PendingItem(value:value, deleted:deleted, base:cache.seen[key])
        conflicts.removeValue(forKey:key)
        persist()
        status = "Сохранено локально · ожидает отправки"
    }

    func sync() async {
        guard !busy, credentials != nil, !projectURL.isEmpty, !publishableKey.isEmpty else { return }
        busy = true; errorText = nil; status = "Синхронизация…"
        defer { busy = false }
        do {
            let uid = credentials!.userId
            let urlPath = "/rest/v1/run30_sync?select=item_key,value,updated_at&user_id=eq.\(uid)&limit=1000"
            let response = try await request(urlPath)
            let rows = try JSONDecoder().decode([CloudRow].self, from: response)
            let remote = Dictionary(rows.map { ($0.itemKey,$0) }, uniquingKeysWith: { _,new in new })
            var changesApplied = false
            conflicts = [:]
            for row in rows {
                if let pending = cache.pending[row.itemKey] {
                    if pending.value == row.value.data && pending.deleted == row.value.deleted {
                        cache.pending.removeValue(forKey:row.itemKey)
                        cache.seen[row.itemKey] = row.updatedAt
                    } else if pending.base != row.updatedAt {
                        conflicts[row.itemKey] = row
                    }
                } else {
                    apply(row)
                    cache.seen[row.itemKey] = row.updatedAt
                    changesApplied = true
                }
            }
            // Initialize a *missing* cloud start date, never overwrite an existing one.
            if remote["startDate"] == nil && cache.pending["startDate"] == nil {
                cache.pending["startDate"] = PendingItem(value:.string(startDate), deleted:false, base:nil)
            }
            for (key,pending) in cache.pending where pending.base != nil && remote[key] == nil {
                conflicts[key] = CloudRow(itemKey:key, value:CloudEnvelope(data:.null,deleted:true), updatedAt:"")
            }
            let send = cache.pending.filter { conflicts[$0.key] == nil }
            if !send.isEmpty {
                let body = send.map { item in
                    UploadRow(userId:uid, itemKey:item.key, value:CloudEnvelope(data:item.value.value,deleted:item.value.deleted))
                }
                let bytes = try JSONEncoder().encode(body)
                let reply = try await request("/rest/v1/run30_sync?on_conflict=user_id,item_key",
                                              method:"POST", body:bytes, prefer:"resolution=merge-duplicates,return=representation")
                let updated = try JSONDecoder().decode([CloudRow].self, from:reply)
                for row in updated {
                    if let sent = send[row.itemKey], cache.pending[row.itemKey]?.nonce == sent.nonce {
                        cache.pending.removeValue(forKey:row.itemKey)
                    }
                    cache.seen[row.itemKey] = row.updatedAt
                }
            }
            if changesApplied { publish() }
            persist()
            status = conflicts.isEmpty ? "В облаке ✓" : "Конфликты: \(conflicts.count)"
        } catch {
            errorText = error.localizedDescription
            status = "Офлайн / ошибка — данные сохранены локально"
            persist()
        }
    }

    func resolveConflict(key: String, useLocal: Bool) async {
        guard let r = conflicts[key] else { return }
        if useLocal {
            if cache.pending[key] != nil { cache.pending[key]?.base = r.updatedAt.isEmpty ? nil : r.updatedAt }
        } else {
            apply(r)
            cache.pending.removeValue(forKey:key)
            if !r.updatedAt.isEmpty { cache.seen[key] = r.updatedAt } else { cache.seen.removeValue(forKey:key) }
        }
        conflicts.removeValue(forKey:key)
        persist()
        if useLocal { await sync() }
    }

    private func apply(_ row: CloudRow) {
        let key = row.itemKey
        let value = row.value
        if key == "startDate", !value.deleted, case .string(let date) = value.data {
            cache.startDate = date
        } else if key.hasPrefix("record:") {
            let recordKey = String(key.dropFirst("record:".count))
            let parts = recordKey.split(separator:"-").compactMap { Int($0) }
            guard parts.count == 2, (1...26).contains(parts[0]), (0...3).contains(parts[1]) else { return }
            if value.deleted || value.data == .null { cache.records.removeValue(forKey:recordKey) }
            else if let record = value.data.unwrap(RunRecord.self) { cache.records[recordKey] = record }
        } else if key.hasPrefix("ready:") {
            let item = String(key.dropFirst("ready:".count))
            let parts = item.split(separator:"-").compactMap { Int($0) }
            guard parts.count == 2, (1...26).contains(parts[0]), (0...4).contains(parts[1]) else { return }
            if value.deleted { cache.ready[item] = false }
            else if case .bool(let b) = value.data { cache.ready[item] = b }
        }
    }

    private func publish() {
        records = cache.records
        ready = cache.ready
        startDate = cache.startDate
        pendingCount = cache.pending.count
    }

    private func persist() {
        cache.records = records
        cache.ready = ready
        cache.startDate = startDate
        pendingCount = cache.pending.count
        if let bytes = try? JSONEncoder().encode(cache) { try? bytes.write(to: cacheURL, options:.atomic) }
    }

    private func authDecoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private func renewTokenIfNeeded() async throws {
        guard let sessionData = credentials else { throw CloudError.message("Войди в аккаунт") }
        if sessionData.expiresAt.timeIntervalSinceNow > 60 { return }
        let bytes = try JSONSerialization.data(withJSONObject:["refresh_token":sessionData.refreshToken])
        let result = try await request("/auth/v1/token?grant_type=refresh_token", method:"POST",body:bytes,authorized:false)
        let decoded = try authDecoder().decode(AuthResponse.self, from:result)
        credentials = SessionCredentials(accessToken:decoded.accessToken, refreshToken:decoded.refreshToken,
            userId:sessionData.userId,email:sessionData.email,
            expiresAt:Date().addingTimeInterval(TimeInterval(decoded.expiresIn)))
        SecureSession.save(credentials)
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil,
                         authorized: Bool = true, prefer: String? = nil) async throws -> Data {
        guard let url = URL(string:projectURL+path), !projectURL.isEmpty else { throw CloudError.message("Не настроен Project URL") }
        if authorized { try await renewTokenIfNeeded() }
        var request = URLRequest(url:url)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 25
        request.setValue(publishableKey, forHTTPHeaderField:"apikey")
        request.setValue("application/json", forHTTPHeaderField:"Content-Type")
        if authorized, let access = credentials?.accessToken { request.setValue("Bearer "+access, forHTTPHeaderField:"Authorization") }
        if let prefer { request.setValue(prefer,forHTTPHeaderField:"Prefer") }
        let (data,response) = try await session.data(for:request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.message("Нет ответа сервера") }
        if !(200...299).contains(http.statusCode) {
            let err = String(data:data, encoding:.utf8) ?? "Ошибка сервера"
            throw CloudError.message("HTTP \(http.statusCode): \(String(err.prefix(260)))")
        }
        return data
    }
}

private enum CloudError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

private extension URL {
    var originString: String {
        guard let scheme, let host else { return absoluteString }
        return "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
    }
}
