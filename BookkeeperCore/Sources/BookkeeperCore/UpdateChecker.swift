import Foundation

/// One entry in the update feed (`appcast.json`), as the GitHub release carries it.
public struct UpdateInfo: Sendable, Codable, Equatable, Identifiable {
    public let version: String     // marketing version, e.g. "1.1"
    public let notes: String?      // optional "what's new"
    public let file: String?       // zip name in the release; default "Bookkeeper.zip"
    /// Every shipped version's notes, newest first, so an app a few versions behind can
    /// show all it is about to gain. Absent in feeds from before 2.0.14.
    public let history: [UpdateNote]?
    /// The zip's SHA-256 (hex) and the release key's signature over "<version>\n<sha256>"
    /// (`ReleaseFeed`).
    public let sha256: String?
    public let signature: String?
    public var id: String { version }
    public init(version: String, notes: String? = nil, file: String? = nil, history: [UpdateNote]? = nil,
                sha256: String? = nil, signature: String? = nil) {
        self.version = version; self.notes = notes; self.file = file; self.history = history
        self.sha256 = sha256; self.signature = signature
    }

    /// What installing this brings to an app on `current`: each newer version's notes,
    /// newest first. Falls back to this version's own notes when the feed has no history.
    public func changes(since current: String) -> [UpdateNote] {
        let newer = (history ?? []).filter { UpdateChecker.isNewer($0.version, than: current) }
        if !newer.isEmpty { return newer }
        return [UpdateNote(version: version, notes: notes ?? "")]
    }
}

/// One version's line in the change log.
public struct UpdateNote: Sendable, Codable, Equatable, Identifiable {
    public let version: String
    public let notes: String
    public var id: String { version }
    public init(version: String, notes: String) { self.version = version; self.notes = notes }
}

/// Version compare and the outcome of an update check (`ReleaseFeed.check`).
public enum UpdateChecker {
    /// What a check actually found. "Nothing new" and "I couldn't look" are different
    /// answers, so each outcome has its own case.
    public enum Status: Sendable, Equatable {
        case available(UpdateInfo)
        case upToDate(current: String, published: String?)
        case unreadableFeed(path: String)
        /// GitHub couldn't be asked, or had nothing to give; says why in plain words.
        case offline(why: String)

        public var update: UpdateInfo? {
            if case .available(let info) = self { return info }
            return nil
        }

        /// True when the app could not form an opinion — as opposed to forming the
        /// opinion that nothing is new.
        public var isFailure: Bool {
            switch self {
            case .available, .upToDate: return false
            default: return true
            }
        }
    }

    /// Dot-separated numeric compare: "1.10" > "1.9", "1.1" > "1.0".
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
