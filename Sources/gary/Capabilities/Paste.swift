import AppKit
import Carbon.HIToolbox
import GaryCore

extension Capability {
    static let paste = Capability(name: "paste", summary: "Paste the clipboard into the frontmost app.", types: """
    declare namespace Gary {
      interface Host { paste(): Promise<{ app: string | null; name: string | null }> }
    }
    """, example: """
    const snippets = ["Thanks!", "Looks good to me."];

    module.exports = {
      render() {
        return { type: "column", children: snippets.map((text) => ({ type: "text", key: text, text, action: text })) };
      },
      onAction(text) {
        host.clipboard.writeText(text);
        host.hide();
        host.paste().then((target) => host.log(`pasted into ${target.name}`)).catch((error) => host.log(String(error)));
      },
    } satisfies Gary.Menu;
    """, permissions: [.accessibility], install: { host, plugin in
        plugin.installAPI(host, nil, ["paste"]) { _ in .later(.global(qos: .userInitiated)) { try pasteIntoFrontApp() } }
    })
}

private func pasteIntoFrontApp() throws -> JSON {
    guard CGPreflightPostEventAccess() else { throw HostFailure(missingGrant(.accessibility, "paste")) }
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
