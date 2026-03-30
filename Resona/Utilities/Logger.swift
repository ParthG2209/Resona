import Foundation
import os.log

// MARK: - Logger

/// Unified logging. Uses os.log in production, prints in debug.
enum Logger {

    private static let subsystem = Constants.App.bundleIdentifier

    // Static constants — allocated exactly once for the entire app lifetime.
    // Previously the LogCategory.log computed property called OSLog(subsystem:category:)
    // on every single log statement, creating a new OSLog object each time.
    // OSLog objects are expensive to construct and are meant to be long-lived constants.
    static let general    = OSLog(subsystem: subsystem, category: "General")
    static let spotify    = OSLog(subsystem: subsystem, category: "Spotify")
    static let appleMusic = OSLog(subsystem: subsystem, category: "AppleMusic")
    static let wallpaper  = OSLog(subsystem: subsystem, category: "Wallpaper")
    static let cache      = OSLog(subsystem: subsystem, category: "Cache")

    static func info(_ message: String, category: LogCategory = .general) {
        guard AppSettings.shared.enableDebugLogging else { return }
        os_log("%{public}@", log: category.log, type: .info, message)
    }

    static func debug(_ message: String, category: LogCategory = .general) {
        #if DEBUG
        os_log("%{public}@", log: category.log, type: .debug, message)
        #endif
    }

    static func error(_ message: String, category: LogCategory = .general) {
        os_log("%{public}@", log: category.log, type: .error, message)
    }

    static func fault(_ message: String, category: LogCategory = .general) {
        os_log("%{public}@", log: category.log, type: .fault, message)
    }
}

// MARK: - LogCategory

enum LogCategory {
    case general, spotify, appleMusic, wallpaper, cache

    // Returns the pre-allocated static constant instead of constructing a new
    // OSLog object on every invocation. This is the correct pattern per Apple's
    // os.log documentation: "Create log objects once and reuse them."
    var log: OSLog {
        switch self {
        case .general:    return Logger.general
        case .spotify:    return Logger.spotify
        case .appleMusic: return Logger.appleMusic
        case .wallpaper:  return Logger.wallpaper
        case .cache:      return Logger.cache
        }
    }
}