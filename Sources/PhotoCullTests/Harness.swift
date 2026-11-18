import Foundation
import Darwin

/// Tiny test harness (XCTest is unavailable in a CommandLineTools-only toolchain).

public final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) { self.value = value }

    @discardableResult
    public func update<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    public func snapshot() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

nonisolated(unsafe) var pcFailures: [String] = []
nonisolated(unsafe) var pcChecks = 0

public func check(_ cond: Bool, _ msg: String, file: String = #fileID, line: Int = #line) {
    pcChecks += 1
    if cond {
        print("  ok   \(msg)")
    } else {
        let where_ = "\(file):\(line)"
        pcFailures.append("\(msg)  [\(where_)]")
        print("  FAIL \(msg)  [\(where_)]")
    }
}

public func checkEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String,
                                     file: String = #fileID, line: Int = #line) {
    check(a == b, "\(msg) (got \(a), want \(b))", file: file, line: line)
}

public func checkClose(_ a: Double, _ b: Double, _ tol: Double = 0.001, _ msg: String,
                       file: String = #fileID, line: Int = #line) {
    check(abs(a - b) <= tol, "\(msg) (got \(a), want \(b)±\(tol))", file: file, line: line)
}

public func suite(_ name: String, _ body: () throws -> Void) {
    print("\n== \(name) ==")
    do { try body() } catch { pcFailures.append("\(name) threw: \(error)"); print("  THREW \(error)") }
}

/// Create a unique temp directory; callers own its cleanup.
public func makeTempDir(_ tag: String) throws -> URL {
    let base = ProcessInfo.processInfo.environment["PC_TEST_ROOT"] ?? NSTemporaryDirectory()
    let url = URL(fileURLWithPath: base, isDirectory: true)
        .appendingPathComponent("pc-\(tag)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

public func touch(_ url: URL, bytes: Int = 8) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: bytes).write(to: url)
}

/// Kernel-canonical path spelling (realpath of the deepest existing ancestor,
/// plus any not-yet-existing suffix) — matches how Core's Finalize canonicalises
/// configured roots before reporting paths, so expectations can compare against
/// the spelling the product actually returns on symlinked roots like /var.
public func canonicalPath(_ url: URL) -> String {
    var ancestor = url.path, suffix = ""
    while ancestor != "/" {
        var st = stat()
        if lstat(ancestor, &st) == 0 { break }
        guard errno == ENOENT else { return url.path }
        suffix = "/" + (ancestor as NSString).lastPathComponent + suffix
        ancestor = (ancestor as NSString).deletingLastPathComponent
    }
    guard let resolved = realpath(ancestor, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved) + suffix
}

/// URL of the bundled fixture images (the photocull repo's test JPEGs).
public func fixtureURL(_ name: String) -> URL? {
    let bases = [
        ProcessInfo.processInfo.environment["PC_FIXTURES"],
        FileManager.default.currentDirectoryPath + "/testdata",
        NSHomeDirectory() + "/Documents/1-projects/photocull/tests/fixtures",
    ].compactMap { $0 }
    for b in bases {
        let u = URL(fileURLWithPath: b).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: u.path) { return u }
    }
    return nil
}
