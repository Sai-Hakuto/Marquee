import Foundation
import ServiceManagement

// Thin wrapper around SMAppService for the "Launch Marquee at Login" toggle. The system owns
// this state (it's also editable in System Settings ▸ General ▸ Login Items), so callers should
// always re-read `isEnabled` after `setEnabled` rather than assuming the change took —
// registration can be refused (e.g. the user previously disabled the app in System Settings).
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[Marquee] Launch-at-login change failed: \(error.localizedDescription)")
        }
    }
}
