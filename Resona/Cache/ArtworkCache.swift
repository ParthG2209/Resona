import Foundation

// MARK: - ArtworkCache

/// Manages on-disk artwork files with LRU eviction and expiry.
final class ArtworkCache {

    static let shared = ArtworkCache()

    // MARK: - Properties

    private let fileManager = FileManager.default
    private let cacheRoot: URL
    private let maxSizeBytes: Int

    private init() {
        // ~/Library/Caches/com.resona.app/artwork/
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheRoot = caches
            .appendingPathComponent(Constants.App.bundleIdentifier)
            .appendingPathComponent(Constants.Cache.directoryName)

        maxSizeBytes = AppSettings.shared.maxCacheSizeMB * 1_048_576

        createDirectoriesIfNeeded()
        cleanExpiredFiles()
    }

    // MARK: - Public API

    /// Store raw data for a given cache key. Returns the local URL if successful.
    func store(data: Data, for key: CacheKey) -> URL? {
        let subdir = cacheRoot.appendingPathComponent(key.source.rawValue)
        let fileURL = subdir.appendingPathComponent(key.filename)

        do {
            try data.write(to: fileURL, options: .atomic)
            enforceMaxSize()
            Logger.info("Cached: \(key.filename)", category: .cache)
            return fileURL
        } catch {
            Logger.error("Cache write failed: \(error)", category: .cache)
            return nil
        }
    }

    /// Returns local URL if the artwork is already cached (and not expired).
    func retrieve(for key: CacheKey) -> URL? {
        let subdir = cacheRoot.appendingPathComponent(key.source.rawValue)
        let fileURL = subdir.appendingPathComponent(key.filename)

        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        // Touch modification date to mark as recently used (LRU)
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
        return fileURL
    }

    /// Delete all cached files.
    func clearAll() {
        try? fileManager.removeItem(at: cacheRoot)
        createDirectoriesIfNeeded()
        Logger.info("Cache cleared", category: .cache)
    }

    // MARK: - Directory Setup

    private func createDirectoriesIfNeeded() {
        let subdirs = [
            cacheRoot.appendingPathComponent(MusicSource.spotify.rawValue),
            cacheRoot.appendingPathComponent(MusicSource.appleMusic.rawValue)
        ]
        for dir in subdirs {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Expiry

    private func cleanExpiredFiles() {
        let expiryDate = Calendar.current.date(
            byAdding: .day,
            value: -Constants.Cache.expiryDays,
            to: Date()
        )!

        guard let enumerator = fileManager.enumerator(
            at: cacheRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var cleaned = 0
        for case let fileURL as URL in enumerator {
            guard let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = attrs.contentModificationDate,
                  modified < expiryDate
            else { continue }
            try? fileManager.removeItem(at: fileURL)
            cleaned += 1
        }

        if cleaned > 0 {
            Logger.info("Cleaned \(cleaned) expired cache files", category: .cache)
        }
    }

    // MARK: - Size Enforcement (LRU Eviction)

    private func enforceMaxSize() {
        var files = allCachedFiles()

        let totalSize = files.reduce(0) { $0 + ($1.fileSize ?? 0) }
        guard totalSize > maxSizeBytes else { return }

        // Sort by oldest modification date first (LRU)
        files.sort { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }

        var freed = 0
        var currentSize = totalSize
        for file in files {
            guard currentSize > maxSizeBytes else { break }
            try? fileManager.removeItem(at: file.url)
            currentSize -= file.fileSize ?? 0
            freed += 1
        }

        Logger.info("LRU eviction: removed \(freed) files to stay under \(AppSettings.shared.maxCacheSizeMB)MB", category: .cache)
    }

    private func allCachedFiles() -> [CachedFile] {
        guard let enumerator = fileManager.enumerator(
            at: cacheRoot,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        return (enumerator.allObjects as? [URL] ?? []).compactMap { url -> CachedFile? in
            guard let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            else { return nil }
            return CachedFile(url: url, fileSize: attrs.fileSize, modificationDate: attrs.contentModificationDate)
        }
    }
}

private struct CachedFile {
    let url: URL
    let fileSize: Int?
    let modificationDate: Date?
}
