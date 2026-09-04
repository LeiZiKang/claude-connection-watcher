import Foundation

enum EvidenceKind: String {
    case official = "已验证签名的 Claude 客户端组件"
    case connection = "观测到 Claude / Anthropic 连接"
    case appMember = "属于有相关连接的同一 App"
}

struct NetworkEvidence {
    let process: ProcessRecord
    let kind: EvidenceKind
    let matchedDomain: String
    let endpoint: String
    let observedAt: Date
    var identity: ProcessIdentity { process.identity }
    var pid: Int32 { identity.pid }
    var processName: String { process.name }
}

struct SocketEndpoint: Hashable {
    let host: String
    let port: Int

    init?(host: String, port: String) {
        guard let number = Int(port), (1...65535).contains(number), !host.isEmpty, host != "*" else { return nil }
        var address = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if address.hasPrefix("::ffff:"), address.dropFirst(7).contains(".") { address = String(address.dropFirst(7)) }
        self.host = address
        self.port = number
    }

    init?(_ text: String) {
        guard let colon = text.lastIndex(of: ":") else { return nil }
        self.init(host: String(text[..<colon]), port: String(text[text.index(after: colon)...]))
    }
}

struct SocketRecord: Hashable {
    let pid: Int32
    let network: String
    let source: SocketEndpoint
    let destination: SocketEndpoint
    let display: String
}

struct ProxyConnection {
    let host: String
    let network: String
    let source: SocketEndpoint
    let inbound: SocketEndpoint?
    let destination: SocketEndpoint?
    let isTunnel: Bool
}

final class ClaudeConnectionObserver {
    static let window: TimeInterval = 300
    static let domains = ["anthropic.com", "claude.ai", "claude.com"]
    private let queue = DispatchQueue(label: "ClaudeConnectionObserver", qos: .utility)
    private let snapshotLock = NSLock()
    private let inventory = ProcessInventory()
    private var timer: DispatchSourceTimer?
    private var history: [ProcessIdentity: NetworkEvidence] = [:]
    private var cachedItems: [NetworkEvidence] = []
    private var cachedError: String?
    private(set) var startedAt = Date()

