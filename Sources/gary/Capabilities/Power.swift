import AppKit
import Carbon.HIToolbox
import GaryCore
import IOKit.pwr_mgt

extension Capability {
    static let power = Capability(
        name: "power",
        summary: """
        Sleep, lock the screen, restart, shut down, or log out. `sleep` asks the power manager directly and needs no permission. \
        `lock` presses the Lock Screen shortcut, control-command-Q, so it needs Accessibility. `restart`, `shutDown`, and `logOut` \
        ask loginwindow, as the Apple menu does, so apps can save their documents or cancel. macOS asks the user once, the first time, \
        to let Gary control loginwindow, and the promise rejects while that Automation grant is missing. \
        `stayAwake` keeps the Mac awake, as caffeinate does, until the plugin calls it with `"off"` or stops: \
        `"system"` keeps the Mac from sleeping when idle but lets the display sleep, and `"display"` keeps the display on too.
        """,
        types: """
        declare namespace Gary {
          interface Host {
            power: {
              sleep(): null;
              lock(): null;
              restart(): Promise<null>;
              shutDown(): Promise<null>;
              logOut(): Promise<null>;
              stayAwake(mode: "off" | "system" | "display"): null;
            };
          }
        }
        """,
        example: """
        const actions = [
          { action: "lock", symbol: "lock", title: "Lock" },
          { action: "sleep", symbol: "moon", title: "Sleep" },
          { action: "logOut", symbol: "rectangle.portrait.and.arrow.right", title: "Log Out" },
          { action: "restart", symbol: "arrow.clockwise", title: "Restart" },
          { action: "shutDown", symbol: "power", title: "Shut Down" },
        ] as const;
        let awake = false;

        export default {
          render() {
            const items = [...actions, { action: "awake", symbol: awake ? "cup.and.saucer.fill" : "cup.and.saucer", title: "Stay Awake" }];
            return {
              type: "column",
              gap: 4,
              children: items.map(({ action, symbol, title }) => ({
                type: "button", key: action, action,
                children: [{ type: "row", gap: 6, children: [{ type: "icon", symbol }, { type: "text", text: title }] }],
              })),
            };
          },
          onAction(action) {
            if (action === "awake") {
              awake = !awake;
              host.power.stayAwake(awake ? "display" : "off");
              return;
            }
            host.hide();
            if (action === "lock") host.power.lock();
            else if (action === "sleep") host.power.sleep();
            else if (action === "logOut") host.power.logOut().catch((error) => host.log(String(error)));
            else if (action === "restart") host.power.restart().catch((error) => host.log(String(error)));
            else if (action === "shutDown") host.power.shutDown().catch((error) => host.log(String(error)));
          },
        } satisfies Gary.Menu;
        """,
        permissions: [.accessibility],
        install: { host, plugin in
            let awake = Awake(name: "Gary: \(plugin.id)")
            plugin.onStop { awake.release() }
            plugin.installAPI(host, "power", ["sleep", "lock", "restart", "shutDown", "logOut", "stayAwake"]) { call in
                switch call.method {
                case "stayAwake":
                    let raw = try call.string(0, "mode")
                    guard let mode = Awake.Mode(rawValue: raw) else { throw call.fail("mode must be \"off\", \"system\", or \"display\"") }
                    try awake.hold(mode)
                case "sleep": try sleepNow()
                case "lock": try lockScreen()
                case "restart": return .later(.global(qos: .userInitiated)) { try askLoginWindow(AEEventID(kAERestart)) }
                case "shutDown": return .later(.global(qos: .userInitiated)) { try askLoginWindow(AEEventID(kAEShutDown)) }
                case "logOut": return .later(.global(qos: .userInitiated)) { try askLoginWindow(AEEventID(kAEReallyLogOut)) }
                default: throw call.unknownMethod
                }
                return .now(.null)
            }
        },
    )
}

private func sleepNow() throws {
    let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
    defer { IOServiceClose(port) }
    let status = IOPMSleepSystem(port)
    guard status == kIOReturnSuccess else { throw HostFailure("the power manager refused to sleep (\(status))") }
}

private func lockScreen() throws {
    guard CGPreflightPostEventAccess() else { throw HostFailure(missingGrant(.accessibility, "power.lock")) }
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: down)
        event?.flags = [.maskControl, .maskCommand]
        event?.post(tap: .cghidEventTap)
    }
}

private func askLoginWindow(_ event: AEEventID) throws -> JSON {
    let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow")
    let consent = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(kCoreEventClass), event, true)
    guard consent == noErr else {
        throw HostFailure(
            consent == OSStatus(errAEEventNotPermitted)
                ? "Gary may not control loginwindow; allow it in System Settings > Privacy & Security > Automation"
                : "cannot reach loginwindow (\(consent))",
        )
    }
    let message = NSAppleEventDescriptor.appleEvent(
        withEventClass: AEEventClass(kCoreEventClass),
        eventID: event,
        targetDescriptor: target,
        returnID: AEReturnID(kAutoGenerateReturnID),
        transactionID: AETransactionID(kAnyTransactionID),
    )
    try message.sendEvent(options: [.noReply], timeout: 10)
    return .null
}

private final class Awake {
    enum Mode: String {
        case off, system, display

        var assertionType: String? {
            switch self {
            case .off: nil
            case .system: kIOPMAssertionTypePreventUserIdleSystemSleep
            case .display: kIOPMAssertionTypePreventUserIdleDisplaySleep
            }
        }
    }

    private let name: String
    private var assertion: IOPMAssertionID?

    init(name: String) {
        self.name = name
    }

    func hold(_ mode: Mode) throws {
        release()
        guard let type = mode.assertionType else { return }
        var id = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
        guard status == kIOReturnSuccess else { throw HostFailure("the power manager refused to keep the Mac awake (\(status))") }
        assertion = id
    }

    func release() {
        guard let assertion else { return }
        IOPMAssertionRelease(assertion)
        self.assertion = nil
    }
}
