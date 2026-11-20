import Foundation

// Session.swift — read/write `.photocull.json` sidecar.
// JSON round-trips with the Go implementation:
//   {"version":1,"decisions":{"DSCF1234":"keep"},"last_index":12}
// `crops` is an additive key the Go app ignores.

public enum Decision: String, Codable, Sendable, CaseIterable {
    case keep, reject, undecided
}

/// Normalized crop rectangle in *oriented display space*, origin top-left.
/// Values are 0...1 fractions of the oriented image's width/height.
public struct CropRect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }

    /// Full-frame crop (0, 0, 1, 1).
    public static let full = CropRect(x: 0, y: 0, w: 1, h: 1)

    /// True when this rect covers the whole frame (within 0.5% tolerance).
    public var isFullFrame: Bool {
        let tol = 0.005
        return abs(x) <= tol && abs(y) <= tol && abs(w - 1) <= tol && abs(h - 1) <= tol
    }

    /// Clamp into 0...1 and enforce a minimum size on each axis, keeping the
    /// rect inside the frame.
    public func clamped(minSize: Double) -> CropRect {
        var w = min(max(self.w, minSize), 1)
        var h = min(max(self.h, minSize), 1)
        var x = min(max(self.x, 0), 1 - w)
        var y = min(max(self.y, 0), 1 - h)
        x = max(x, 0); y = max(y, 0)
        if w.isNaN { w = minSize }; if h.isNaN { h = minSize }
        return CropRect(x: x, y: y, w: w, h: h)
    }

    /// Aspect ratio w/h in oriented space.
    public var aspect: Double { h == 0 ? 0 : w / h }
}

/// A per-stem field that carries its own sync stamp.
public enum SessionField: String, Sendable, CaseIterable {
    case decision, crop, tilt, rotation
}

/// One change from another writer (the HTTP layer maps its JSON into this).
public struct SessionChange: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case decision(Decision)
        case crop(CropRect?)
        case tilt(Double)
        case rotation(Int)
    }
    /// UPPERCASED stem.
    public var stem: String
    public var field: SessionField
    public var value: Value
    /// Unix milliseconds of the change; the merge rule compares this against
    /// the stored stamp.
    public var at: Int64

    public init(stem: String, field: SessionField, value: Value, at: Int64) {
        self.stem = stem; self.field = field; self.value = value; self.at = at
    }
}

public enum FolderStatus: String, Sendable {
    case empty
    case unstarted
    case inProgress = "in progress"
    case complete
}

public final class Session {
    public static let fileName = ".photocull.json"

    public var version: Int
    /// Keys are UPPERCASED stems.
    public var decisions: [String: Decision]
    public var lastIndex: Int
    /// Keys are UPPERCASED stems. Empty when nothing is cropped.
    public var crops: [String: CropRect]
    /// Fine straightening angle per stem, in degrees. Positive tilts the photo
    /// clockwise on screen. Empty when nothing is tilted.
    public var tilts: [String: Double]
    /// Quarter turns per stem (1 = 90° clockwise on screen). Empty when none.
    public var rotations: [String: Int]
    /// Per-(stem, field) Unix-ms stamps of the last change. Keys are
    /// UPPERCASED stems; a missing stamp reads as 0. Written as the additive
    /// `stamps` key, and only when non-empty.
    public private(set) var stamps: [String: [SessionField: Int64]]

    public init(version: Int, decisions: [String: Decision], lastIndex: Int, crops: [String: CropRect],
                tilts: [String: Double] = [:], rotations: [String: Int] = [:],
                stamps: [String: [SessionField: Int64]] = [:]) {
        self.version = version; self.decisions = decisions
        self.lastIndex = lastIndex; self.crops = crops
        self.tilts = tilts; self.rotations = rotations
        var normalized: [String: [SessionField: Int64]] = [:]
        for (stem, fields) in stamps {
            let kept = fields.filter { $0.value > 0 }
            guard !kept.isEmpty else { continue }
            normalized[stem.uppercased(), default: [:]].merge(kept) { current, _ in current }
        }
        self.stamps = normalized
    }

    /// Fresh empty session (version 1, no decisions, lastIndex 0).
    public static func fresh() -> Session {
        Session(version: 1, decisions: [:], lastIndex: 0, crops: [:])
    }

    /// Load from `folder/.photocull.json`; returns a fresh session when absent.
    /// A corrupt file also yields a fresh session; only I/O errors throw.
    public static func load(folder: URL, strict: Bool = false) throws -> Session {
        let url = folder.appendingPathComponent(Session.fileName)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Missing file → fresh (Go: os.IsNotExist → newSession()).
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError {
                return Session.fresh()
            }
            if ns.domain == NSPOSIXErrorDomain && ns.code == ENOENT {
                return Session.fresh()
            }
            throw error
        }

