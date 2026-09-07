import AppKit

// Player と同じ一時ソースに連結して、製品に故障注入用 API を増やさず検証する。
// AivisSpeech や一般クリップボードには触らず、音量ゼロの短い WAV を使う。
final class Aivis {
    var delay: UInt64 = 0
    var invalidWAV = false
    func ensureRunning() async throws {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
    }
    func synthesize(text: String, speakerId: Int) async throws -> Data {
        if invalidWAV { return Data() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 15435)!
        buffer.frameLength = 15435
        buffer.floatChannelData![0].initialize(repeating: 0, count: 15435)
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }
}

enum Log { static func write(_ message: String) { print(message) } }

@main
enum AudioTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func wait(_ seconds: Double = 3, until condition: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        require(condition(), "状態遷移が時間内に完了しませんでした")
    }

    static func deadlineTests() {
        var deadline = PlaybackDeadline()
        require(!deadline.tick(now: 1000, rate: 1, playing: true), "合成前は復旧しない")
        deadline.begin(duration: 10)
        require(!deadline.tick(now: 0, rate: 1, playing: true), "開始")
        require(!deadline.tick(now: 5, rate: 1, playing: true), "文の途中")
        require(!deadline.tick(now: 7, rate: 2, playing: true), "速度変更")
        require(!deadline.tick(now: 8, rate: 1, playing: true), "完了猶予")
        require(!deadline.tick(now: 12.9, rate: 1, playing: true), "早すぎる復旧をしない")
        require(deadline.tick(now: 13, rate: 1, playing: true), "完了が来なければ検出する")
        deadline.begin(duration: 1)
        _ = deadline.tick(now: 0, rate: 1, playing: true)
        deadline.resetClock()
        _ = deadline.tick(now: 100, rate: 1, playing: false)
        deadline.resetClock()
        require(!deadline.tick(now: 200, rate: 1, playing: true), "一時停止の時間を含めない")
        require(!deadline.tick(now: 201, rate: 1, playing: true), "再開後も猶予を残す")
        deadline.clear()
        require(!deadline.tick(now: 999, rate: 1, playing: true), "停止後の期限を捨てる")
        print("PASS: 合成待ち・長い文・速度変更・一時停止の期限判定")
    }

    static func clipboardTests() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("コピーした文章です。", forType: .string)
        require(tryValue(ClipboardReader.read(from: board)) == "コピーした文章です。", "通常テキスト")
        board.clearContents()
        let attributed = NSAttributedString(string: "書式付きの文章です。")
        let rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        board.setData(rtf, forType: .rtf)
        require(tryValue(ClipboardReader.read(from: board)) == attributed.string, "RTF のみのコピー")
        board.clearContents()
        board.setData(Data([1, 2, 3]), forType: .png)
        require(tryValue(ClipboardReader.read(from: board)) == nil, "画像を文章にしない")
        board.clearContents()
        require(tryValue(ClipboardReader.read(from: board)) == nil, "取得できないときは失敗")
        board.setString(" \n", forType: .string)
        require(tryValue(ClipboardReader.read(from: board)) == nil, "空白を読まない")
        print("PASS: 通常テキスト・RTF・画像・空のクリップボード")
    }

    static func tryValue(_ result: Result<String, ClipboardReader.Failure>) -> String? {
        try? result.get()
    }

    static func main() throws {
        deadlineTests()
        try clipboardTests()
        Player.playerTests()
    }
}


extension Player {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        AudioTests.require(condition(), message)
    }
    private static func wait(_ seconds: Double = 3, until condition: () -> Bool) {
        AudioTests.wait(seconds, until: condition)
    }
    static func playerTests() {
        var settings = Settings()
        settings.rate = 1.25
        settings.volume = 0
        let aivis = Aivis()
        let player = Player(aivis: aivis, settings: settings)
        var completed = 0
        var errors: [String] = []
        player.onProgress = { index, _ in completed = max(completed, index) }
        player.onError = { errors.append($0) }
        player.load(text: "一文目です。二文目です。三文目です。")
        player.play()
        wait { player.state == .idle }
        require(completed == 3 && errors.isEmpty, "ミュートでも3文を最後まで再生する")
        require(!player.engine.isRunning, "待機中の出力を止める")

        completed = 0
        player.load(text: "復旧の検証です。次の文です。")
        player.play()
        wait { player.scheduledCount > 0 }
        let brokenEngine = player.engine
        player.node.pause() // 表示は playing のまま、完了だけを止める。
        wait(8) { player.engine !== brokenEngine }
        require(player.rate == 1.25 && player.volume == 0, "復旧で速度とミュートを変えない")
        wait { player.state == .idle }
        require(completed == 2 && errors.isEmpty, "停止した文から自動復旧する")
        print("PASS: ミュート中の正常完了・完了通知が止まった場合の自動復旧")

        player.load(text: "一時停止の検証です。次の文です。")
        player.play()
        wait { player.scheduledCount > 0 }
        player.pause()
        let index = player.progress.index
        player.handleConfigurationChange()
        require(player.state == .paused && player.progress.index == index, "出力変更で勝手に再生しない")
        player.play()
        wait { player.state == .idle }
        print("PASS: 一時停止中の出力変更後に再開")

        player.load(text: "復旧上限の検証です。")
        player.play()
        wait { player.scheduledCount > 0 }
        for _ in 0..<3 {
            player.node.pause()
            player.playbackDeadline.begin(duration: 0)
            _ = player.playbackDeadline.tick(now: ProcessInfo.processInfo.systemUptime - 6,
                                             rate: 1, playing: true)
            player.checkPlaybackProgress()
        }
        require(player.state == .paused && errors.count == 1, "繰り返し壊れたら明示して止める")
        player.play()
        wait { player.state == .idle }
        print("PASS: 復旧上限と手動再試行")

        aivis.delay = 500_000_000
        player.load(text: "取り消される文章です。")
        player.play()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        player.stop()
        aivis.delay = 0
        errors.removeAll()
        player.load(text: "置き換え後の文章です。")
        player.play()
        wait { player.state == .idle }
        require(errors.isEmpty, "古い起動待ちのキャンセルで新しい再生を壊さない")
        aivis.invalidWAV = true
        player.load(text: "壊れた音声の検証です。")
        player.play()
        wait { player.state == .idle }
        require(errors.count == 1, "壊れた WAV を無限に合成しない")
        print("PASS: 起動待ちの取消・不正な WAV")
    }

}
