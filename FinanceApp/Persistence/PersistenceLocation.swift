import Foundation

/// Where the store lives, and making sure the place exists before anything
/// tries to write there.
///
/// **The bug this exists for.** On a freshly installed device the container
/// has `Library` but not `Library/Application Support`. SwiftData opens a
/// store there happily — opening does not need the directory — and the failure
/// only appears at the first `save()`, which rolls back. From the person's
/// side that looks like an import that validated, previewed, reported its
/// counts, and then silently kept nothing; relaunching the app fixed it,
/// because by then something else had created the directory. "Works after a
/// relaunch" is not a fix: the first import is the one that matters, and a
/// person doing it once and seeing nothing has no reason to try again.
///
/// So the directory is created before the container is opened, not after a
/// write has already failed.
enum PersistenceLocation {

    enum Failure: Error, CustomStringConvertible {
        case noApplicationSupportDirectory
        case couldNotCreate(String)

        var description: String {
            switch self {
            case .noApplicationSupportDirectory:
                "The system did not report an Application Support directory."
            case let .couldNotCreate(reason):
                "The store directory could not be created: \(reason)"
            }
        }
    }

    /// Ensures Application Support exists, and returns it.
    ///
    /// `withIntermediateDirectories: true` also makes this succeed when the
    /// directory is already there, so it is safe on every launch rather than
    /// only the first.
    @discardableResult
    static func prepareApplicationSupport(
        using fileManager: FileManager = .default
    ) throws -> URL {
        guard let directory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw Failure.noApplicationSupportDirectory
        }
        try prepare(directory, using: fileManager)
        return directory
    }

    /// Ensures one directory exists, and that it really is a directory.
    ///
    /// A file sitting where the directory should be would let `createDirectory`
    /// "succeed" against an existing path and then fail every write after it,
    /// which is the same invisible failure again in a different disguise.
    static func prepare(_ directory: URL, using fileManager: FileManager = .default) throws {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw Failure.couldNotCreate(String(describing: error))
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw Failure.couldNotCreate("\(directory.lastPathComponent) is not a directory")
        }
    }
}