        return try decode(data: data, strict: strict)
    }

    /// Destructive callers decode the exact bytes captured from their pinned input.
    package static func decode(data: Data, strict: Bool) throws -> Session {
        guard !data.isEmpty else {
            if strict { throw SidecarError.invalid("empty sidecar") }
            return Session.fresh()
        }

        struct RawShape: Decodable {
            var version: Int?
            var decisions: [String: Decision]?
            var last_index: Int?
            var crops: [String: CropRect]?
            var tilts: [String: Double]?
            var rotations: [String: Int]?
            var stamps: [String: [String: Int64]]?
        }
        guard let raw = try? JSONDecoder().decode(RawShape.self, from: data) else {
            if strict { throw SidecarError.invalid("malformed sidecar") }
            return Session.fresh() // corrupt JSON must not crash
        }
        if strict, raw.version != 1 {
            throw SidecarError.invalid("unsupported sidecar version \(raw.version.map(String.init) ?? "missing")")
        }
        if strict {
            for keys in [Array((raw.decisions ?? [:]).keys), Array((raw.crops ?? [:]).keys),
                         Array((raw.tilts ?? [:]).keys), Array((raw.rotations ?? [:]).keys),
                         Array((raw.stamps ?? [:]).keys)] {
                guard Set(keys.map { $0.uppercased() }).count == keys.count else {
                    throw SidecarError.invalid("ambiguous case-folded stem keys")
                }
            }
        }
        var decisions: [String: Decision] = [:]
        for (k, v) in raw.decisions ?? [:] { decisions[k.uppercased()] = v }
        var crops: [String: CropRect] = [:]
        for (k, v) in raw.crops ?? [:] { crops[k.uppercased()] = v }
        var tilts: [String: Double] = [:]
        for (k, v) in raw.tilts ?? [:] { tilts[k.uppercased()] = v }
        var rotations: [String: Int] = [:]
        for (k, v) in raw.rotations ?? [:] { rotations[k.uppercased()] = v }
        var stamps: [String: [SessionField: Int64]] = [:]
        for (stem, fields) in raw.stamps ?? [:] {
            var parsed: [SessionField: Int64] = [:]
            // Unknown field names are additive keys from a later writer; ignore them.
            for (name, at) in fields { if let field = SessionField(rawValue: name) { parsed[field] = at } }
            stamps[stem.uppercased(), default: [:]].merge(parsed) { current, _ in current }
        }
        return Session(version: raw.version ?? 0,
                       decisions: decisions,
                       lastIndex: raw.last_index ?? 0,
                       crops: crops,
                       tilts: tilts,
                       rotations: rotations,
                       stamps: stamps)
    }

    /// Write to `folder/.photocull.json` with sorted keys and 2-space indent,
    /// byte-compatible with Go's `json.MarshalIndent`. `crops`, `tilts`,
    /// `rotations` and `stamps` are additive keys the Go app ignores; each is
    /// included only when non-empty.
    public func save(folder: URL) throws {
        var parts: [String] = []
        parts.append("  \"version\": \(version)")
        parts.append("  \"decisions\": \(Self.decisionsJSON(decisions))")
        parts.append("  \"last_index\": \(lastIndex)")
        if !crops.isEmpty { parts.append("  \"crops\": \(Self.cropsJSON(crops))") }
        if !tilts.isEmpty { parts.append("  \"tilts\": \(Self.tiltsJSON(tilts))") }
        if !rotations.isEmpty { parts.append("  \"rotations\": \(Self.rotationsJSON(rotations))") }
        if !stamps.isEmpty { parts.append("  \"stamps\": \(Self.stampsJSON(stamps))") }
        let out = "{\n" + parts.joined(separator: ",\n") + "\n}"
        let url = folder.appendingPathComponent(Session.fileName)
        try out.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    public enum SidecarError: Error, LocalizedError {
        case invalid(String)
        public var errorDescription: String? {
            if case .invalid(let reason) = self { return "Unsafe Finalize sidecar: \(reason)" }
            return nil
        }
    }

    public func get(_ stem: String) -> Decision {
        decisions[stem.uppercased()] ?? .undecided
    }

    // ── Sync stamps ────────────────────────────────────────────────────────

    /// Unix milliseconds "now" — the stamp a local change carries.
    public static func nowStamp() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }

    /// Stamp of the last change to a field; 0 when the field was never stamped.
    public func stamp(_ stem: String, _ field: SessionField) -> Int64 {
        stamps[stem.uppercased()]?[field] ?? 0
    }

    /// Record `at` as the field's stamp. Clearing a value keeps its stamp, so
    /// a clear can win over an older set.
    private func recordStamp(_ stem: String, _ field: SessionField, _ at: Int64) {
        guard at > 0 else { return }
        stamps[stem, default: [:]][field] = at
    }

    /// Set a decision. `at` defaults to now; pass an explicit stamp when
    /// replaying someone else's change.
    public func set(_ stem: String, _ decision: Decision, at stamp: Int64? = nil) {
        let key = stem.uppercased()
        decisions[key] = decision
        recordStamp(key, .decision, stamp ?? Self.nowStamp())
    }

    public func crop(for stem: String) -> CropRect? {
        crops[stem.uppercased()]
    }

    public func setCrop(_ stem: String, _ rect: CropRect?, at stamp: Int64? = nil) {
        let key = stem.uppercased()
        if let rect { crops[key] = rect } else { crops.removeValue(forKey: key) }
        recordStamp(key, .crop, stamp ?? Self.nowStamp())
    }

    public func tilt(for stem: String) -> Double {
        tilts[stem.uppercased()] ?? 0
    }

    /// `nil` (or a near-zero angle) removes the entry.
    public func setTilt(_ stem: String, _ degrees: Double?, at stamp: Int64? = nil) {
        let key = stem.uppercased()
        if let degrees, abs(degrees) >= 0.05 { tilts[key] = degrees } else { tilts.removeValue(forKey: key) }
        recordStamp(key, .tilt, stamp ?? Self.nowStamp())
    }

    public func quarterTurns(for stem: String) -> Int {
        rotations[stem.uppercased()] ?? 0
    }

    /// `nil` (or a multiple of 4) removes the entry.
    public func setQuarter(_ stem: String, _ turns: Int?, at stamp: Int64? = nil) {
        let key = stem.uppercased()
        let normalized = ((turns ?? 0) % 4 + 4) % 4
        if normalized != 0 { rotations[key] = normalized } else { rotations.removeValue(forKey: key) }
        recordStamp(key, .rotation, stamp ?? Self.nowStamp())
    }

    // ── Merge ─────────────────────────────────────────────────────────────

    /// Merge `incoming` into the receiver. Per (stem, field) the larger stamp
    /// wins; an equal stamp keeps the receiver's value — which is why the
    /// on-disk sidecar is always the receiver. `last_index` is not merged:
    /// `incoming` (the writer) supplies the cursor that gets written.
    public func merged(with incoming: Session) -> Session {
        let out = Session(version: version, decisions: decisions, lastIndex: incoming.lastIndex,
                          crops: crops, tilts: tilts, rotations: rotations, stamps: stamps)
        for field in SessionField.allCases {
            for stem in fieldStems(field).union(incoming.fieldStems(field)) {
                let theirs = incoming.stamp(stem, field)
                guard theirs > stamp(stem, field) else { continue }
                out.assign(field, from: incoming, stem: stem)
                out.recordStamp(stem, field, theirs)
            }
        }
        return out
    }

    /// Apply one incoming change with the merge rule: a stamp that is not
    /// larger than the stored one is ignored, so replays are idempotent.
    @discardableResult
    public func apply(_ change: SessionChange) -> Bool {
        guard change.at > stamp(change.stem, change.field) else { return false }
        switch (change.field, change.value) {
        case (.decision, .decision(let decision)): set(change.stem, decision, at: change.at)
        case (.crop, .crop(let rect)): setCrop(change.stem, rect, at: change.at)
        case (.tilt, .tilt(let degrees)): setTilt(change.stem, degrees, at: change.at)
        case (.rotation, .rotation(let turns)): setQuarter(change.stem, turns, at: change.at)
        default: return false
        }
        return true
    }

    /// Copy every field of `other` into this instance, keeping the object
    /// identity that undo edits and views capture.
    public func adopt(_ other: Session) {
        version = other.version
        decisions = other.decisions
        lastIndex = other.lastIndex
        crops = other.crops
        tilts = other.tilts
        rotations = other.rotations
        stamps = other.stamps
    }

    /// Content equality, ignoring object identity.
    public func hasSameContent(as other: Session) -> Bool {
        version == other.version && decisions == other.decisions && lastIndex == other.lastIndex
            && crops == other.crops && tilts == other.tilts && rotations == other.rotations
            && stamps == other.stamps
    }

    /// Stems that carry a value or a stamp for `field`, so a clear (no value,
    /// stamp kept) still takes part in the merge.
    private func fieldStems(_ field: SessionField) -> Set<String> {
        var stems = Set<String>()
        switch field {
        case .decision: stems.formUnion(decisions.keys)
        case .crop: stems.formUnion(crops.keys)
        case .tilt: stems.formUnion(tilts.keys)
        case .rotation: stems.formUnion(rotations.keys)
        }
        for (stem, fields) in stamps where fields[field] != nil { stems.insert(stem) }
        return stems
    }

    /// Copy one field's value (possibly a removal) from `other`.
    private func assign(_ field: SessionField, from other: Session, stem: String) {
        switch field {
        case .decision: decisions[stem] = other.decisions[stem]
        case .crop: crops[stem] = other.crops[stem]
        case .tilt: tilts[stem] = other.tilts[stem]
        case .rotation: rotations[stem] = other.rotations[stem]
        }
    }

    /// (keep, reject, undecided) counts over the given stems.
    public func statusCounts(stems: [String]) -> (keep: Int, reject: Int, undecided: Int) {
        var keep = 0, reject = 0, undecided = 0
        for stem in stems {
            switch get(stem) {
            case .keep: keep += 1
            case .reject: reject += 1
            case .undecided: undecided += 1
            }
        }
        return (keep, reject, undecided)
    }

    /// Folder-level rollup used by the sessions list. Only real decisions
    /// (keep/reject) count as decided — toggle-to-clear writes an `.undecided`
    /// value back into `decisions`, and a session where that happened must drop
    /// out of `complete`. (Deliberate divergence from Go, which counted mere
    /// presence as seen.)
    public func folderStatus(stems: [String]) -> FolderStatus {
        if stems.isEmpty { return .empty }
        let decided = stems.filter { get($0) != .undecided }.count
        if decided == 0 { return .unstarted }
        if decided == stems.count { return .complete }
        return .inProgress
    }

    // ── JSON serialization (hand-rolled for Go byte-compatibility) ──────────

    static func jsonEscape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out
    }

    /// Shortest numeric form, like Go's JSON encoder for float64.
    static func jsonNumber(_ v: Double) -> String {
        if v.isNaN || v.isInfinite { return "0" }
        if v == v.rounded() && abs(v) < 1e15 {
            return String(Int64(v))
        }
        return "\(v)"
    }

    static func decisionsJSON(_ decisions: [String: Decision]) -> String {
        if decisions.isEmpty { return "{}" }
        var lines: [String] = []
        for key in decisions.keys.sorted() {
            lines.append("    \"\(jsonEscape(key))\": \"\(decisions[key]!.rawValue)\"")
        }
        return "{\n" + lines.joined(separator: ",\n") + "\n  }"
    }

    static func cropJSON(_ rect: CropRect) -> String {
        "{\n" +
        "      \"x\": \(jsonNumber(rect.x)),\n" +
        "      \"y\": \(jsonNumber(rect.y)),\n" +
        "      \"w\": \(jsonNumber(rect.w)),\n" +
        "      \"h\": \(jsonNumber(rect.h))\n" +
        "    }"
    }

    static func cropsJSON(_ crops: [String: CropRect]) -> String {
        if crops.isEmpty { return "{}" }
        var lines: [String] = []
        for key in crops.keys.sorted() {
            lines.append("    \"\(jsonEscape(key))\": \(cropJSON(crops[key]!))")
        }
        return "{\n" + lines.joined(separator: ",\n") + "\n  }"
    }

    static func tiltsJSON(_ tilts: [String: Double]) -> String {
        if tilts.isEmpty { return "{}" }
        var lines: [String] = []
        for key in tilts.keys.sorted() {
            lines.append("    \"\(jsonEscape(key))\": \(jsonNumber(tilts[key]!))")
        }
        return "{\n" + lines.joined(separator: ",\n") + "\n  }"
    }

    static func rotationsJSON(_ rotations: [String: Int]) -> String {
        if rotations.isEmpty { return "{}" }
        var lines: [String] = []
        for key in rotations.keys.sorted() {
            lines.append("    \"\(jsonEscape(key))\": \(rotations[key]!)")
        }
        return "{\n" + lines.joined(separator: ",\n") + "\n  }"
    }

    static func stampsJSON(_ stamps: [String: [SessionField: Int64]]) -> String {
        if stamps.isEmpty { return "{}" }
        var lines: [String] = []
        for key in stamps.keys.sorted() {
            let fields = (stamps[key] ?? [:]).sorted { $0.key.rawValue < $1.key.rawValue }
            let inner = fields.map { "      \"\($0.key.rawValue)\": \($0.value)" }.joined(separator: ",\n")
            lines.append("    \"\(jsonEscape(key))\": {\n\(inner)\n    }")
        }
        return "{\n" + lines.joined(separator: ",\n") + "\n  }"
    }
}
