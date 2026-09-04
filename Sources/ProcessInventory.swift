import AppKit
import Security

struct AppOwner: Hashable {
    let name: String
    let path: String
    let bundleID: String
}

struct ProcessRecord {
    let identity: ProcessIdentity
    let name: String
    let owner: AppOwner
    let isOfficialClient: Bool
}

/// Run on the observer queue. Never infer ownership from a process's display name.
final class ProcessInventory {
    private var officialCache: [ProcessIdentity: Bool] = [:]
    private var ownerCache: [String: AppOwner] = [:]

    func collect() -> [Int32: ProcessRecord] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        var pids = [Int32](repeating: 0, count: Int(count) + 256)
        let size = Int32(pids.count * MemoryLayout<Int32>.stride)
        let actual = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, size) }
        guard actual > 0 else { return [:] }
        var records: [Int32: ProcessRecord] = [:]
        for pid in pids.prefix(min(Int(actual), pids.count)) {
            guard let identity = captureProcessIdentity(pid: pid), !Self.isProtected(identity) else { continue }
            let owner = appOwner(for: identity.executablePath)
            let official: Bool
            if let cached = officialCache[identity] {
                official = cached
            } else {
                official = isOfficial(identity, owner: owner)
                officialCache[identity] = official
            }
            let resolvedOwner = official && owner.bundleID.isEmpty
                ? AppOwner(name: "Claude Code", path: identity.executablePath, bundleID: "com.anthropic.claude-code")
                : owner
            records[pid] = ProcessRecord(identity: identity,
                                         name: URL(fileURLWithPath: identity.executablePath).lastPathComponent,
                                         owner: resolvedOwner, isOfficialClient: official)
        }
        let live = Set(records.values.map(\.identity))
        officialCache = officialCache.filter { live.contains($0.key) }
        return records
    }

    private func appOwner(for path: String) -> AppOwner {
        if let cached = ownerCache[path] { return cached }
        let components = (path as NSString).pathComponents
        if let appIndex = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) {
            let appPath = NSString.path(withComponents: Array(components[...appIndex]))
            if let bundle = Bundle(path: appPath) {
                let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
                let owner = AppOwner(name: name, path: appPath, bundleID: bundle.bundleIdentifier ?? "")
                ownerCache[path] = owner
                return owner
            }
        }
        let owner = AppOwner(name: URL(fileURLWithPath: path).lastPathComponent, path: path, bundleID: "")
        ownerCache[path] = owner
        return owner
    }

    private func isOfficial(_ identity: ProcessIdentity, owner: AppOwner) -> Bool {
        // Only inspect signing data for plausible installations, then require the
        // actual running code to satisfy Anthropic's Developer ID requirement.
        let path = identity.executablePath
        let candidate = owner.bundleID == "com.anthropic.claudefordesktop"
            || URL(fileURLWithPath: path).lastPathComponent == "claude"
            || path.contains("/.local/share/claude/versions/")
        guard candidate else { return false }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: identity.pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return false }
        var requirement: SecRequirement?
        let expression = "anchor apple generic and certificate leaf[subject.OU] = \"Q6L2SF6YDW\""
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }
        if owner.bundleID == "com.anthropic.claudefordesktop" { return true }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return false }
        return dictionary[kSecCodeInfoIdentifier as String] as? String == "com.anthropic.claude-code"
    }

    static func isProtected(_ identity: ProcessIdentity) -> Bool {
        let path = identity.executablePath.lowercased()
        if identity.pid <= 1 || identity.pid == getpid() { return true }
        // Network transports are infrastructure, never a user-app quit target.
        // Apply this guard again immediately before every signal.
        let protectedFragments = ["claude connection watcher.app/", "claude network guard.app/",
                                  "clash", "mihomo", "sing-box", "singbox", "proxifier.app/",
                                  "surge.app/", "biuuu.app/", "flyingbird-lite.app/"]
        return protectedFragments.contains { path.contains($0) }
    }
}
