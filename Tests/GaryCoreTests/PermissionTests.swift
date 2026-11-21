@testable import GaryCore
import Testing

struct PermissionTests {
    @Test(arguments: Permission.allCases)
    func `each permission opens its privacy pane in System Settings`(permission: Permission) {
        #expect(permission.settingsPane.scheme == "x-apple.systempreferences")
        #expect(permission.settingsPane.query?.hasPrefix("Privacy_") == true)
    }
}
