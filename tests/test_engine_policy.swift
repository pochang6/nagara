import AppKit

@main
enum EnginePolicyTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    /// 三択のどれか1つだけに当たり、保存される2つの値もその1つと矛盾しないこと
    static func requireSettled(_ c: Controller, _ expected: Controller.EnginePolicy, _ step: String) {
        require(c.enginePolicy == expected, "\(step): \(expected) のはずが \(c.enginePolicy)")
        let minutes = c.settings.engineIdleQuitMinutes
        let onExit = c.settings.quitEngineOnExit
        switch expected {
        case .keepRunning: require(minutes == 0 && !onExit, "\(step): 起動したままなのに値が残っている")
        case .idleQuit: require(minutes > 0 && onExit, "\(step): 待ち時間の値が揃っていない")
        case .quitOnExit: require(minutes == 0 && onExit, "\(step): 終了時だけのはずが値が揃っていない")
        }
    }

    static func main() {
        let c = Controller()
        c.settings = Settings()
        c.settings.launchEngineIfNeeded = false
        c.settings.engineURL = "http://127.0.0.1:1"
        c.aivis.update(settings: c.settings)

        c.setEngineIdleMinutes(120)
        requireSettled(c, .idleQuit, "2時間を選ぶ")
        require(c.settings.engineIdleQuitMinutes == 120, "選んだ分が入る")
        c.setEnginePolicy(.keepRunning)
        requireSettled(c, .keepRunning, "2時間 → 起動したまま")
        require(!c.aivis.quitIfIdle(), "起動したままなら時間で閉じない")
        c.setEngineIdleMinutes(30)
        requireSettled(c, .idleQuit, "起動したまま → 段から30分")
        c.setEnginePolicy(.quitOnExit)
        requireSettled(c, .quitOnExit, "30分 → 終了時だけ")
        c.setEnginePolicy(.idleQuit)
        requireSettled(c, .idleQuit, "終了時だけ → しばらく使わなければ")
        c.setEnginePolicy(.keepRunning)
        requireSettled(c, .keepRunning, "しばらく → 起動したまま")

        // 手で書き換えた三択に無い組み合わせは、読み込み時に寄せる
        var odd = Settings()
        odd.engineIdleQuitMinutes = 120
        odd.quitEngineOnExit = false
        odd.settleEnginePolicy()
        require(odd.engineIdleQuitMinutes == 120 && odd.quitEngineOnExit, "分を優先して揃える")
        var negative = Settings()
        negative.engineIdleQuitMinutes = -5
        negative.quitEngineOnExit = false
        negative.settleEnginePolicy()
        require(negative.engineIdleQuitMinutes == 0 && !negative.quitEngineOnExit, "負の分は閉じない扱い")
        print("PASS: 三択の切り替え・段からの選択・読み込み時の正規化")
    }
}
