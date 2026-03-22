import Foundation
import os.log

// MARK: - Logger

/// Unified logging. Uses os.log in production, prints in debug.
enum Logger {

    private static let subsystem = Constants.App.bundleIdentifier

    private static let general  = OSLog(subsystem: subsystem, category: "General")
    private static let spotify  = OSLog(subsystem: subsystem, category: "Spotify")
    private static let appleMusic = OSLog(subsystem: subsystem, category: "AppleMusic")
    private static let wallpaper  = OSLog(subsystem: subsystem, category: "Wallpaper")
    private static let cache    = OSLog(subsystem: subsystem, category: "Cache")

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

    var log: OSLog {
        let subsystem = Constants.App.bundleIdentifier
        switch self {
        case .general:    return OSLog(subsystem: subsystem, category: "General")
        case .spotify:    return OSLog(subsystem: subsystem, category: "Spotify")
        case .appleMusic: return OSLog(subsystem: subsystem, category: "AppleMusic")
        case .wallpaper:  return OSLog(subsystem: subsystem, category: "Wallpaper")
        case .cache:      return OSLog(subsystem: subsystem, category: "Cache")
        }
    }
}
