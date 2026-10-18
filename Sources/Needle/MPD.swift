import Foundation
import Network

// The wire: one TCP connection speaking MPD's line protocol (https://mpd.readthedocs.io/en/latest/protocol.html).
// A reply is "key: value" lines ending in "OK", or a single "ACK [code@index] {command} message" line.
// A binary chunk (cover art) arrives as "binary: <n>", then n raw bytes, then a newline.

enum MPDError: LocalizedError {
    case unreachable(String)
    case closed
    case timeout
    case malformed(String)
    case ack(code: Int, command: String, message: String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let why): return why
        case .closed: return "The server closed the connection"
        case .timeout: return "The server stopped answering"
        case .malformed(let line): return "Unexpected reply from the server: \(line)"
        case .ack(_, let command, let message): return command.isEmpty ? message : "\(command): \(message)"
        }
    }

    /// True when the socket failed rather than MPD refusing a command — worth a reconnect.
    var isConnectionLevel: Bool {
        if case .ack = self { return false }
        return true
    }
}

typealias MPDPair = (key: String, value: String)

/// One command's reply: its key/value lines in order, and the binary chunk if it sent one.
struct MPDReply {
    var pairs: [MPDPair] = []
    var binary: Data?

    subscript(key: String) -> String? { pairs.first { $0.key == key }?.value }

    func all(_ key: String) -> [String] { pairs.filter { $0.key == key }.map(\.value) }

    /// Splits a flat listing (playlistinfo, search, listplaylists) into one record per item;
    /// each record starts at a `starter` key ("file", "playlist").
    func records(startingAt starter: String) -> [[MPDPair]] {
        var out: [[MPDPair]] = []
        for p in pairs {
            if p.key == starter { out.append([p]) } else if !out.isEmpty { out[out.count - 1].append(p) }
        }
        return out
    }
}

