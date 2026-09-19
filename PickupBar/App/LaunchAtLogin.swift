import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` for the Settings toggle.
///
/// Registration can fail for reasons the user cannot act on (an unsigned debug
/// build, a sandbox quirk), so errors are swallowed and the getter simply
/// reports whatever the service currently says.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
            } catch {
                // Nothing useful to show the user here; the toggle re-reads
                // `status`, so it snaps back if the change did not take.
            }
        }
    }
}
