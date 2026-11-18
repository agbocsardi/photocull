import Foundation

@main struct FinalizeCoreChecks {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count == 2 && args[0] == "--flock-probe" {
            finalizeLockProbe(args[1]); return
        }
        try suiteFinalizePlanningChecks()
        if args != ["--planning-only"] { try suiteFinalizeFailureChecks() }
    }
}
