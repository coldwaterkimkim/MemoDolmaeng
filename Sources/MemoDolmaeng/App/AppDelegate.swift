import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: NoteStore?
    private var workspace: EdgeWorkspaceController?
    private var statusItemController: StatusItemController?
    private var globalHotkeyController: GlobalHotkeyController?
    private var libraryWindowController: LibraryWindowController?
    private var preferencesWindowController: PreferencesWindowController?
    private var createNoteObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        do {
            let store = try makeStore()
            if let persistenceError = store.lastPersistenceError { throw persistenceError }

            let edgePreferences = EdgePreferences.shared
            let workspace = EdgeWorkspaceController(store: store, preferences: edgePreferences)
            let library = LibraryWindowController(workspace: workspace)
            let settings = PreferencesWindowController(
                workspace: workspace,
                edgePreferences: edgePreferences,
                editorPreferences: AppPreferences.shared
            )
            let status = StatusItemController()

            status.onCreateNote = { [weak workspace] in workspace?.createNote() }
            status.onToggleRecent = { [weak workspace] in workspace?.toggleRecent() }
            status.onShowLibrary = { [weak library] in library?.show() }
            status.onShowSettings = { [weak settings] in settings?.show() }
            workspace.onShowLibrary = { [weak library] in library?.show() }
            workspace.onPresentationChange = { [weak status] isOpen in status?.setPanelOpen(isOpen) }

            self.store = store
            self.workspace = workspace
            statusItemController = status
            libraryWindowController = library
            preferencesWindowController = settings
            do {
                globalHotkeyController = try GlobalHotkeyController { [weak workspace] in
                    workspace?.toggleRecent()
                }
            } catch {
                presentHotkeyAlert(error: error)
            }
            createNoteObserver = NotificationCenter.default.addObserver(
                forName: .memoDolmaengCreateNoteRequested,
                object: nil,
                queue: .main
            ) { [weak workspace] _ in
                Task { @MainActor in workspace?.createNote() }
            }

            workspace.start()
        } catch {
            presentRecoveryAlert(error: error)
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard workspace?.prepareForTermination() != false else { return .terminateCancel }
        if let createNoteObserver { NotificationCenter.default.removeObserver(createNoteObserver) }
        return .terminateNow
    }

    @objc private func newNote(_ sender: Any?) { workspace?.createNote() }
    @objc private func foldMemo(_ sender: Any?) { workspace?.closeMemo() }
    @objc private func showLibrary(_ sender: Any?) { libraryWindowController?.show() }
    @objc private func showPreferences(_ sender: Any?) { preferencesWindowController?.show() }

    private func makeStore() throws -> NoteStore {
        if let injectedDirectory = ProcessInfo.processInfo.environment["MEMODOLMAENG_DATA_DIR"],
           !injectedDirectory.isEmpty {
            let url = URL(fileURLWithPath: injectedDirectory, isDirectory: true)
                .appendingPathComponent("notes.json", isDirectory: false)
            return try NoteStore(persistenceURL: url)
        }
        return try NoteStore()
    }

    private func presentRecoveryAlert(error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "메모 데이터를 안전하게 열지 못했어"
        alert.informativeText = "기존 notes.json은 건드리지 않았고 앱도 열지 않았어. Backups 폴더와 원본 파일을 보존한 채 다시 시도해줘.\n\n오류: \(error.localizedDescription)"
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    private func presentHotkeyAlert(error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "전역 단축키를 등록하지 못했어"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu(title: "Main Menu")

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "메모돌맹")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        appMenu.addItem(withTitle: "메모돌맹 정보", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "설정…", action: #selector(showPreferences(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "메모돌맹 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "파일")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        let newNote = NSMenuItem(title: "새 메모", action: #selector(newNote(_:)), keyEquivalent: "n")
        newNote.target = self
        fileMenu.addItem(newNote)
        let fold = NSMenuItem(title: "현재 메모 접기", action: #selector(foldMemo(_:)), keyEquivalent: "w")
        fold.target = self
        fileMenu.addItem(fold)
        fileMenu.addItem(.separator())
        let library = NSMenuItem(title: "보관함", action: #selector(showLibrary(_:)), keyEquivalent: "l")
        library.target = self
        fileMenu.addItem(library)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "편집")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        editMenu.addItem(NSMenuItem(title: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "다시 실행", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "붙이기", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        NSApp.mainMenu = mainMenu
    }
}
