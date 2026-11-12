import CoreServices
import Foundation

/// FSEvents stream over the scanned root; delivers changed directory paths on the main queue.
final class LiveWatcher {
    typealias Handler = (_ paths: [String], _ flags: [FSEventStreamEventFlags]) -> Void

    private var stream: FSEventStreamRef?
    private let path: String
    private let handler: Handler

    init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<LiveWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let flagList = Array(UnsafeBufferPointer(start: flags, count: count))
            watcher.handler(list, flagList)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0, flags) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
