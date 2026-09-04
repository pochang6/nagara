import Foundation

// 設定は JSON 1枚。GUI で全部いじれるようにはせず、
// よく触るものだけメニューに出し、残りはファイルを直接開いて直す。
struct Settings: Codable {
    // まい / ノーマル。AivisSpeech の /speakers から採った実際の ID
    var speakerId: Int = 1_431_611_904
    var speakerLabel: String = "まい / ノーマル"

    // 再生速度。合成側の speedScale ではなく再生側で変える（DESIGN.md 参照）
    //
    // rate は「いま使っている速度」であり、そのまま次の起動時の既定になる。
    // 一度 1.25 にすれば以後ずっと 1.25 で始まる。
    var rate: Float = 1.0
    /// ⌃⌥→ / ⌃⌥← で1段ずつ動く段階。メニューからも直接選べる。
    ///
    /// 1.0 未満を外してあるのは、TimePitch で引き伸ばすと音が濁って
    /// 「デジタルノイズ混じりのダースベイダー」になるため。実用になるのは 1.0〜1.5。
    /// それ以上・以下を試したければ、この配列に手で足せば出る
    var rateLadder: [Float] = [1.0, 1.1, 1.2, 1.25, 1.35, 1.5]

    // 音量。0.0〜1.0。
    //
    // 既定を 1.0 にしていないのは、合成音声がもともと大きめで、
    // 聴くたびにシステム音量のほうを下げに行く羽目になったため。
    // rate と同じく、いま使っている値がそのまま次回の既定になる。
    var volume: Float = 0.8
    /// ⌃⌥= / ⌃⌥- で1段ずつ動く段階。メニューからも直接選べる
    var volumeLadder: [Float] = [0.2, 0.4, 0.6, 0.8, 0.9, 1.0]

    // 届いた端から喋り出すか。既定は OFF ＝ 黙って溜める
    var autoPlay: Bool = false

    var port: UInt16 = 17371
    var engineURL: String = "http://127.0.0.1:10101"

    // エンジンが落ちていたら裏で起こす。
    //
    // 起動のたびに 8 秒待つのも、一度きりの用事のために一日中居座られるのも、どちらも嫌。
    // なので「一度起きたら置いておく／しばらく使われなければ静かに落ちる」を既定にした。
    // 手で閉じられた場合は追いかけない（次に必要になったときだけまた起こす）。
    var launchEngineIfNeeded: Bool = true
    var engineAppName: String = "AivisSpeech"
    /// 最後に使ってから何分で落とすか。0 なら落とさず置いておく
    var engineIdleQuitMinutes: Int = 15
    /// nagara の終了に合わせて落とすか（自分で起こしたエンジンだけが対象）
    var quitEngineOnExit: Bool = true
    /// Electron 製なので完全には抑えられないが、起動直後に隠す努力はする
    var hideEngineOnLaunch: Bool = true

    var historyLimit: Int = 30

    // 読み飛ばし。コードブロックを律儀に読み上げても仕方がない
    var skipCodeBlocks: Bool = true
    // これより短い応答はキューに積まない（「了解しました」を朗読しないため）
    var minimumLength: Int = 12

    static let directory: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/nagara", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let fileURL = directory.appendingPathComponent("settings.json")

    // 項目を足したときに、既存の settings.json を初期値で上書きしてしまわないための実装。
    // 合成された Codable は「キーが1つでも欠けたら失敗」なので、
    // バージョンを上げるたびにユーザーの設定が消える。全項目を decodeIfPresent で拾う。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Settings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            do {
                if let decoded = try container.decodeIfPresent(T.self, forKey: key) {
                    return decoded
                }
            } catch {
                Log.write("settings: \(key.stringValue) を読めなかったので既定値を使う")
            }
            return fallback
        }
        speakerId = value(.speakerId, fallback.speakerId)
        speakerLabel = value(.speakerLabel, fallback.speakerLabel)
        rate = value(.rate, fallback.rate)
        rateLadder = value(.rateLadder, fallback.rateLadder)
        volume = value(.volume, fallback.volume)
        volumeLadder = value(.volumeLadder, fallback.volumeLadder)
        autoPlay = value(.autoPlay, fallback.autoPlay)
        port = value(.port, fallback.port)
        engineURL = value(.engineURL, fallback.engineURL)
        launchEngineIfNeeded = value(.launchEngineIfNeeded, fallback.launchEngineIfNeeded)
        engineAppName = value(.engineAppName, fallback.engineAppName)
        engineIdleQuitMinutes = value(.engineIdleQuitMinutes, fallback.engineIdleQuitMinutes)
        quitEngineOnExit = value(.quitEngineOnExit, fallback.quitEngineOnExit)
        hideEngineOnLaunch = value(.hideEngineOnLaunch, fallback.hideEngineOnLaunch)
        historyLimit = value(.historyLimit, fallback.historyLimit)
        skipCodeBlocks = value(.skipCodeBlocks, fallback.skipCodeBlocks)
        minimumLength = value(.minimumLength, fallback.minimumLength)
    }

    init() {}

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: fileURL) else {
            let fresh = Settings()
            fresh.save()
            return fresh
        }
        guard let decoded = try? JSONDecoder().decode(Settings.self, from: data) else {
            // ここまで来るのは JSON 自体が壊れているとき。
            // 黙って初期値に戻すと原因が分からなくなるので、退避してから作り直す
            let broken = fileURL.deletingPathExtension().appendingPathExtension("broken.json")
            try? FileManager.default.removeItem(at: broken)
            try? FileManager.default.moveItem(at: fileURL, to: broken)
            Log.write("settings: 読めなかったので \(broken.lastPathComponent) へ退避した")
            let fresh = Settings()
            fresh.save()
            return fresh
        }
        // 足りない項目を補ったうえで書き戻す。次回からは素直に読める
        decoded.save()
        return decoded
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Settings.fileURL, options: .atomic)
    }

    var engineBaseURL: URL {
        URL(string: engineURL) ?? URL(string: "http://127.0.0.1:10101")!
    }
}
