import AppKit

@main
enum AutoplayTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func controller() -> Controller {
        let controller = Controller()
        controller.settings = Settings()
        controller.settings.volume = 0
        // 実エンジンや個人設定に触れず、再生の入口と設定切り替えを検証する。
        controller.settings.launchEngineIfNeeded = false
        controller.settings.engineURL = "http://127.0.0.1:1"
        controller.player.update(settings: controller.settings)
        controller.player.volume = 0
        controller.aivis.update(settings: controller.settings)
        return controller
    }

    static func main() {
        let c = controller()
        c.setAutoPlay(true)
        require(c.player.state == .idle, "未読がなければ起こさない")
        c.setAutoPlay(false)
        c.speak(text: "切り替え直前に届いた返答の検証です。", source: "test")
        require(c.player.state == .idle && c.unreadCount == 1, "OFF 中は積むだけ")
        c.setAutoPlay(true)
        require(c.player.state == .playing && c.unreadCount == 0,
                "ON に切り替えたら未読を再生する")
        c.stop()
        c.setAutoPlay(false)
        c.setAutoPlay(true)
        require(c.player.state == .idle, "既読は読み直さない")
        c.speak(text: "自動再生が有効な間に新しく届く返答です。", source: "test")
        require(c.player.state == .playing, "ON の後の到着も再生する")
        c.speak(text: "再生中に届くので順番を待つ返答です。", source: "test")
        require(c.waiting.count == 1, "再生中は順番待ち")
        c.setAutoPlay(false)
        c.setAutoPlay(true)
        require(c.waiting.count == 1 && c.unreadCount == 1, "切り替えで割り込まない")
        c.player.pause()
        c.setAutoPlay(false)
        c.setAutoPlay(true)
        require(c.player.state == .paused, "一時停止を勝手に再開しない")
        c.stop()

        let explicit = controller()
        explicit.setAutoPlay(true)
        explicit.speak(text: "明示的に積むだけと指定された返答です。", source: "test", autoplay: false)
        explicit.setAutoPlay(true)
        require(explicit.player.state == .idle, "ON の再指定では再生しない")
        print("PASS: ON 前後の到着・未読なし・既読・順番待ち・一時停止・ON の再指定")
    }
}
