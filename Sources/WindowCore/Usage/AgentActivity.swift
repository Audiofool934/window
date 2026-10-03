import Darwin
import Foundation

/// Where Codex, Claude Code, and Grok Build leave their usage on this Mac.
/// Window reads these files and does not ask any service.
public struct AgentLocations: Equatable, Sendable {
    public var grokLog: URL
    public var codexDirectories: [URL]
    public var claudeProjects: URL

    public static func home(in directory: URL = FileManager.default.homeDirectoryForCurrentUser) -> AgentLocations {
        AgentLocations(
            grokLog: directory.appendingPathComponent(".grok/logs/unified.jsonl"),
            codexDirectories: [
                directory.appendingPathComponent(".codex/sessions"),
                directory.appendingPathComponent(".codex/archived_sessions")
            ],
            claudeProjects: directory.appendingPathComponent(".claude/projects")
        )
    }
}

enum AgentSource {
    case grok
    case codex
    case claude

    var marker: Data {
        switch self {
        case .grok: return Data("shell.turn.inference_done".utf8)
        case .codex: return Data("token_count".utf8)
        case .claude: return Data("\"input_tokens\":".utf8)
        }
    }
}

/// One usage record pulled out of a log line. Message text is never kept.
struct AgentEvent {
    var date: Date
    var tokens: Double
    var messageID: String?
}

enum AgentLogLine {
    static func event(in line: String, source: AgentSource) -> AgentEvent? {
        guard let date = date(in: line) else { return nil }
        switch source {
        case .grok:
            guard line.contains("shell.turn.inference_done") else { return nil }
            guard let prompt = number("prompt_tokens", in: line), let completion = number("completion_tokens", in: line) else { return nil }
            let tokens = prompt + completion
            guard tokens > 0 else { return nil }
            return AgentEvent(date: date, tokens: tokens, messageID: nil)
        case .codex:
            guard let last = line.range(of: "\"last_token_usage\"") else { return nil }
            guard let tokens = number("total_tokens", in: String(line[last.upperBound...])), tokens > 0 else { return nil }
            return AgentEvent(date: date, tokens: tokens, messageID: nil)
        case .claude:
            guard let input = number("input_tokens", in: line) else { return nil }
            let cacheWrite = number("cache_creation_input_tokens", in: line) ?? 0
            let cacheRead = number("cache_read_input_tokens", in: line) ?? 0
            let output = number("output_tokens", in: line) ?? 0
            let tokens = input + cacheWrite + cacheRead + output
            guard tokens > 0 else { return nil }
            return AgentEvent(date: date, tokens: tokens, messageID: messageID(in: line))
        }
    }

    static func date(in line: String) -> Date? {
        for key in ["\"timestamp\":\"", "\"ts\":\""] {
            guard let range = line.range(of: key) else { continue }
            let rest = line[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            if let date = iso8601(rest[..<end]) { return date }
        }
        return nil
    }

    /// `2026-10-02T03:28:30Z` or with a fraction of a second, in UTC.
    static func iso8601(_ text: Substring) -> Date? {
        let s = text
        guard s.count >= 20 else { return nil }
        func num(_ from: Int, _ count: Int) -> Int? {
            guard let start = s.index(s.startIndex, offsetBy: from, limitedBy: s.endIndex),
                  let end = s.index(start, offsetBy: count, limitedBy: s.endIndex) else { return nil }
            return Int(s[start..<end])
        }
        guard s[s.index(s.startIndex, offsetBy: 10)] == "T",
              let year = num(0, 4), let month = num(5, 2), let day = num(8, 2),
              let hour = num(11, 2), let minute = num(14, 2), let second = num(17, 2),
              (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else { return nil }
        var fraction = 0.0
        var index = s.index(s.startIndex, offsetBy: 19)
        if index < s.endIndex, s[index] == "." {
            index = s.index(after: index)
            var digits = 0
            var value = 0
            while index < s.endIndex, let digit = s[index].wholeNumberValue, digits < 6 {
                value = value * 10 + digit
                digits += 1
                index = s.index(after: index)
            }
            if digits > 0 { fraction = Double(value) / pow(10, Double(digits)) }
        }
        let days = unixDays(year: year, month: month, day: day)
        return Date(timeIntervalSince1970: Double(days) * 86_400 + Double(hour * 3600 + minute * 60 + second) + fraction)
    }

    /// Days since 1970-01-01, Howard Hinnant's civil-from-days inverse.
    private static func unixDays(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let m = month + (month > 2 ? -3 : 9)
        let doy = (153 * m + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    private static func messageID(in line: String) -> String? {
        guard let range = line.range(of: "\"message\":{\"id\":\"") else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "\""), end > rest.startIndex else { return nil }
        let id = rest[..<end]
        guard id.count < 80 else { return nil }
        return String(id)
    }

    /// The number after `"key":`, or nil when the key is missing or holds an object.
    private static func number(_ key: String, in line: String) -> Double? {
        guard let range = line.range(of: "\"\(key)\":") else { return nil }
        var index = range.upperBound
        if index < line.endIndex, line[index] == " " { index = line.index(after: index) }
        let start = index
        if index < line.endIndex, line[index] == "-" || line[index] == "+" { index = line.index(after: index) }
        var saw = false
        while index < line.endIndex {
            let character = line[index]
            if character.isNumber || character == "." {
                saw = true
                index = line.index(after: index)
                continue
            }
            break
        }
        guard saw else { return nil }
        return Double(line[start..<index])
    }
}

/// Tokens gathered from log files, in ten-minute buckets, so a file is read once and then only as it grows.
struct AgentLedger {
    static let bucket: TimeInterval = 600

    struct FileState {
        var device: UInt64 = 0
        var inode: UInt64 = 0
        var offset: UInt64 = 0
        var buckets: [Int: Double] = [:]
        var seen: Set<String> = []
    }

    var files: [String: FileState] = [:]

    mutating func ingest(_ url: URL, source: AgentSource) {
        let path = url.path
        var info = stat()
        guard stat(path, &info) == 0, info.st_size > 0 else { return }
        let size = UInt64(info.st_size)
        var state = files[path] ?? FileState()
        let device = UInt64(info.st_dev)
        let inode = UInt64(info.st_ino)
        if state.inode != inode || state.device != device || size < state.offset {
            state = FileState()
        }
        state.device = device
        state.inode = inode
        guard size > state.offset else {
            files[path] = state
            return
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: state.offset)) != nil else { return }

        let marker = source.marker
        var pending = Data()
        var read: UInt64 = 0
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            read += UInt64(chunk.count)
            pending.append(chunk)
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 0x0A) {
                consume(pending[start..<newline], marker: marker, source: source, state: &state)
                start = newline + 1
            }
            if start > pending.startIndex {
                pending.removeSubrange(pending.startIndex..<start)
            }
            // A line this long is not a usage record. Drop it rather than keep the whole file in memory.
            if pending.count > 32 << 20 {
                pending.removeAll(keepingCapacity: false)
            }
        }
        state.offset += read - UInt64(pending.count)
        files[path] = state
    }