enum MPD {
    /// One argument, quoted the way the protocol wants: in double quotes, with \ and " escaped.
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Runs a closure exactly once, from whichever callback gets there first (ready, failed, or the deadline).
final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

/// One connection to MPD. The protocol is strict request/reply with no tags, so commands go out
/// one at a time: `exchange` queues callers in order even though an actor is re-entrant across awaits.
actor MPDConnection {
    nonisolated let host: String
    nonisolated let port: UInt16
    private(set) var protocolVersion = ""

    private var connection: NWConnection?
    private var buffer: [UInt8] = []
    private var cursor = 0
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var generation = 0
    private var timedOut = false
    private var lastUsed = Date()
    private let queue = DispatchQueue(label: "needle.mpd.socket")

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    var isOpen: Bool { connection != nil }

    /// Seconds since the last command finished. MPD hangs up on clients silent for its connection_timeout
    /// (60 s by default), so MPDClient opens a fresh connection rather than reuse one silent for 30 s.
    var idleFor: TimeInterval { Date().timeIntervalSince(lastUsed) }

    func open(timeout: TimeInterval = 4) async throws {
        close()
        generation += 1
        guard let nwPort = NWEndpoint.Port(rawValue: port), port > 0 else {
            throw MPDError.unreachable("Port \(port) is not a valid port")
        }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = max(1, Int(timeout.rounded(.up)))
        tcp.noDelay = true
        // Keepalive lets a long `idle` notice a server that vanished (Mac asleep, moved networks).
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 20
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: nil, tcp: tcp))
        connection = conn
        buffer = []
        cursor = 0
        let host = self.host
        let queue = self.queue
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let once = Once()
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        once.run { cont.resume() }
                    case .waiting(let e), .failed(let e):
                        once.run { cont.resume(throwing: MPDError.unreachable(MPDConnection.describe(e, host: host))) }
                    case .cancelled:
                        once.run { cont.resume(throwing: MPDError.closed) }
                    default:
                        break
                    }
                }
                conn.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) {
                    once.run { cont.resume(throwing: MPDError.unreachable("\(host) did not answer within \(Int(timeout)) seconds")) }
                }
            }
        } catch {
            close()
            throw error
        }
        // From here on, a socket the server closes (or that dies) marks this connection closed at once,
        // so the next command opens a fresh one instead of failing on the dead one.
        let gen = generation
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .waiting, .cancelled:
                Task { await self?.died(gen) }
            default:
                break
            }
        }
        let greeting = try await withDeadline(timeout) { try await self.readLine() }
        guard greeting.hasPrefix("OK MPD ") else {
            close()
            throw MPDError.malformed(greeting)
        }
        protocolVersion = String(greeting.dropFirst("OK MPD ".count))
        lastUsed = Date()
    }

    private func died(_ gen: Int) {
        guard gen == generation, connection != nil else { return }
        close()
    }

    func close() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        buffer = []
        cursor = 0
    }

    /// Sends one command; returns its reply. `timeout: .infinity` is for `idle`, which waits for news.
    func run(_ command: String, timeout: TimeInterval = 6) async throws -> MPDReply {
        try await exchange([command], timeout: timeout)[0]
    }

    /// Sends several commands as one command list — one round trip, one reply per command.
    /// MPD stops at the first command it refuses and answers ACK for the whole list.
    func runList(_ commands: [String], timeout: TimeInterval = 6) async throws -> [MPDReply] {
        guard !commands.isEmpty else { return [] }
        return try await exchange(commands, timeout: timeout)
    }

    // MARK: exchange

    private func exchange(_ commands: [String], timeout: TimeInterval) async throws -> [MPDReply] {
        await acquire()
        defer { release() }
        // A socket macOS already knows is dead may never call back: don't send on one, start afresh.
        guard let conn = connection, case .ready = conn.state else {
            close()
            throw MPDError.closed
        }
        let list = commands.count > 1
        let text = list
            ? "command_list_ok_begin\n" + commands.joined(separator: "\n") + "\ncommand_list_end\n"
            : commands[0] + "\n"
        let replies = try await withDeadline(timeout) {
            try await self.write(text)
            return try await self.readReplies(list: list)
        }
        lastUsed = Date()
        return replies
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    /// Runs `body`; if it is still waiting after `seconds`, the socket is torn down so the read fails.
    private func withDeadline<T>(_ seconds: TimeInterval, _ body: () async throws -> T) async throws -> T {
        guard seconds.isFinite else { return try await body() }
        let gen = generation
        timedOut = false
        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.expire(gen)
        }
        defer { watchdog.cancel() }
        do {
            return try await body()
        } catch {
            if timedOut { throw MPDError.timeout }
            throw error
        }
    }

    private func expire(_ gen: Int) {
        guard gen == generation, connection != nil else { return }
        timedOut = true
        close()
    }

    private func readReplies(list: Bool) async throws -> [MPDReply] {
        var replies: [MPDReply] = []
        var current = MPDReply()
        while true {
            let line = try await readLine()
            if line == "OK" {
                if !list { replies.append(current) }
                return replies
            }
            if line == "list_OK" {
                replies.append(current)
                current = MPDReply()
                continue
            }
            if line.hasPrefix("ACK ") { throw MPDConnection.parseAck(line) }
            guard let sep = line.range(of: ": ") ?? line.range(of: ":") else { continue }
            let key = String(line[..<sep.lowerBound])
            let value = String(line[sep.upperBound...])
            if key == "binary", let n = Int(value) {
                current.binary = try await readBytes(n)
                _ = try await readBytes(1)   // the newline that closes the chunk
            } else {
                current.pairs.append((key, value))
            }
        }
    }

    // MARK: socket

    private func write(_ text: String) async throws {
        guard let conn = connection else { throw MPDError.closed }
        let host = self.host
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: Data(text.utf8), completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: MPDConnection.wrap(error, host: host))
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func receiveMore() async throws {
        guard let conn = connection, case .ready = conn.state else { throw MPDError.closed }
        let host = self.host
        let chunk: Data = try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if let error {
                    cont.resume(throwing: MPDConnection.wrap(error, host: host))
                } else if isComplete {
                    cont.resume(throwing: MPDError.closed)
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
        guard connection != nil else { throw MPDError.closed }
        if cursor > 0 {
            buffer.removeFirst(cursor)
            cursor = 0
        }
        buffer.append(contentsOf: chunk)
    }

    private func readLine() async throws -> String {
        var scanFrom = cursor
        while true {
            if let nl = buffer[scanFrom...].firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[cursor..<nl], as: UTF8.self)
                cursor = nl + 1
                return line
            }
            let unread = buffer.count - cursor
            try await receiveMore()
            scanFrom = cursor + unread   // only look at the new bytes next time round
        }
    }

    private func readBytes(_ n: Int) async throws -> Data {
        while buffer.count - cursor < n { try await receiveMore() }
        let out = Data(buffer[cursor..<(cursor + n)])
        cursor += n
        return out
    }

    // MARK: messages

    /// "ACK [50@0] {albumart} No file exists" → code 50, command "albumart", message "No file exists".
    static func parseAck(_ line: String) -> MPDError {
        var code = 0
        var command = ""
        var message = String(line.dropFirst(4))
        if let lb = line.firstIndex(of: "["), let at = line.firstIndex(of: "@"), lb < at {
            code = Int(line[line.index(after: lb)..<at]) ?? 0
        }
        if let lc = line.firstIndex(of: "{"), let rc = line.firstIndex(of: "}"), lc < rc {
            command = String(line[line.index(after: lc)..<rc])
            message = String(line[line.index(after: rc)...]).trimmingCharacters(in: .whitespaces)
        }
        return .ack(code: code, command: command, message: message)
    }

    /// On an established socket these mean MPD hung up while we were quiet (its connection_timeout) —
    /// "Socket is not connected" is how macOS reported it on 18 Oct — or that the socket died under a
    /// pending read (ECANCELED, from `died`): `.closed`, which MPDClient retries once on a fresh
    /// connection. A deadline's own cancel is reported as `.timeout` before this is consulted.
    static func wrap(_ error: NWError, host: String) -> MPDError {
        if case .posix(let code) = error, [.ENOTCONN, .ECONNRESET, .EPIPE, .ECONNABORTED, .ENETRESET, .ECANCELED].contains(code) { return .closed }
        return .unreachable(describe(error, host: host))
    }

    static func describe(_ error: NWError, host: String) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return "\(host) refused the connection — is MPD running?"
            case .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN: return "\(host) is not reachable from this network"
            case .ETIMEDOUT: return "\(host) did not answer"
            case .ECANCELED: return "The connection was closed"
            case .ECONNRESET, .EPIPE: return "\(host) dropped the connection"
            case .ENETDOWN:
                // What macOS answers when the Local Network privacy switch is off for this app.
                return "No network — or macOS is blocking Needle's local network access (System Settings › Privacy & Security › Local Network)"
            default: return "\(host): \(String(cString: strerror(code.rawValue)))"
            }
        case .dns(let code):
            // kDNSServiceErr_PolicyDenied: macOS's Local Network privacy switch is off for this app.
            if code == -65570 { return "macOS is blocking local network access for Needle (System Settings › Privacy & Security › Local Network)" }
            return "Cannot find \(host) (DNS error \(code))"
        default:
            return "\(host): \(error.debugDescription)"
        }
    }
}
