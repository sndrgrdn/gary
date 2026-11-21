import AppKit
import Carbon.HIToolbox
import GaryCore

extension Capability {
    static let paste = Capability(name: "paste", summary: "Paste the clipboard into the frontmost app.", types: """
    declare namespace Gary {
      interface Host { paste(): Promise<{ app: string | null; name: string | null }> }
    }
    """, permissions: [.accessibility], install: { host, plugin in
        plugin.installAPI(host, nil, ["paste"]) { _ in .later(.global(qos: .userInitiated)) { try pasteIntoFrontApp() } }
    })
}

private func pasteIntoFrontApp() throws -> JSON {
    guard CGPreflightPostEventAccess() else { throw HostFailure(missingGrant("Accessibility", "paste")) }
    let deadline = Date().addingTimeInterval(1)
    while NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), Date() < deadline { usleep(20_000) }
    let front = NSWorkspace.shared.frontmostApplication
    let source = CGEventSource(stateID: .combinedSessionState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
        event?.flags = .maskCommand
        event?.post(tap: .cgSessionEventTap)
    }
    return .object(["app": front?.bundleIdentifier.map(JSON.string) ?? .null, "name": front?.localizedName.map(JSON.string) ?? .null])
}