    mutating func tokens(at now: Date) -> Double {
        var sum = 0.0
        for path in files.keys {
            var state = files[path] ?? FileState()
            let stale = state.buckets.keys.filter {
                now.timeIntervalSince1970 - Double($0) * Self.bucket >= Opening.day + Self.bucket
            }
            for bucket in stale { state.buckets[bucket] = nil }
            for (bucket, amount) in state.buckets {
                let age = now.timeIntervalSince1970 - Double(bucket) * Self.bucket
                sum += Opening.decayed(amount, age: age)
            }
            files[path] = state
        }
        return sum
    }

    private func consume(_ line: Data.SubSequence, marker: Data, source: AgentSource, state: inout FileState) {
        guard !line.isEmpty, line.range(of: marker) != nil else { return }
        var bytes = Data(line)
        if bytes.last == 0x0D { bytes.removeLast() }
        guard let text = String(data: bytes, encoding: .utf8), let event = AgentLogLine.event(in: text, source: source) else { return }
        if let id = event.messageID {
            guard state.seen.insert(id).inserted else { return }
        }
        let bucket = Int(event.date.timeIntervalSince1970 / Self.bucket)
        state.buckets[bucket, default: 0] += event.tokens
    }
}

enum AgentScan {
    /// Reads any new bytes in the local logs and returns the decayed token total.
    static func read(locations: AgentLocations, now: Date, ledger: inout AgentLedger) -> Double {
        ledger.ingest(locations.grokLog, source: .grok)
        for directory in locations.codexDirectories {
            for url in jsonl(in: directory, notBefore: now.addingTimeInterval(-(Opening.day + 3600))) {
                ledger.ingest(url, source: .codex)
            }
        }
        for url in jsonl(in: locations.claudeProjects, notBefore: now.addingTimeInterval(-(Opening.day + 3600))) {
            ledger.ingest(url, source: .claude)
        }
        return ledger.tokens(at: now)
    }

    private static func jsonl(in directory: URL, notBefore: Date) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true, let modified = values.contentModificationDate, modified >= notBefore else { continue }
            urls.append(url)
        }
        return urls
    }
}

/// Polls the local agent logs off the main thread and reports the decayed token total.
public final class AgentActivity {
    private let locations: AgentLocations
    private let queue = DispatchQueue(label: "blog.audiofool.window.agents", qos: .utility)
    private var ledger = AgentLedger()
    private var timer: DispatchSourceTimer?
    private var onUpdate: ((Double) -> Void)?

    public init(locations: AgentLocations = .home()) {
        self.locations = locations
    }

    /// `onUpdate` is called on the main queue. The first reading follows as soon as the logs have been scanned.
    public func start(_ onUpdate: @escaping (Double) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.onUpdate = onUpdate
            guard self.timer == nil else {
                self.scan()
                return
            }
            self.scan()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 20, repeating: 20, leeway: .seconds(5))
            timer.setEventHandler { [weak self] in self?.scan() }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func scan() {
        let tokens = AgentScan.read(locations: locations, now: Date(), ledger: &ledger)
        let callback = onUpdate
        DispatchQueue.main.async { callback?(tokens) }
    }
}
