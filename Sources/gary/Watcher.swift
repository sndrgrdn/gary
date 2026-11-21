import CoreServices
import Foundation

final class FileWatcher {
    private let queue = DispatchQueue(label: "gary.watch")
    private let quiet: TimeInterval
    private let onChange: (Set<String>, Trace) -> Void
    private var stream: FSEventStreamRef?
    private var pending: Set<String> = []
    private var firstEvent: Double?
    private var flush: DispatchWorkItem?

    init(root: URL, quiet: TimeInterval = 0.02, onChange: @escaping (Set<String>, Trace) -> Void) {
        self.quiet = quiet
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
        stream = FSEventStreamCreate(nil, { _, info, count, paths, _, _ in
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info!).takeUnretainedValue()
            let list = Unmanaged<NSArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            watcher.received(Array(list.prefix(count)))
        }, &context, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0, FSEventStreamCreateFlags(flags))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    private func received(_ paths: [String]) {
        let time = now()
        if firstEvent == nil { firstEvent = time }
        if tracing { log(String(format: "fs-event t0=%.6f paths=%@", time, paths.joined(separator: ","))) }
        pending.formUnion(paths)
        flush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let paths = pending, trace = Trace("fs", start: firstEvent ?? now())
            pending = []
            firstEvent = nil
            DispatchQueue.main.async { self.onChange(paths, trace) }
        }
        flush = work
        queue.asyncAfter(deadline: .now() + quiet, execute: work)
    }
}
