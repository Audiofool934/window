import AppKit
import CryptoKit
import Foundation
import Network
import Security

public enum SpotifyError: Error, CustomStringConvertible {
    case notConnected
    case denied(String)
    case badResponse(Int)
    case timedOut

    public var description: String {
        switch self {
        case .notConnected: return "Not connected to a Spotify account."
        case .denied(let reason): return "Spotify did not authorize Window (\(reason))."
        case .badResponse(let code): return "Spotify answered with status \(code)."
        case .timedOut: return "No answer came back from the browser."
        }
    }
}

/// A Spotify account reached through the Web API with the user's own developer app.
/// Authorization Code with PKCE needs no client secret; the redirect lands on a loopback port that only exists during sign-in.
public final class SpotifyAccount {
    public static let scopes = "user-read-currently-playing user-read-playback-state"
    /// What to register in the developer dashboard. Spotify accepts the port chosen at sign-in for loopback addresses.
    public static let registeredRedirect = "http://127.0.0.1/callback"

    public let clientID: String
    private let session: URLSession
    private var accessToken: String?
    private var expiry = Date.distantPast

    public init(clientID: String, session: URLSession = .shared) {
        self.clientID = clientID
        self.session = session
    }

    public var isConnected: Bool { Keychain.read(account: clientID) != nil }

    public func disconnect() {
        Keychain.delete(account: clientID)
        accessToken = nil
        expiry = .distantPast
    }

    /// Opens the browser to Spotify's consent page and waits for it to come back.
    public func connect() async throws {
        let verifier = PKCE.verifier()
        let state = PKCE.verifier(length: 24)
        let receiver = try LoopbackReceiver()
        defer { receiver.stop() }
        let port = try await receiver.start()
        let redirect = "http://127.0.0.1:\(port)/callback"
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier))
        ]
        let consent = components.url!
        await MainActor.run { _ = NSWorkspace.shared.open(consent) }
        let query = try await receiver.callback(timeout: 300)
        if let error = query["error"] { throw SpotifyError.denied(error) }
        guard query["state"] == state, let code = query["code"] else { throw SpotifyError.denied("state mismatch") }
        try await requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect,
            "client_id": clientID,
            "code_verifier": verifier
        ])
    }

    func validAccessToken() async throws -> String {
        if let accessToken, Date() < expiry.addingTimeInterval(-60) { return accessToken }
        guard let refresh = Keychain.read(account: clientID) else { throw SpotifyError.notConnected }
        try await requestToken(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
        guard let accessToken else { throw SpotifyError.notConnected }
        return accessToken
    }

    func invalidateAccessToken() {
        accessToken = nil
    }

    private func requestToken(_ form: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(form).data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // A refresh token that no longer works will not start working again.
            if status == 400, form["grant_type"] == "refresh_token" { Keychain.delete(account: clientID) }
            throw SpotifyError.badResponse(status)
        }
        struct Token: Decodable {
            var access_token: String
            var expires_in: Double
            var refresh_token: String?
        }
        let token = try JSONDecoder().decode(Token.self, from: data)
        accessToken = token.access_token
        expiry = Date().addingTimeInterval(token.expires_in)
        if let refresh = token.refresh_token { Keychain.write(refresh, account: clientID) }
    }

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }
}

/// Polls the account's currently-playing endpoint, more often near the end of a track so changes land promptly.
public final class SpotifyWebSource: NowPlayingSource {
    public var onChange: ((NowPlaying?) -> Void)?
    /// Called when the account stops working, for example after access is revoked.
    public var onFailure: ((Error) -> Void)?
    private let account: SpotifyAccount
    private let session: URLSession
    private var timer: Timer?
    private var running = false
    private var inFlight = false
    private var last: NowPlaying?
    private var lastPoll = Date.distantPast

    public init(account: SpotifyAccount, session: URLSession = .shared) {
        self.account = account
        self.session = session
    }

    public func start() {
        guard !running else { return }
        running = true
        poll()
    }

    public func stop() {
        running = false
        timer?.invalidate()
        timer = nil
    }

    public func refresh() {
        guard running, Date().timeIntervalSince(lastPoll) > 1 else { return }
        poll()
    }

