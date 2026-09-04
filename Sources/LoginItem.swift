import Foundation
import ServiceManagement

// 「使いたいときに迷子になる」のがいちばん困るので、既定でログイン時に起動する。
// 気に入らなければメニューから外せる。
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            Log.write("loginitem: \(enabled ? "登録" : "解除")した")
            return true
        } catch {
            Log.write("loginitem: 失敗 \(error.localizedDescription)")
            return false
        }
    }

    /// 初回起動のときだけ、黙って登録しておく
    static func enableOnFirstRun() {
        let key = "dev.pochang6.nagara.didSetupLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        set(true)
    }
}
