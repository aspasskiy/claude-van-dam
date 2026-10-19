import Foundation

public struct LockTimeout: LocalizedError {
    let name: String
    public var errorDescription: String? {
        "Couldn't take \(name) — Claude Code is updating credentials. Try again in a few seconds."
    }
}

/// The app's own locks: `flock` on a file.
final class FileLock {
    private var fd: Int32 = -1

    init(_ url: URL, timeout: TimeInterval = 10) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw LockTimeout(name: url.lastPathComponent) }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if Date() > deadline {
                close(fd)
                fd = -1
                throw LockTimeout(name: url.lastPathComponent)
            }
            usleep(100_000)
        }
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}

/// Claude Code's locks: a directory whose mkdir is the mutex (npm
/// proper-lockfile). Stale only past `staleness`; never steal a younger one.
/// Held locks are touched every 3 s so others don't deem them stale
///.
final class DirLock {
    private let url: URL
    private var toucher: DispatchSourceTimer?
    private var held = false

    init(_ url: URL, staleness: TimeInterval, timeout: TimeInterval = 9) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let deadline = Date().addingTimeInterval(timeout)
        while mkdir(url.path, 0o755) != 0 {
            guard errno == EEXIST else { throw LockTimeout(name: url.lastPathComponent) }
            if Date() > deadline { throw LockTimeout(name: url.lastPathComponent) }
            var st = stat()
            if stat(url.path, &st) != 0 { continue } // released between mkdir and stat
            let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
            if Date().timeIntervalSince1970 - mtime > staleness {
                if rmdir(url.path) != 0 { usleep(50_000) }
                continue
            }
            usleep(useconds_t(250_000 + Int.random(in: 0..<250_000)))
        }
        held = true
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 3, repeating: 3)
        let path = url.path
        timer.setEventHandler { utimes(path, nil) }
        timer.resume()
        toucher = timer
    }

    func release() {
        guard held else { return }
        toucher?.cancel()
        toucher = nil
        rmdir(url.path)
        held = false
    }

    deinit { release() }
}

/// The full switch lock set, in order: the global
/// `.lock`, Claude Code's two credential locks, then its config lock.
final class SwitchLocks {
    private var file: FileLock?
    private var dirs: [DirLock] = []

    init(paths: Paths) throws {
        file = try FileLock(paths.globalLock)
        do {
            dirs.append(try DirLock(paths.oauthRefreshLock, staleness: 60))
            dirs.append(try DirLock(paths.credentialsLock, staleness: 60))
            dirs.append(try DirLock(paths.configLock, staleness: 10))
        } catch {
            release()
            throw error
        }
    }

    func release() {
        for d in dirs.reversed() { d.release() }
        dirs.removeAll()
        file?.release()
        file = nil
    }

    deinit { release() }
}
