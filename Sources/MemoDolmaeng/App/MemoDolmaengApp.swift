import AppKit

private var retainedAppDelegate: AppDelegate?

@main
struct MemoDolmaengApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()

        retainedAppDelegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
