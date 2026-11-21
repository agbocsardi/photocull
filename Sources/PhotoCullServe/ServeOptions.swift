import Foundation
import PhotoCullCore
import PhotoCullServer

// ServeOptions.swift — the photocull-serve command line.
//
// Hand-rolled: five flags do not justify a dependency, and the deployment side
// (docs/REMOTE-CULL.md §6) needs a stable, tiny contract more than a parser.

struct ServeOptions {
    var real = false
    var dataRoot: String?
    var port = CullServer.defaultPort
    var tokenFile: String?
    var pwa: String?
    var help = false

    /// A malformed command line: message plus usage on stderr, exit 2.
    enum UsageError: Error, CustomStringConvertible {
        case message(String)

        var description: String {
            switch self {
            case .message(let text): return text
            }
        }
    }

    static let usage = """
    usage: photocull-serve [--real --data-root PATH] [--port N] --token-file PATH [--pwa DIR]

    Serve the PhotoCull HTTP API v1 and the phone web app on 127.0.0.1.

      --real              serve a real library (requires --data-root)
      --data-root PATH    library folder: inbox/, archive/ and dump/ live under it,
                          and it must hold the owner-created .photocull-serve-root
                          marker
      --port N            listen port (default \(CullServer.defaultPort))
      --token-file PATH   file holding the bearer token: a regular file (not a
                          symlink), not accessible by group or others, at least 32
                          characters
      --pwa DIR           phone web app folder (default: bundled or repository pwa/)
      -h, --help          show this help and exit

    Without --real this is a DEV host: it serves the throwaway library under
    \(PCConfig.abbreviateHome(LibraryMode.devRoot)), exactly like a dev build of
    the app. A DEV host never takes an arbitrary folder.
    """

    static func parse(_ arguments: [String]) throws -> ServeOptions {
        var options = ServeOptions()
        var index = 1

        func value(for flag: String) throws -> String {
            guard index + 1 < arguments.count else {
                throw UsageError.message("\(flag) requires a value")
            }
            index += 1
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                options.help = true
            case "--real":
                options.real = true
            case "--data-root":
                options.dataRoot = try value(for: argument)
            case "--port":
                let raw = try value(for: argument)
                guard let port = Int(raw), (1...65535).contains(port) else {
                    throw UsageError.message("--port needs a number between 1 and 65535, got \(raw)")
                }
                options.port = port
            case "--token-file":
                options.tokenFile = try value(for: argument)
            case "--pwa":
                options.pwa = try value(for: argument)
            default:
                throw UsageError.message("unknown argument \(argument)")
            }
            index += 1
        }

        guard !options.help else { return options }
        guard options.tokenFile != nil else {
            throw UsageError.message("--token-file is required")
        }
        if options.dataRoot != nil && !options.real {
            throw UsageError.message("--data-root is only for --real; a DEV host always uses "
                + PCConfig.abbreviateHome(LibraryMode.devRoot))
        }
        if options.real && options.dataRoot == nil {
            throw UsageError.message("--real requires --data-root PATH")
        }
        return options
    }
}
