import Foundation
import CryptoKit
import Security
import Network

// Only the app's own OAuth registrations are stored here. No Codex/ChatGPT
// credential files are read or shared.
enum OAuthSecurity {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw VoiceError("Could not create a secure sign-in request.") }
        return base64url(Data(bytes))
    }
    static func base64url(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func decode(_ value: String) -> Data? {
        let s = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: s + String(repeating: "=", count: (4 - s.count % 4) % 4))
    }
    static func challenge(_ verifier: String) -> String { base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(fields.sorted { $0.key < $1.key }.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
    }
    static func callback(_ target: String, state: String, clientID: String?) throws -> (code: String, clientID: String) {
        guard let url = URLComponents(string: "http://127.0.0.1" + target), url.path == "/auth/callback" else { throw VoiceError("Invalid sign-in callback path.") }
        var fields: [String: String] = [:]
        for item in url.queryItems ?? [] {
            guard fields[item.name] == nil else { throw VoiceError("Duplicate sign-in callback parameter.") }
            fields[item.name] = item.value ?? ""
        }
        guard fields["state"] == state else { throw VoiceError("Sign-in state did not match. Please try again.") }
        if let issuer = fields["iss"], issuer != Self.issuer { throw VoiceError("Unexpected sign-in issuer.") }
        if fields["error"] != nil { throw VoiceError("ChatGPT sign-in was not authorised. You can try again or use the local model.") }
        let issued = fields["client_id"] ?? clientID ?? ""
        guard !issued.isEmpty, issued != "dynamic_agent_client", clientID == nil || clientID == issued,
              let code = fields["code"], !code.isEmpty else { throw VoiceError("ChatGPT registration was incomplete or did not match the selected account.") }
        return (code, issued)
    }
    static func verifyIDToken(_ token: String, jwks: Data, clientID: String, nonce: String?, subject: String? = nil, now: Date = Date()) throws -> [String: Any] {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 3, let headerData = decode(parts[0]), let payload = decode(parts[1]), let signature = decode(parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any], header["alg"] as? String == "RS256",
              let kid = header["kid"] as? String,
              let set = try JSONSerialization.jsonObject(with: jwks) as? [String: Any], let keys = set["keys"] as? [[String: Any]],
              let key = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }),
              key["use"] == nil || key["use"] as? String == "sig",
              key["alg"] == nil || key["alg"] as? String == "RS256",
              let n = key["n"] as? String, let e = key["e"] as? String,
              let modulus = decode(n), let exponent = decode(e) else { throw VoiceError("ChatGPT returned an invalid identity token.") }
        let der = tagged(0x30, tagged(0x02, integer(modulus)) + tagged(0x02, integer(exponent)))
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, &error),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, &error) else { throw VoiceError("ChatGPT identity signature could not be verified.") }
        guard let claims = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw VoiceError("Invalid identity claims.") }
        try validateClaims(claims, clientID: clientID, nonce: nonce, subject: subject, now: now)
        return claims
    }
    static func validateClaims(_ claims: [String: Any], clientID: String, nonce: String?, subject: String?, now: Date) throws {
        let audience = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard claims["iss"] as? String == issuer, audience.contains(clientID),
              audience.count <= 1 || claims["azp"] as? String == clientID,
              let exp = claims["exp"] as? Double, exp > now.timeIntervalSince1970,
              let sub = claims["sub"] as? String, !sub.isEmpty,
              subject == nil || subject == sub,
              nonce == nil || claims["nonce"] as? String == nonce,
              (claims["nbf"] as? Double ?? 0) <= now.timeIntervalSince1970 + 60 else { throw VoiceError("ChatGPT identity validation failed. Please sign in again.") }
    }
    private static func integer(_ value: Data) -> Data { value.first.map { $0 >= 0x80 } == true ? Data([0]) + value : value }
    private static func tagged(_ tag: UInt8, _ data: Data) -> Data {
        var count = data.count; var length: [UInt8] = []
        if count < 128 { length = [UInt8(count)] } else {
            while count > 0 { length.insert(UInt8(count & 255), at: 0); count >>= 8 }
            length.insert(0x80 | UInt8(length.count), at: 0)
        }
        return Data([tag] + length) + data
    }
}

enum OAuthVault {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.xiuke.realtime-voice-llm-local.chatgpt", kSecAttrAccount as String: "registrations-v1"] }
    static func read() throws -> Data? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw VoiceError("Could not read ChatGPT credentials from Keychain (\(status)).") }
        return result as? Data
    }
    static func write(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw VoiceError("Could not save ChatGPT credentials to Keychain.") }; return
        }
        guard status == errSecSuccess else { throw VoiceError("Could not update ChatGPT credentials in Keychain.") }
    }
}

// State is confined to a private serial queue; only the loopback interface is
// bound. It exists solely for the pending OAuth transaction, for at most 5 min.
final class OAuthLoopback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "LocalVoice.OAuthCallback")
    private var listener: NWListener?
    private var ready: CheckedContinuation<UInt16, Error>?
    private var pending: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private var connections: [NWConnection] = []
    let state: String
    init(state: String) { self.state = state }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.ready = continuation
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.stateUpdateHandler = { status in
                        switch status {
                        case .ready:
                            if let port = listener.port { self.ready?.resume(returning: port.rawValue); self.ready = nil }
                        case .failed(let error): self.finish(.failure(error))
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { connection in
                        guard self.connections.count < 8 else { connection.cancel(); return }
                        self.connections.append(connection); connection.start(queue: self.queue)
                        self.receive(connection, accumulated: Data())
                    }
                    listener.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + 300) { self.finish(.failure(VoiceError("ChatGPT sign-in timed out. Please try again."))) }
                } catch { self.finish(.failure(error)) }
            }
        }
    }
    func value() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result { continuation.resume(with: result) } else { self.pending = continuation }
                }
            }
        } onCancel: { self.cancel() }
    }
    func cancel() { queue.async { self.finish(.failure(CancellationError())) } }
    private func finish(_ result: Result<String, Error>) {
        guard self.result == nil else { return }
        self.result = result
        if let ready { ready.resume(throwing: VoiceError("Could not start the sign-in callback listener.")); self.ready = nil }
        pending?.resume(with: result); pending = nil
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        for connection in connections { connection.cancel() }; connections = []
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, done, error in
            var buffer = accumulated; if let data { buffer.append(data) }
            guard buffer.count <= 16384, error == nil else { self.close(connection); return }
            guard let header = String(data: buffer, encoding: .utf8), header.contains("\r\n\r\n") else {
                if done { self.close(connection) } else { self.receive(connection, accumulated: buffer) }; return
            }
            let request = header.components(separatedBy: "\r\n").first?.split(separator: " ").map(String.init) ?? []
            guard request.count == 3, request[0] == "GET", request[1].hasPrefix("/auth/callback?"),
                  let components = URLComponents(string: "http://127.0.0.1" + request[1]),
                  components.queryItems?.filter({ $0.name == "state" }).count == 1,
                  components.queryItems?.first(where: { $0.name == "state" })?.value == self.state else { self.reply(connection, text: "Invalid callback.", status: "400 Bad Request", target: nil); return }
            self.reply(connection, text: "Return to Local Voice to finish connecting your ChatGPT account. You may close this tab.", status: "200 OK", target: request[1])
        }
    }
    private func close(_ connection: NWConnection) { connection.cancel(); connections.removeAll { $0 === connection } }
    private func reply(_ connection: NWConnection, text: String, status: String, target: String?) {
        let body = Data(text.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in
            self.close(connection)
            if let target { self.finish(.success(target)) }
        })
    }
}
