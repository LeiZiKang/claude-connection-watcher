import Foundation

func runSelfTests() {
    var checks = 0
    func require(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("SELF_TEST_FAILED: \(name)\n".utf8))
            exit(1)
        }
        checks += 1
    }
    require(captureProcessIdentity(pid: getpid())?.pid == getpid(), "native identity")
    require(AppLanguage.resolve(saved: "zh-Hans", preferred: ["en-US"]) == .chinese, "saved Chinese wins")
    require(AppLanguage.resolve(saved: "en", preferred: ["zh-Hans"]) == .english, "saved English wins")
    require(AppLanguage.resolve(saved: nil, preferred: ["zh-TW"]) == .chinese, "Chinese system default")
    require(AppLanguage.resolve(saved: "invalid", preferred: ["fr-FR"]) == .english, "unsupported language fallback")
    let refreshGate = RefreshGate()
    require(refreshGate.begin(), "first manual refresh accepted")
    require(!refreshGate.begin(), "duplicate manual refresh coalesced")
    refreshGate.finish()
    require(refreshGate.begin(), "manual refresh can run again after completion")
    refreshGate.finish()
    for host in ["anthropic.com", "api.anthropic.com", "CLAUDE.AI.", "claude.com"] {
        require(ClaudeConnectionObserver.domainMatches(host), "accepted domain \(host)")
    }
    for host in ["anthropic.com.evil.example", "notclaude.ai", "198.18.0.10", "", "https://claude.ai"] {
        require(!ClaudeConnectionObserver.domainMatches(host), "rejected domain \(host)")
    }
    let fixture = """
    p100
    cBrowser Helper
    f4
    PTCP
    n127.0.0.1:50000->127.0.0.1:7897
    f5
    PTCP
    n127.0.0.1:50001->127.0.0.1:7897
    p200
    cProxy
    f6
    PTCP
    n127.0.0.1:7897->127.0.0.1:50000
    f7
    PUDP
    n*:50002
    """
    let sockets = ClaudeConnectionObserver.parseSockets(fixture)
    require(sockets.count == 3, "connected sockets only")
    let data = Data("""
    {"connections":[{"metadata":{"host":"api.anthropic.com","network":"tcp",
    "sourceIP":"127.0.0.1","sourcePort":"50000","inboundIP":"127.0.0.1",
    "inboundPort":7897,"type":"HTTPS","processPath":"/fabricated","pid":999}}]}
    """.utf8)
    let connections = ClaudeConnectionObserver.parseConnections(data)!
    require(connections.count == 1, "controller metadata parsed")
    require(ClaudeConnectionObserver.match(connections[0], sockets: sockets)?.pid == 100,
            "source socket maps to client, never proxy or supplied PID/path")
    require(ClaudeConnectionObserver.match(connections[0], sockets: []) == nil, "missing socket rejected")
    let duplicate = SocketRecord(pid: 300, network: "tcp", source: connections[0].source,
                                 destination: connections[0].inbound!, display: "duplicate")
    require(ClaudeConnectionObserver.match(connections[0], sockets: sockets.union([duplicate])) == nil,
            "ambiguous owner rejected")
    let owner = AppOwner(name: "Test Browser", path: "/Applications/Test.app", bundleID: "test")
    func record(start: UInt64, path: String = "/Applications/Test.app/Contents/MacOS/test") -> ProcessRecord {
        ProcessRecord(identity: ProcessIdentity(pid: 100, effectiveUID: geteuid(), startSeconds: start,
            startMicroseconds: 7, executablePath: path), name: "test", owner: owner, isOfficialClient: false)
    }
    let original = [Int32(100): record(start: 1)]
    require(ClaudeConnectionObserver.verifiedProcess(connections[0], first: sockets, last: sockets,
        before: original, after: original) != nil, "bracketed identity accepted")
    require(ClaudeConnectionObserver.verifiedProcess(connections[0], first: sockets, last: sockets,
        before: original, after: [100: record(start: 2)]) == nil, "reused PID rejected")
    require(ClaudeConnectionObserver.verifiedProcess(connections[0], first: sockets, last: [],
        before: original, after: original) == nil, "vanished socket rejected")
    let proxy = [Int32(100): record(start: 1, path: "/usr/local/bin/mihomo")]
    require(ClaudeConnectionObserver.verifiedProcess(connections[0], first: sockets, last: sockets,
        before: proxy, after: proxy) == nil, "proxy identity never becomes a target")
    let wrongPeer = ProxyConnection(host: "claude.ai", network: "tcp", source: connections[0].source,
        inbound: SocketEndpoint("127.0.0.1:9999"), destination: nil, isTunnel: false)
    require(ClaudeConnectionObserver.match(wrongPeer, sockets: sockets) == nil, "peer mismatch rejected")
    let wrongProtocol = ProxyConnection(host: "claude.ai", network: "udp", source: connections[0].source,
        inbound: connections[0].inbound, destination: nil, isTunnel: false)
    require(ClaudeConnectionObserver.match(wrongProtocol, sockets: sockets) == nil, "protocol mismatch rejected")
    let tunnel = ProxyConnection(host: "claude.ai", network: "tcp", source: connections[0].source,
                                 inbound: nil, destination: nil, isTunnel: true)
    require(ClaudeConnectionObserver.match(tunnel, sockets: sockets)?.pid == 100, "unique TUN source")
    require(ClaudeConnectionObserver.match(tunnel, sockets: sockets.union([duplicate])) == nil, "ambiguous TUN rejected")
    require(SocketEndpoint("[::ffff:127.0.0.1]:50000") == connections[0].source, "IPv4 mapped IPv6")
    require(ClaudeConnectionObserver.parseConnections(Data("{\"message\":\"Unauthorized\"}".utf8)) == nil,
            "API error is not empty success")
    for path in ["/Applications/Clash Verge.app/Contents/MacOS/Clash Verge", "/usr/local/bin/mihomo",
                 "/usr/local/bin/sing-box", "/Applications/Claude Connection Watcher.app/Contents/MacOS/app"] {
        let identity = ProcessIdentity(pid: 999999, effectiveUID: geteuid(), startSeconds: 1,
                                       startMicroseconds: 1, executablePath: path)
        require(ProcessInventory.isProtected(identity), "protected \(path)")
    }
    // Exercise pipes above their capacity, including stderr, so a wait-before-read
    // regression fails instead of making the observer hang indefinitely.
    let large = CommandRunner.run("/usr/bin/awk", ["BEGIN { for(i=0;i<20000;i++) { print \"012345678901234567890123456789\"; print \"abcdefghijabcdefghij\" > \"/dev/stderr\" } }"], timeout: 5)
    require(large.status == 0 && large.output.count == 620000, "large stdout drains")
    require(large.diagnostic?.utf8.count == 2048, "large stderr drains and diagnostic is bounded")
    let start = ProcessInfo.processInfo.systemUptime
    let slow = CommandRunner.run("/bin/sleep", ["2"], timeout: 0.15)
    require(slow.status == -1 && slow.diagnostic != nil, "slow command times out")
    require(ProcessInfo.processInfo.systemUptime - start < 1.5, "bounded timeout cleanup")
    print("SELF_TEST_OK: \(checks) checks passed. No user application was stopped.")
}
