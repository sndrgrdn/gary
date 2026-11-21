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

    init(roots: [URL], quiet: TimeInterval = 0.02, onChange: @escaping (Set<String>, Trace) -> Void) {
        self.quiet = quiet
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil,
        )
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
        stream = FSEventStreamCreate(
            nil,
            { _, info, count, paths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
                let list = Unmanaged<NSArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
                watcher.received(Array(list.prefix(count)))
            },
            &context,
            roots.map { $0.resolvingSymlinksInPath().path } as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0,
            FSEventStreamCreateFlags(flags),
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            flush?.cancel()
        }
    }

    private func received(_ paths: [String]) {
        let time = now()
        if firstEvent == nil {
            firstEvent = time
        }
        if tracing {
            log(String(format: "fs-event t0=%.6f paths=%@", time, paths.joined(separator: ",")))
        }
        pending.formUnion(paths)
        flush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let paths = pending
            let trace = Trace("fs", start: firstEvent ?? now())
            pending = []
            firstEvent = nil
            DispatchQueue.main.async { self.onChange(paths, trace) }
        }
        flush = work
        queue.asyncAfter(deadline: .now() + quiet, execute: work)
    }
}

final class PathWatch {
    private let paths: [String]
    private let queue: DispatchQueue
    private let onChange: () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?

    init(_ paths: [String], queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.paths = paths
        self.queue = queue
        self.onChange = onChange
        queue.async { [weak self] in self?.arm() }
    }

    func stop() {
        queue.async { [self] in
            pending?.cancel()
            for source in sources {
                source.cancel()
            }
            sources = []
        }
    }

    private func arm() {
        for source in sources {
            source.cancel()
        }
        sources = paths.compactMap { path in
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .delete, .rename, .attrib],
                queue: queue,
            )
            source.setEventHandler { [weak self] in self?.changed() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            return source
        }
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.arm()
            self?.onChange()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}
