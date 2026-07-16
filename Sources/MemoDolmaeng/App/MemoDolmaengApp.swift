import AppKit
import Darwin

private var retainedAppDelegate: AppDelegate?

@main
struct MemoDolmaengApp {
    static func main() {
        setenv("MD_PERF", "0", 1)
        let application = NSApplication.shared
        let delegate = AppDelegate()

        retainedAppDelegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
