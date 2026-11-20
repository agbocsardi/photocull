import Foundation

// Wire types for HTTP API v1 as specified in docs/REMOTE-CULL.md §3.
// Field names, value ranges and null-ness are part of that contract: do not
// rename a property without changing the contract and the PWA together.

/// Body of `GET /api/health`.
public struct HealthResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var api: Int
    public var name: String

    public init(ok: Bool = true, api: Int = 1, name: String) {
        self.ok = ok
        self.api = api
        self.name = name
    }
}

/// Session rollup shown by `GET /api/sessions`.
public enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case empty
    case unstarted
    case inProgress = "in progress"
    case complete
}

public struct SessionSummary: Codable, Sendable, Equatable {
    public var date: String
    public var total: Int
    public var keep: Int
    public var reject: Int
    public var undecided: Int
    public var status: SessionStatus

    public init(date: String, total: Int, keep: Int, reject: Int, undecided: Int, status: SessionStatus) {
        self.date = date
        self.total = total
        self.keep = keep
        self.reject = reject
        self.undecided = undecided
        self.status = status
    }
}

/// Body of `GET /api/sessions`.
public struct SessionsResponse: Codable, Sendable, Equatable {
    public var sessions: [SessionSummary]

    public init(sessions: [SessionSummary]) {
        self.sessions = sessions
    }
}

/// A decision as stored in the sidecar.
public enum DecisionValue: String, Codable, Sendable, CaseIterable {
    case keep
    case reject
    case undecided
}

/// Crop rectangle in source-photo coordinates.
public struct CropRect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

/// One photo inside `GET /api/sessions/{date}`.
///
/// `crop` is encoded as an explicit `null` when unset, as the contract requires.
public struct SessionPhoto: Codable, Sendable, Equatable {
    public var stem: String
    public var hasRaw: Bool
    /// Always present; `undecided` when the sidecar has no decision.
    public var decision: DecisionValue
    public var rotation: Int
    public var tilt: Double
    public var crop: CropRect?
    /// Preview URL including the `?v=<etag>` cache buster.
    public var preview: String

    public init(stem: String, hasRaw: Bool, decision: DecisionValue, rotation: Int,
                tilt: Double, crop: CropRect?, preview: String) {
        self.stem = stem
        self.hasRaw = hasRaw
        self.decision = decision
        self.rotation = rotation
        self.tilt = tilt
        self.crop = crop
        self.preview = preview
    }

    private enum CodingKeys: String, CodingKey {
        case stem, hasRaw, decision, rotation, tilt, crop, preview
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.stem = try container.decode(String.self, forKey: .stem)
        self.hasRaw = try container.decode(Bool.self, forKey: .hasRaw)
        self.decision = try container.decodeIfPresent(DecisionValue.self, forKey: .decision) ?? .undecided
        self.rotation = try container.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        self.tilt = try container.decodeIfPresent(Double.self, forKey: .tilt) ?? 0
        self.crop = try container.decodeIfPresent(CropRect.self, forKey: .crop)
        self.preview = try container.decode(String.self, forKey: .preview)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.stem, forKey: .stem)
        try container.encode(self.hasRaw, forKey: .hasRaw)
        try container.encode(self.decision, forKey: .decision)
        try container.encode(self.rotation, forKey: .rotation)
        try container.encode(self.tilt, forKey: .tilt)
        if let crop = self.crop {
            try container.encode(crop, forKey: .crop)
        } else {
            try container.encodeNil(forKey: .crop)
        }
        try container.encode(self.preview, forKey: .preview)
    }
}

/// Body of `GET /api/sessions/{date}` and `POST /api/sessions/{date}/changes`.
public struct SessionDetail: Codable, Sendable, Equatable {
    public var date: String
    /// Opaque revision that changes whenever the sidecar changes.
    public var rev: String
    public var lastIndex: Int
    /// Ascending stem, the order the Mac app shows.
    public var photos: [SessionPhoto]

    public init(date: String, rev: String, lastIndex: Int, photos: [SessionPhoto]) {
        self.date = date
        self.rev = rev
        self.lastIndex = lastIndex
        self.photos = photos
    }

    private enum CodingKeys: String, CodingKey {
        case date, rev, photos
        case lastIndex = "last_index"
    }
}

/// A validated change ready to be applied by a backend.
///
/// `at` is already clamped to the server clock by the time a backend sees it.
public struct SessionChange: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case decision(DecisionValue)
        case rotation(Int)
    }

    public var stem: String
    public var value: Value
    /// Unix milliseconds, clamped to at most the server's now + 60 s.
    public var at: Int64

    public init(stem: String, value: Value, at: Int64) {
        self.stem = stem
        self.value = value
        self.at = at
    }
}
