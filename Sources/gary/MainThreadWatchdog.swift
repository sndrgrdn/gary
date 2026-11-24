#if DEBUG
    import Foundation
    import Synchronization

    final nonisolated class MainThreadWatchdog: @unchecked Sendable {
        static let threshold: UInt64 = 16_000_000
        private static let poll: useconds_t = 2000
        private static let depth = 48

        private let thread: thread_act_t
        private let stack: ClosedRange<UInt>
        private let beat = Atomic<UInt64>(0)
        private let waiting = Atomic(false)
        private let awake = DispatchSemaphore(value: 0)
        private let frames = UnsafeMutableBufferPointer<UInt>.allocate(capacity: depth)

        @MainActor
        static func start() {
            let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
            let watchdog = MainThreadWatchdog(thread: mach_thread_self(), stack: (top - UInt(pthread_get_stacksize_np(pthread_self())))...top)
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, CFIndex.max) { _, activity in
                watchdog.observe(activity)
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            let watcher = Thread { watchdog.watch() }
            watcher.name = "gary.watchdog"
            watcher.qualityOfService = .userInteractive
            watcher.start()
            log("main thread watchdog: logs stalls over \(threshold / 1_000_000) ms")
        }

        private init(thread: thread_act_t, stack: ClosedRange<UInt>) {
            self.thread = thread
            self.stack = stack
            beat.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), ordering: .sequentiallyConsistent)
        }

        private func observe(_ activity: CFRunLoopActivity) {
            beat.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), ordering: .sequentiallyConsistent)
            if activity == .afterWaiting {
                waiting.store(false, ordering: .sequentiallyConsistent)
                awake.signal()
            } else if activity == .beforeWaiting {
                waiting.store(true, ordering: .sequentiallyConsistent)
            }
        }

        private func watch() {
            var last = beat.load(ordering: .sequentiallyConsistent)
            var sample: [String]?
            while true {
                usleep(Self.poll)
                let idle = waiting.load(ordering: .sequentiallyConsistent)
                let current = beat.load(ordering: .sequentiallyConsistent)
                if current != last {
                    if let sample {
                        report(current - last, sample)
                    }
                    sample = nil
                    last = current
                } else if idle {
                    awake.wait()
                    last = beat.load(ordering: .sequentiallyConsistent)
                } else if sample == nil, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - last > Self.threshold {
                    sample = self.sample()
                }
            }
        }

        private func report(_ stalled: UInt64, _ sample: [String]) {
            let frames = sample.enumerated().map { "  \($0.offset) \($0.element)" }.joined(separator: "\n")
            log(String(format: "main thread stalled %.1f ms:\n", Double(stalled) / 1_000_000) + frames)
        }

        private func sample() -> [String] {
            guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
            let count = walk()
            thread_resume(thread)
            return frames.prefix(count).map(symbol)
        }

        private func walk() -> Int {
            var state = arm_thread_state64_t()
            var size = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
            let read = withUnsafeMutablePointer(to: &state) { pointer in
                pointer.withMemoryRebound(to: natural_t.self, capacity: Int(size)) { thread_get_state(thread, ARM_THREAD_STATE64, $0, &size) }
            }
            guard read == KERN_SUCCESS else { return 0 }
            frames[0] = Self.strip(state.__pc)
            frames[1] = Self.strip(state.__lr)
            var count = 2
            var frame = UInt(state.__fp)
            while count < Self.depth, stack.contains(frame), stack.contains(frame + 16), frame.isMultiple(of: 8) {
                guard let record = UnsafePointer<UInt>(bitPattern: frame) else { break }
                let caller = Self.strip(UInt64(record[1]))
                if count > 2 || caller != frames[1] {
                    frames[count] = caller
                    count += 1
                }
                guard record[0] > frame else { break }
                frame = record[0]
            }
            return count
        }

        private static func strip(_ address: UInt64) -> UInt {
            UInt(address & 0x7FFF_FFFF_FFFF)
        }

        private func symbol(_ address: UInt) -> String {
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else { return String(format: "0x%lx", address) }
            let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
            guard let name = info.dli_sname else { return String(format: "%@ 0x%lx", image, address) }
            return String(format: "%@ %@ + %ld", image, String(cString: name), address - UInt(bitPattern: info.dli_saddr))
        }
    }
#endif