    func start(onUpdate: @escaping () -> Void) {
        guard timer == nil else { return }
        startedAt = Date()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(200))
        source.setEventHandler { [weak self] in
            self?.sample()
            DispatchQueue.main.async(execute: onUpdate)
        }
        timer = source
        source.resume()
    }

    func stop() { timer?.cancel(); timer = nil }

    func snapshot() -> (items: [NetworkEvidence], error: String?) {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        let now = Date()
        return (cachedItems.filter { $0.kind == .official || now.timeIntervalSince($0.observedAt) < Self.window }, cachedError)
    }

    // Also used by --diagnose; collects metadata only and never signals a target.
    func sample() {
        let before = inventory.collect()
        var warning: String?
        var matches: [NetworkEvidence] = []
        let socketPath = "/tmp/verge/verge-mihomo.sock"
        if FileManager.default.fileExists(atPath: socketPath) {
            let first = readSockets()
            // Fixed GET endpoint on an existing Unix socket. -q disables curlrc;
            // no redirects, configuration writes, connection deletion, or DNS.
            let response = CommandRunner.run("/usr/bin/curl", ["-q", "--silent", "--show-error",
                "--noproxy", "*", "--max-time", "2", "--max-filesize", "8388608",
                "--unix-socket", socketPath, "--request", "GET", "http://localhost/connections"])
            let last = readSockets()
            if let error = first.error ?? last.error {
                warning = "其他 App 的网络识别不可用：\(error)"
            } else if response.status != 0 || response.diagnostic != nil {
                warning = "无法读取现有代理的连接记录；仍会列出已识别的 Claude 客户端。"
            } else if let connections = Self.parseConnections(response.output) {
                let after = inventory.collect()
                for connection in connections {
                    guard let (current, socket) = Self.verifiedProcess(connection, first: first.items,
                        last: last.items, before: before, after: after) else { continue }
                    matches.append(NetworkEvidence(process: current, kind: .connection,
                        matchedDomain: connection.host, endpoint: socket.display, observedAt: Date()))
                }
                let missed = connections.count - matches.count
                if missed > 0 { warning = "\(missed) 条相关代理连接暂时无法精确对应本机进程；未据此增加退出目标。" }
            } else {
                warning = "现有代理没有返回可识别的连接记录；仍会列出 Claude 客户端。"
            }
        } else {
            warning = "未发现受支持的本地代理连接接口。已列出 Claude 客户端；其他 App 的访问尚不可见。"
        }
        let current = inventory.collect()
        let now = Date()
        history = history.filter { now.timeIntervalSince($0.value.observedAt) < Self.window }
        for match in matches {
            guard current[match.pid]?.identity == match.identity else { continue }
            let previousDomains = history[match.identity]?.matchedDomain.components(separatedBy: ", ") ?? []
            let domains = Set(previousDomains + [match.matchedDomain]).sorted().joined(separator: ", ")
            history[match.identity] = NetworkEvidence(process: match.process, kind: .connection,
                matchedDomain: domains, endpoint: match.endpoint, observedAt: match.observedAt)
        }
        var items = history
        for record in current.values where record.isOfficialClient {
            if items[record.identity] == nil {
                items[record.identity] = NetworkEvidence(process: record, kind: .official,
                    matchedDomain: "", endpoint: "", observedAt: now)
            }
        }
        // Include the other live components of an observed app so quitting a
        // renderer alone doesn't leave its parent application running.
        let relatedApps = Set(items.values.filter {
            current[$0.pid]?.identity == $0.identity && $0.process.owner.path.hasSuffix(".app")
        }.map { $0.process.owner })
        for record in current.values where relatedApps.contains(record.owner) && items[record.identity] == nil {
            let relatedTime = items.values.filter { $0.process.owner == record.owner }
                .map(\.observedAt).max() ?? now
            items[record.identity] = NetworkEvidence(process: record, kind: .appMember,
                matchedDomain: "", endpoint: "", observedAt: relatedTime)
        }
        let sorted = items.values.sorted {
            if $0.process.owner.name != $1.process.owner.name { return $0.process.owner.name < $1.process.owner.name }
            return $0.pid < $1.pid
        }
        snapshotLock.lock()
        cachedItems = sorted
        cachedError = warning
        snapshotLock.unlock()
    }

    private func readSockets() -> (items: Set<SocketRecord>, error: String?) {
        let result = CommandRunner.run("/usr/sbin/lsof", ["-nP", "-l", "-iTCP", "-iUDP", "-FpcnP"])
        guard (result.status == 0 || (result.status == 1 && result.output.isEmpty)), result.diagnostic == nil else {
            return ([], result.diagnostic ?? "无法读取本机连接表")
        }
        return (Self.parseSockets(String(decoding: result.output, as: UTF8.self)), nil)
    }

    static func parseSockets(_ text: String) -> Set<SocketRecord> {
        var result = Set<SocketRecord>()
        var pid: Int32?, network = ""
        for line in text.split(whereSeparator: \Character.isNewline) {
            let value = String(line.dropFirst())
            switch line.first {
            case "p": pid = Int32(value); network = ""
            case "f": network = ""
            case "P": network = value.lowercased()
            case "n":
                guard let pid, ["tcp", "udp"].contains(network), let arrow = value.range(of: "->") else { continue }
                let local = String(value[..<arrow.lowerBound])
                let remote = String(value[arrow.upperBound...]).components(separatedBy: " ")[0]
                guard let source = SocketEndpoint(local), let destination = SocketEndpoint(remote) else { continue }
                result.insert(SocketRecord(pid: pid, network: network, source: source,
                                           destination: destination, display: local + "->" + remote))
            default: continue
            }
        }
        return result
    }

    static func domainMatches(_ host: String) -> Bool {
        let value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domains.contains { value == $0 || value.hasSuffix("." + $0) }
    }

    static func parseConnections(_ data: Data) -> [ProxyConnection]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["connections"] as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let metadata = row["metadata"] as? [String: Any] else { return nil }
            func string(_ key: String) -> String {
                if let value = metadata[key] as? String { return value }
                if let value = metadata[key] as? NSNumber { return value.stringValue }
                return ""
            }
            // A nonempty sniffed name is more specific than the routing host.
            let sniffed = string("sniffHost")
            let host = (sniffed.isEmpty ? string("host") : sniffed).lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let network = string("network").lowercased()
            guard domainMatches(host), ["tcp", "udp"].contains(network),
                  let source = SocketEndpoint(host: string("sourceIP"), port: string("sourcePort")) else { return nil }
            return ProxyConnection(host: host, network: network, source: source,
                inbound: SocketEndpoint(host: string("inboundIP"), port: string("inboundPort")),
                destination: SocketEndpoint(host: string("destinationIP"), port: string("destinationPort")),
                isTunnel: string("type").lowercased() == "tun")
        }
    }

    static func match(_ connection: ProxyConnection, sockets: Set<SocketRecord>) -> SocketRecord? {
        var candidates = sockets.filter { $0.network == connection.network && $0.source == connection.source }
        if !connection.isTunnel, let inbound = connection.inbound {
            candidates = candidates.filter { $0.destination == inbound }
        } else if !connection.isTunnel, let destination = connection.destination {
            candidates = candidates.filter { $0.destination == destination }
        } else if !connection.isTunnel { return nil }
        // TUN may translate a Fake-IP. Only accept a unique source socket;
        // ambiguous UDP/TCP source tuples are never guessed.
        return candidates.count == 1 ? candidates.first : nil
    }

    static func verifiedProcess(_ connection: ProxyConnection, first: Set<SocketRecord>,
                                last: Set<SocketRecord>, before: [Int32: ProcessRecord],
                                after: [Int32: ProcessRecord]) -> (ProcessRecord, SocketRecord)? {
        guard let a = match(connection, sockets: first), let b = match(connection, sockets: last), a == b,
              let prior = before[a.pid], let current = after[b.pid], prior.identity == current.identity,
              !ProcessInventory.isProtected(current.identity) else { return nil }
        return (current, b)
    }
}
