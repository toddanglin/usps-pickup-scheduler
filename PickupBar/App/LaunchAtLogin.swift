import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` for the Settings toggle.
///
/// Registration genuinely can fail — an unapproved login item, an unsigned
/// build — and the user can usually act on it, so both the status and the error
/// are handed to the UI instead of being swallowed.
enum LaunchAtLogin {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    /// Registers or unregisters the login item. Throws whatever
    /// `ServiceManagement` reported, so the caller can show it.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}