    private func schedule(after seconds: TimeInterval) {
        timer?.invalidate()
        guard running else { return }
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard running, !inFlight else { return }
        inFlight = true
        lastPoll = Date()
        timer?.invalidate()
        Task { [weak self] in
            guard let self else { return }
            let next: TimeInterval
            do {
                let (state, remaining) = try await self.fetch()
                await MainActor.run { self.publish(state) }
                if let state, state.isPlaying {
                    next = min(4, max((remaining ?? 4) + 0.6, 1))
                } else {
                    next = 8
                }
            } catch SpotifyError.notConnected {
                await MainActor.run { self.onFailure?(SpotifyError.notConnected) }
                next = 60
            } catch let SpotifyError.badResponse(code) where code == 429 {
                next = 30
            } catch {
                next = 15
            }
            await MainActor.run {
                self.inFlight = false
                self.schedule(after: next)
            }
        }
    }

    private func publish(_ state: NowPlaying?) {
        guard state != last else { return }
        last = state
        onChange?(state)
    }

    /// The current item, and seconds left in it.
    private func fetch() async throws -> (NowPlaying?, TimeInterval?) {
        var attempt = 0
        while true {
            let token = try await account.validAccessToken()
            var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing?additional_types=track,episode")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: return Self.parse(data)
            case 204: return (nil, nil)
            case 401 where attempt == 0:
                account.invalidateAccessToken()
                attempt += 1
            default: throw SpotifyError.badResponse(status)
            }
        }
    }

    static func parse(_ data: Data) -> (NowPlaying?, TimeInterval?) {
        struct Image: Decodable { var url: String; var width: Int? }
        struct Named: Decodable { var name: String }
        struct Album: Decodable { var name: String; var images: [Image]? }
        struct Show: Decodable { var name: String; var images: [Image]? }
        struct Item: Decodable {
            var uri: String
            var name: String
            var duration_ms: Double?
            var artists: [Named]?
            var album: Album?
            var show: Show?
            var images: [Image]?
        }
        struct Playing: Decodable {
            var is_playing: Bool
            var progress_ms: Double?
            var currently_playing_type: String?
            var item: Item?
        }
        guard let playing = try? JSONDecoder().decode(Playing.self, from: data), let item = playing.item else { return (nil, nil) }
        let images = item.album?.images ?? item.images ?? item.show?.images ?? []
        let best = images.max { ($0.width ?? 0) < ($1.width ?? 0) }
        let artist = item.artists?.map(\.name).joined(separator: ", ") ?? item.show?.name ?? ""
        let state = NowPlaying(uri: item.uri, title: item.name, artist: artist, album: item.album?.name ?? item.show?.name ?? "",
                               artworkURL: best.flatMap { URL(string: $0.url) }, isPlaying: playing.is_playing)
        var remaining: TimeInterval?
        if let duration = item.duration_ms, let progress = playing.progress_ms {
            remaining = max(duration - progress, 0) / 1000
        }
        return (state, remaining)
    }
}

enum PKCE {
    static func verifier(length: Int = 64) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Listens on 127.0.0.1 for the one redirect that ends sign-in, then goes away.
/// State is confined to its own serial queue.
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "blog.audiofool.window.loopback")
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var finished = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<UInt16, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.claim() { ready.resume(returning: self?.listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if once.claim() { ready.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    func callback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { (waiting: CheckedContinuation<[String: String], Error>) in
            queue.async {
                self.continuation = waiting
                self.queue.asyncAfter(deadline: .now() + timeout) { self.finish(.failure(SpotifyError.timedOut)) }
            }
        }
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            guard let components = URLComponents(string: "http://127.0.0.1\(target)"), components.path == "/callback" else {
                self.respond(connection, status: "404 Not Found", body: "")
                return
            }
            var query: [String: String] = [:]
            for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
            let ok = query["code"] != nil
            let body = """
            <!doctype html><meta charset="utf-8"><title>Window</title>
            <body style="font: 15px -apple-system, sans-serif; margin: 22vh auto; max-width: 28em; color: #333">
            <p>\(ok ? "Spotify is connected to Window. You can close this tab." : "Spotify did not connect. You can close this tab and try again from the menu.")</p>
            """
            self.respond(connection, status: "200 OK", body: body)
            self.finish(.success(query))
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard !finished, let continuation else { return }
        finished = true
        self.continuation = nil
        continuation.resume(with: result)
    }
}

/// Lets exactly one caller through, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

/// The refresh token, kept in the login keychain.
enum Keychain {
    static let service = "blog.audiofool.window.spotify"

    static func read(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        delete(account: account)
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
                                   kSecAttrLabel as String: "Window: Spotify"]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
