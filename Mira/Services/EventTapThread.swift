import Foundation

/// A dedicated background thread hosting a CFRunLoop for `CGEventTap` sources.
///
/// Event taps must **not** be serviced on the main run loop. An active
/// `.cgSessionEventTap` whose run loop is busy stalls the events it's interested
/// in (keystrokes, media keys), and after ~1s macOS disables the tap entirely
/// (`kCGEventTapDisabledByTimeout`). During an agent build the main thread gets
/// busy (SwiftUI diffing, overlay redraws, step updates), so taps parked on the
/// main run loop turn laggy and then silently die. Hosting them here decouples
/// input handling from main-thread load so keystrokes/media keys stay crisp.
///
/// Thread-safe: `addSource`/`removeSource` may be called from any thread.
final class EventTapThread {
    static let shared = EventTapThread()

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()

    private init() {}

    /// Lazily spins up the thread and returns its run loop, blocking briefly
    /// until the run loop exists.
    private func runLoopBlocking() -> CFRunLoop {
        lock.lock()
        if let rl = runLoop { lock.unlock(); return rl }

        let t = Thread { [weak self] in
            guard let self else { return }
            // An NSMachPort keeps the run loop alive with no busy-spin; sources
            // added later from other threads are serviced here.
            let keepAlive = NSMachPort()
            RunLoop.current.add(keepAlive, forMode: .common)
            self.runLoop = CFRunLoopGetCurrent()
            self.ready.signal()
            CFRunLoopRun()
        }
        t.name = "com.mira.eventtap"
        t.qualityOfService = .userInteractive
        thread = t
        lock.unlock()

        t.start()
        ready.wait()
        return runLoop!
    }

    /// Adds a run-loop source (typically a `CGEventTap`'s mach-port source) to
    /// the dedicated thread's run loop.
    func addSource(_ source: CFRunLoopSource) {
        let rl = runLoopBlocking()
        CFRunLoopAddSource(rl, source, .commonModes)
        CFRunLoopWakeUp(rl)
    }

    /// Removes a previously added source.
    func removeSource(_ source: CFRunLoopSource) {
        guard let rl = runLoop else { return }
        CFRunLoopRemoveSource(rl, source, .commonModes)
        CFRunLoopWakeUp(rl)
    }
}
