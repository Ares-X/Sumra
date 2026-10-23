#if os(macOS)
import Foundation
import Darwin

// Native bookmarks follow the same file across Finder moves and renames.
// A replacement chosen in Relocate is an explicit association made by the user.
enum DocumentFileIdentity {
    private struct Identity: Codable {
        var bookmark: Data
        var volumeUUID: String
        var fileID: UInt64
        var bornSeconds: Int64
        var bornNanoseconds: Int64
    }

    static func bookmark(for url: URL) -> Data? {
        var file = stat()
        guard stat(url.path, &file) == 0,
              let volumeUUID = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
              let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: [.volumeUUIDStringKey], relativeTo: nil) else { return nil }
        return try? JSONEncoder().encode(Identity(bookmark: bookmark, volumeUUID: volumeUUID, fileID: file.st_ino,
            bornSeconds: Int64(file.st_birthtimespec.tv_sec), bornNanoseconds: Int64(file.st_birthtimespec.tv_nsec)))
    }

    static func resolve(_ bookmark: Data) -> URL? {
        guard let identity = try? JSONDecoder().decode(Identity.self, from: bookmark) else { return nil }
        var stale = false
        let bookmarkedURL = try? URL(resolvingBookmarkData: identity.bookmark, options: [.withoutUI, .withoutMounting],
                                     relativeTo: nil, bookmarkDataIsStale: &stale)
        // Foundation can prefer the old pathname after another file has reused
        // it. Use the bookmark to locate its volume, then ask the filesystem for
        // the captured object ID instead of adopting that pathname's new file.
        let volumeURL: URL?
        if let bookmarkedURL, (try? bookmarkedURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == identity.volumeUUID {
            var file = stat()
            if stat(bookmarkedURL.path, &file) == 0, file.st_ino == identity.fileID,
               Int64(file.st_birthtimespec.tv_sec) == identity.bornSeconds,
               Int64(file.st_birthtimespec.tv_nsec) == identity.bornNanoseconds {
                return bookmarkedURL.standardizedFileURL
            }
            volumeURL = bookmarkedURL
        } else {
            volumeURL = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey])?.first {
                (try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString) == identity.volumeUUID
            }
        }
        guard let volumeURL else { return nil }
        var volume = statfs()
        guard statfs(volumeURL.path, &volume) == 0 else { return nil }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fsgetpath(&path, path.count, &volume.f_fsid, identity.fileID) > 0 else { return nil }
        let url = URL(fileURLWithPath: String(cString: path))
        var file = stat()
        guard stat(url.path, &file) == 0, file.st_ino == identity.fileID,
              Int64(file.st_birthtimespec.tv_sec) == identity.bornSeconds,
              Int64(file.st_birthtimespec.tv_nsec) == identity.bornNanoseconds else { return nil }
        return url.standardizedFileURL
    }
}
#endif
