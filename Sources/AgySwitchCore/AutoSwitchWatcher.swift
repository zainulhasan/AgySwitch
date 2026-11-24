import Darwin
import Foundation

struct QuotaEvent: Equatable {
    let reason: ExhaustionReason
    var resetAt: Double?
    var email: String?
    /// The email came from the log itself (a sign-in line or an explicit account field), not from a guess.
    var attributed = false
}

/// The account a log's agy process signed in with, from its `applyAuthResult` / `authenticated successfully as` lines.
enum SignIn: Equatable {
    case account(String)
    /// Signed in without a consumer account (for example `authMethod=gateway`), so never part of the pool.
    case noAccount
}

enum QuotaParser {
    // Logs may include arbitrary prompt text and credentials. Only typed event fields leave this parser.
    private static let glog = regex(#"^([IWEF])\d{4}\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?\s+\d+\s+([^\]\r\n]+):\d+\]\s*"#)
    private static let signals: [(ExhaustionReason, String)] = [
        (.stopReason, "STOP_REASON_QUOTA_EXHAUSTED"),
        (.errorCode, "ERROR_CODE_RESOURCE_EXHAUSTED"),
        (.resource, "RESOURCE_EXHAUSTED|ResourceExhausted"),
        (.quota, #"QUOTA_EXHAUSTED|out\s+of\s+quota|quota\s+(?:exhausted|exceeded)|individual\s+quota\s+reached"#),
        (.http429, #"(?:HTTP(?:/\d+(?:\.\d+)?)?\s+|(?:status(?:[ _-]code)?|code)["']?\s*(?:[=:]\s*|\s+)["']?)429|Too\s+Many\s+Requests"#)
    ]
    private static let signal = regex(#"(?<!\w)(?:"# + signals.map { "(" + $0.1 + ")" }.joined(separator: "|") + #")(?!\w)"#, insensitive: true)
    /// Google's own quota markers. Generic 429 or "quota exceeded" wording can come from any tool or MCP server,
    /// so it only counts on agy's error- and warning-level lines.
    private static let googleQuota = regex(#"(?<!\w)(?:STOP_REASON_QUOTA_EXHAUSTED|ERROR_CODE_RESOURCE_EXHAUSTED|RESOURCE_EXHAUSTED|ResourceExhausted|QUOTA_EXHAUSTED)(?!\w)|\bindividual\s+quota\s+reached\b"#, insensitive: true)
    /// agy's own end-of-turn error, e.g. `agent executor error: generating and executing: RESOURCE_EXHAUSTED (code 429)`.
    private static let agyTurnError = regex(#"\bgenerating\s+and\s+executing\b|\bindividual\s+quota\s+reached\b"#, insensitive: true)
    /// Model capacity is a server-side shortage, not the account's quota, so switching accounts doesn't help.
    private static let capacity = regex(#"(?<!\w)MODEL_CAPACITY_EXHAUSTED(?!\w)|\bno\s+capacity\s+available\b"#, insensitive: true)
    /// MCP servers, tool output, background polls and requests agy is still retrying describe someone else's limit
    /// or a recoverable error, never a turn ending on an exhausted account. `attempt N/N failed` is a final failure.
    private static let foreign = regex(#"(?<![A-Za-z0-9])mcp(?![A-Za-z0-9])|\btool[ _-]?(?:result|output|response)s?\b|\b(?:ListExperiments|fetchAvailableModels|loadCodeAssist|onboardUser|fetchQuotaStatus|retrieveUserQuota\w*|doRefreshQuota)\b|\bfailed\s+to\s+poll\b|\bretrying\s+(?:in|after)\b|\bwill\s+retry\b|\battempt\s+\d+\s+failed\b|\battempt\s+(\d+)\s*/\s*(?!\1\b)\d+\s+failed\b"#, insensitive: true)
    private static let errorContext = regex(#"\b(?:error|failed|failure|exception|denied|rejected|returned|request|response|status|rate[ -]limit(?:ed)?)\b"#, insensitive: true)
    private static let nonError = regex(#"\b(?:retry_model_capacity_exhausted|model[ _-]config(?:uration)?|feature[ _-]flag|loaded\s+config|retry[ _-]policy|example\s+(?:error|status)|expected\s+status)\b|^(?:user\s+prompt|model\s+output|prompt\s+text|response\s+text)\s*[:=]"#, insensitive: true)
    private static let resetField = #"(?:reset[_ -]?time|quota[_ -]?reset[_ -]?time)"#
    private static let relativeField = #"(?:try\s+again\s+in|retry[ _-]*after|quota\s+(?:will\s+)?reset\s+(?:in|after)|resets?\s+in)"#
    private static let absolute = regex(#"\b"# + resetField + #"["']?\s*[:=]\s*["']?(\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}:\d{2})(\.\d+)?([Zz]|[+-]\d{2}:?\d{2})?"#, insensitive: true)
    private static let relative = regex(#"\b"# + relativeField + #"(?:["']?\s*[:=])?\s*["']?((?:[0-9]{1,8}[ \t\r\n\f\x0B]*[dhms][ \t\r\n\f\x0B]*)+)(?![A-Za-z0-9_])"#, insensitive: true)
    private static let durationPart = regex(#"([0-9]{1,8})\s*([dhms])"#, insensitive: true)
    /// `google.rpc.RetryInfo`, e.g. `"retryDelay": "3600s"`.
    private static let retryDelay = regex(#"\bretry[_ -]?delay["']?\s*[:=]\s*["']?([0-9]{1,9}(?:\.[0-9]+)?)s(?![A-Za-z0-9_])"#, insensitive: true)
    private static let resetContinuation = regex(#"^[\s{"']*(?:"# + resetField + "|" + relativeField + #")\b"#, insensitive: true)
    private static let account = regex(#"\b(?:id_token_email|idTokenEmail|account_email|accountEmail)["']?\s*[:=]\s*["']?("# + Validation.emailPattern + ")", insensitive: true)
    private static let signInLine = regex(#"^(?:applyAuthResult:\s*email=([^,\s]*)|(?:consumer)?OAuth:\s+authenticated\s+successfully\s+as\b[ \t]*(\S*))"#)
    private static let signInMarkers = [Array("applyAuthResult:".utf8), Array("authenticated successfully as".utf8)]
    /// How far back an untagged line looks for the tagged line it continues (JSON error bodies span ~10 lines).
    private static let headerReach = 32

    private struct Entry {
        let body: String
        let severity: String?
        let source: String?
    }

    static func event(in lines: [String], now: Double, owner: String?) -> QuotaEvent? {
        let entries = lines.map(split)
        for (index, entry) in entries.enumerated() {
            let body = entry.body
            guard first(nonError, in: body) == nil, let matched = first(signal, in: body),
                  let range = Range(matched.range, in: body) else { continue }
            // agy writes backend errors as a tagged header followed by untagged JSON lines: judge those by the header.
            let header = entry.severity == nil
                ? entries[max(index - headerReach, 0)..<index].last { $0.severity != nil } : nil
            let scope = [header?.source, header?.body, entry.source, body].compactMap { $0 }.joined(separator: " ")
            let ownTurn = first(agyTurnError, in: scope) != nil
            if !ownTurn, first(foreign, in: scope) != nil { continue }
            let google = ownTurn || first(googleQuota, in: body) != nil
            switch entry.severity ?? header?.severity {
            case "E", "W", "F":
                break
            case "I":
                // Info lines only count for Google's own markers, stated as the line's subject or in an error context.
                guard google else { continue }
                if first(errorContext, in: body) == nil,
                   !body[..<range.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: " {\"'")).isEmpty {
                    continue
                }
            default:
                // Untagged output with no tagged line before it: only Google's own markers count.
                guard google else { continue }
            }
            let before = entries[max(index - 4, 0)..<index].reversed()
                .prefix { $0.severity == nil }.map(\.body).reversed()
            let after = continuation(lines[(index + 1)..<min(lines.count, index + 7)])
            let context = ([body] + before + after).joined(separator: "\n")
            if first(capacity, in: context) != nil { continue }
            let email = first(account, in: context).flatMap { capture($0, at: 1, in: context)?.lowercased() }
            guard let reasonIndex = signals.indices.first(where: { matched.range(at: $0 + 1).location != NSNotFound })
            else { continue }
            return QuotaEvent(reason: signals[reasonIndex].0, resetAt: resetAt(in: context, now: now),
                              email: email ?? owner, attributed: email != nil)
        }
        return nil
    }

    /// agy logs the account it signed in with at startup and after every re-login. Returns nil for other lines and
    /// for a sign-in line whose email can't be read, so an unexpected format falls back instead of disabling switches.
    static func signIn(in line: String) -> SignIn? {
        var bytes = line
        let marked = bytes.withUTF8 { text in
            signInMarkers.contains { marker in
                text.count >= marker.count && marker.withUnsafeBufferPointer {
                    memmem(text.baseAddress, text.count, $0.baseAddress, $0.count) != nil
                }
            }
        }
        guard marked else { return nil }
        let entry = split(line)
        guard entry.severity == "I", let match = first(signInLine, in: entry.body) else { return nil }
        let value = capture(match, at: 1, in: entry.body) ?? capture(match, at: 2, in: entry.body) ?? ""
        if value.isEmpty { return .noAccount }
        return Validation.email.matchesWhole(value) ? .account(value.lowercased()) : nil
    }

    static func continuation<S: Sequence>(_ lines: S) -> [String] where S.Element == String {
        lines.map(split).prefix { $0.severity == nil || first(resetContinuation, in: $0.body) != nil }.map(\.body)
    }

    static func resetAt(in text: String, now: Double) -> Double? {
        for match in absolute.matches(in: text, range: fullRange(text)) {
            guard let stamp = capture(match, at: 1, in: text) else { continue }
            let base = stamp.uppercased().replacingOccurrences(of: " ", with: "T")
            let zone = capture(match, at: 3, in: text)?.uppercased()
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.calendar = Calendar(identifier: .iso8601)
            parser.isLenient = false
            parser.dateFormat = zone == nil ? "yyyy-MM-dd'T'HH:mm:ss" : "yyyy-MM-dd'T'HH:mm:ssXXXXX"
            let normalized = zone.map {
                $0.count == 5 ? String($0.prefix(3)) + ":" + String($0.suffix(2)) : $0
            } ?? ""
            guard let date = parser.date(from: base + normalized) else { continue }
            let fraction = capture(match, at: 2, in: text).flatMap { Double("0" + $0) } ?? 0
            let time = date.timeIntervalSince1970 + fraction
            if Validation.timestamp(time), time > now { return time }
        }
        for match in relative.matches(in: text, range: fullRange(text)) {
            guard let duration = capture(match, at: 1, in: text) else { continue }
            let total = durationPart.matches(in: duration, range: fullRange(duration)).reduce(0.0) { total, part in
                let number = capture(part, at: 1, in: duration).flatMap(Double.init) ?? 0
                let unit = capture(part, at: 2, in: duration)?.lowercased()
                return total + number * (unit == "d" ? 86_400 : unit == "h" ? 3600 : unit == "m" ? 60 : 1)
            }
            if total > 0, total <= 253_402_300 { return now + total }
        }
        for match in retryDelay.matches(in: text, range: fullRange(text)) {
            guard let seconds = capture(match, at: 1, in: text).flatMap(Double.init), seconds > 0,
                  seconds <= 253_402_300 else { continue }
            return now + seconds
        }
        return nil
    }

    private static func split(_ line: String) -> Entry {
        guard let prefix = first(glog, in: line), let range = Range(prefix.range, in: line) else {
            return Entry(body: String(line.drop(while: \.isWhitespace)), severity: nil, source: nil)
        }
        return Entry(body: String(line[range.upperBound...]), severity: capture(prefix, at: 1, in: line),
                     source: capture(prefix, at: 2, in: line))
    }

    private static func regex(_ pattern: String, insensitive: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: insensitive ? .caseInsensitive : [])
    }
    private static func fullRange(_ value: String) -> NSRange { NSRange(value.startIndex..., in: value) }
    private static func first(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: fullRange(text))
    }
    private static func capture(_ match: NSTextCheckingResult, at index: Int, in text: String) -> String? {
        Range(match.range(at: index), in: text).map { String(text[$0]) }
    }
}

final class LogTail {
    private struct FileID: Hashable {
        let device: dev_t
        let inode: ino_t
        let birthSeconds: Int
        let birthNanoseconds: Int
    }

    private struct Cursor {
        /// The account events in this log belong to: its own sign-in line once seen, otherwise the account that was
        /// active when the log was first seen.
        var owner: String?
        /// Whether `owner` is settled: taken from a sign-in line, or the log was searched and has none.
        var ownerResolved = false
        /// Whether `owner` came from the log's own sign-in line.
        var signedIn = false
        var offset: off_t = 0
        /// Byte offset of the first line returned by the latest `read`.
        var chunkStart: off_t = 0
        var fragment = Data()
        var discarding = false
        var pending: QuotaEvent?
        var retired = false

        mutating func apply(_ signIn: SignIn) {
            if case let .account(email) = signIn { owner = email } else { owner = nil }
            ownerResolved = true
            signedIn = true
        }

        mutating func read(fd: Int32, size: off_t) throws -> [String] {
            if size < offset {
                offset = 0
                fragment = Data()
                discarding = false
                pending = nil
                ownerResolved = false
                signedIn = false
            }
            guard size > offset else { return [] }
            chunkStart = offset - off_t(fragment.count)
            var buffer = [UInt8](repeating: 0, count: 256 * 1024)
            let count = pread(fd, &buffer, buffer.count, offset)
            guard count >= 0 else { throw LogTail.unreadable }
            offset += off_t(count)
            var chunk = Data(buffer.prefix(count))
            if discarding {
                guard let newline = chunk.firstIndex(of: 10) else { return [] }
                chunk = Data(chunk.suffix(from: newline + 1))
                discarding = false
            }
            fragment.append(chunk)
            let lines = fragment.split(separator: 10, omittingEmptySubsequences: false)
            fragment = Data(lines.last ?? Data())
            if fragment.count > LogTail.maxLine {
                fragment = Data()
                discarding = true
            }
            return lines.dropLast().compactMap {
                $0.count <= LogTail.maxLine ? String(decoding: $0, as: UTF8.self) : nil
            }
        }
    }

    let directory: URL
    private var cursors: [FileID: Cursor] = [:]
    static let unreadable = AppError.watchUnreadable
    private static let maxLine = 128 * 1024

    init(directory: URL) { self.directory = directory }

    func start(owner: String?) throws {
        try forEachFile { id, fd, size in
            var cursor = Cursor(owner: owner, offset: size)
            if size > 0 {
                var last: UInt8 = 0
                cursor.discarding = pread(fd, &last, 1, size - 1) != 1 || last != 10
            }
            cursors[id] = cursor
        }
    }

    func poll(owner: () throws -> String?, now: Double) throws -> [QuotaEvent] {
        var visible: Set<FileID> = []
        var newOwner: String?
        var didReadOwner = false
        var events: [QuotaEvent] = []
        try forEachFile { id, fd, size in
            guard visible.insert(id).inserted else { return }
            if cursors[id] == nil {
                if !didReadOwner {
                    newOwner = try owner()
                    didReadOwner = true
                }
                cursors[id] = Cursor(owner: newOwner)
            }
            guard var cursor = cursors[id], !cursor.retired else { return }
            let lines = try cursor.read(fd: fd, size: size)
            if var pending = cursor.pending {
                pending.resetAt = QuotaParser.resetAt(in: QuotaParser.continuation(lines.prefix(6)).joined(separator: "\n"), now: now)
                events.append(pending)
                cursor.pending = nil
            }
            // Sign-in lines split the chunk: events before one belong to the previous account. One event per part.
            var start = lines.startIndex
            while start < lines.endIndex {
                let cut = lines[start...].firstIndex { QuotaParser.signIn(in: $0) != nil } ?? lines.endIndex
                if var event = QuotaParser.event(in: Array(lines[start..<cut]), now: now, owner: nil) {
                    if event.email == nil {
                        Self.resolveOwner(&cursor, fd: fd)
                        event.email = cursor.owner
                        event.attributed = cursor.signedIn
                    }
                    if event.resetAt == nil, cut == lines.endIndex { cursor.pending = event } else { events.append(event) }
                }
                guard cut < lines.endIndex, let signIn = QuotaParser.signIn(in: lines[cut]) else { break }
                cursor.apply(signIn)
                start = cut + 1
            }
            cursors[id] = cursor
        }
        cursors = cursors.filter { visible.contains($0.key) }
        return events
    }

    func retireExisting() {
        for key in Array(cursors.keys) { cursors[key] = Cursor(owner: nil, retired: true) }
        // A file can appear between the last poll and the switch.
        try? forEachFile { id, _, _ in cursors[id] = Cursor(owner: nil, retired: true) }
    }

    /// Settles a log's owner the first time it reports an exhaustion. Logs that were already open when watching
    /// started have their sign-in line before the watched range, so search the part of the file not yet read.
    private static func resolveOwner(_ cursor: inout Cursor, fd: Int32) {
        guard !cursor.ownerResolved else { return }
        cursor.ownerResolved = true
        // No sign-in line: keep the account that was active when the log was first seen.
        if let signIn = lastSignIn(fd: fd, before: cursor.chunkStart) { cursor.apply(signIn) }
    }

    private static func lastSignIn(fd: Int32, before limit: off_t) -> SignIn? {
        let markers = [Data("applyAuthResult:".utf8), Data("authenticated successfully as".utf8)]
        var found: SignIn?
        var carry = Data()
        var discarding = false
        var position: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while position < limit {
            let count = pread(fd, &buffer, Int(min(off_t(buffer.count), limit - position)), position)
            guard count > 0 else { break }
            position += off_t(count)
            var chunk = Data(buffer[..<count])
            if discarding {
                // Skip the rest of an over-long line instead of reading its tail as a new line.
                guard let newline = chunk.firstIndex(of: 10) else { continue }
                chunk = Data(chunk[(newline + 1)...])
                discarding = false
            }
            carry.append(chunk)
            guard let end = carry.lastIndex(of: 10) else {
                if carry.count > maxLine {
                    carry = Data()
                    discarding = true
                }
                continue
            }
            for line in carry[..<end].split(separator: 10) where line.count <= maxLine
                && markers.contains(where: { line.range(of: $0) != nil }) {
                if let signIn = QuotaParser.signIn(in: String(decoding: line, as: UTF8.self)) { found = signIn }
            }
            carry = Data(carry[(end + 1)...])
        }
        return found
    }

    private func forEachFile(_ body: (FileID, Int32, off_t) throws -> Void) throws {
        let files: [String]
        do { files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return // agy may not have created the log directory yet.
        } catch { throw Self.unreadable }
        for name in files where name.hasSuffix(".log") && (name.hasPrefix("cli-") || name.hasPrefix("acp-server-")) {
            let fd = open(directory.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            let id = FileID(device: info.st_dev, inode: info.st_ino, birthSeconds: info.st_birthtimespec.tv_sec,
                            birthNanoseconds: info.st_birthtimespec.tv_nsec)
            try body(id, fd, info.st_size)
        }
    }
}

public final class AutoSwitchWatcher {
    private let tail: LogTail
    private let pool: AccountPool
    private let clock: () -> Double
    private let monotonic: () -> Double
    /// Back-off after a failed switch attempt (for example, every other account cooling down), and how long a
    /// switch distrusts logs whose account is only guessed.
    private let debounce: Double
    private var nextAttempt = -Double.infinity
    private var switchedAt = -Double.infinity
    /// The latest event per account that arrived during the back-off, replayed once it ends.
    private var deferred: [QuotaEvent] = []

    public init(pool: AccountPool, directory: URL, debounce: Double = 30,
                clock: @escaping () -> Double = { Date().timeIntervalSince1970 },
                monotonic: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) throws {
        self.pool = pool
        self.clock = clock
        self.monotonic = monotonic
        self.debounce = debounce
        tail = LogTail(directory: directory)
        try tail.start(owner: pool.currentEmail())
    }

    public func poll(cooldown: Double) throws -> SwitchOutcome? {
        let now = clock()
        let fresh = try tail.poll(owner: pool.currentEmail, now: now)
        guard monotonic() >= nextAttempt else {
            enqueue(fresh)
            return nil
        }
        let events = deferred + fresh
        deferred = []
        for (index, event) in events.enumerated() {
            // Only the active account's own exhaustion can switch (see AccountPool.onQuota). Logs from sessions
            // started before a switch are retired, so a session started after it is handled right away. A log
            // without a sign-in line is only guessed to belong to the account active when it appeared, which right
            // after a switch is the new account, so such events wait out the debounce.
            guard let email = event.email, event.attributed || monotonic() >= switchedAt + debounce else { continue }
            do {
                let until = event.resetAt ?? now + cooldown
                guard let result = try pool.onQuota(email: email, until: until, reason: event.reason) else { continue }
                tail.retireExisting()
                switchedAt = monotonic()
                return result
            } catch {
                nextAttempt = monotonic() + debounce
                enqueue(Array(events[(index + 1)...]))
                throw error
            }
        }
        return nil
    }

    public func didSwitchManually() {
        tail.retireExisting()
        deferred = []
        nextAttempt = -Double.infinity
        switchedAt = monotonic()
    }

    private func enqueue(_ events: [QuotaEvent]) {
        for event in events where event.email != nil {
            deferred.removeAll { $0.email == event.email }
            deferred.append(event)
        }
        deferred = Array(deferred.suffix(16))
    }
}
