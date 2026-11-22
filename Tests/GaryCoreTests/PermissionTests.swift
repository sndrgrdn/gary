@testable import GaryCore
import Testing

struct PermissionTests {
    @Test(arguments: Permission.allCases)
    func `each permission opens its pane in System Settings`(permission: Permission) {
        #expect(permission.settingsPane.scheme == "x-apple.systempreferences")
        #expect(permission.settingsPane.query?.hasPrefix(permission == .notifications ? "id=com.sndrgrdn.gary" : "Privacy_") == true)
    }
}
