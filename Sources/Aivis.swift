import AppKit
import Foundation

// AivisSpeech Engine の薄いクライアント。
// エンジンは VOICEVOX ENGINE 互換の HTTP API なので、engineURL を 50021 に向ければ
// VOICEVOX でもそのまま動く。同梱もリンクもせず、HTTP 越しに話しかけるだけ。
struct Speaker: Identifiable {
    struct Style: Identifiable {
        let id: Int
        let name: String
    }
    let id: String
    let name: String
    let styles: [Style]
}

enum AivisError: LocalizedError {
    case notRunning
    case badResponse(Int)
    case launchFailed

    var errorDescription: String? {
        switch self {
        case .notRunning: return "AivisSpeech が応答しません"
        case .badResponse(let code): return "AivisSpeech が \(code) を返しました"
        case .launchFailed: return "AivisSpeech を起動できませんでした"
        }
    }
}

final class Aivis {
    private let session: URLSession
    private var settings: Settings

    // 自分で起こしたエンジンだけを片付ける。
    // ユーザーが自分で開いていたものを勝手に落とすのは筋が悪い
    private(set) var launchedByUs = false
    /// 最後に合成へ使った時刻。放置されたエンジンを落とす判断に使う
    private(set) var lastUsed = Date()

    /// 自分で起こした時刻。起動直後の見え方を判断材料から外すために持つ。
    /// 前回の nagara から引き継いだ場合は nil＝もう落ち着いている
    private var launchedAt: Date?
    private var ownedPID: pid_t?
    private var activationObserver: NSObjectProtocol?

    /// startHiding() が窓を押し戻している間（20秒）は隠れ／見えるが揺れる。
    /// 少し余裕を持たせて、この秒数が過ぎるまでは見え方を見ない
    private static let hideSettleSeconds: TimeInterval = 25

    init(settings: Settings) {
        self.settings = settings
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        self.session = URLSession(configuration: config)
        restoreOwnership()
        watchForUserTakeover()
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func update(settings: Settings) {
        self.settings = settings
    }

    private var base: URL { settings.engineBaseURL }

    // MARK: - 生死確認と起動

    func isUp() async -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("version"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return http.statusCode == 200
    }

    /// エンジンが落ちていれば裏で起こし、応答するまで待つ。
    ///
    /// AivisSpeech は Electron 製で、起動時に自分でウィンドウを前面へ出してくる。
    /// `open -g -j`（前面化しない・隠して起動）だけでは抑えきれないので、
    /// 起動直後のしばらくは見つけ次第 hide し続ける。それでも一瞬出ることはある。
    /// 完全に消したい場合は GUI を持たない AivisSpeech-Engine 単体版に差し替えること。
    func ensureRunning() async throws {
        if await isUp() {
            lastUsed = Date()
            return
        }
        guard settings.launchEngineIfNeeded else { throw AivisError.notRunning }

        Log.write("engine: 応答なし。\(settings.engineAppName) を裏で起動する")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-j", "-a", settings.engineAppName]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw AivisError.launchFailed
        }
        guard process.terminationStatus == 0 else { throw AivisError.launchFailed }
        claimOwnership()

        if settings.hideEngineOnLaunch { startHiding() }

        // モデルの読み込みがあるので十数秒かかることがある
        for attempt in 1...60 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if await isUp() {
                Log.write("engine: \(attempt)秒で応答した")
                // open の直後は runningApplications にまだ載っていないことがある。
                // 応答したこの時点なら確実に載っている
                rememberEnginePID()
                lastUsed = Date()
                return
            }
        }
        throw AivisError.notRunning
    }

    /// 起動直後にウィンドウが前へ出てくるのを押し戻す。
    /// 出てから隠すので、一瞬ちらつくのは避けられない
    private func startHiding() {
        Task { @MainActor in
            for _ in 0..<40 {
                for app in Self.runningEngines(named: settings.engineAppName) where !app.isHidden {
                    app.hide()
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func markUsed() {
        lastUsed = Date()
    }

    var isEngineRunning: Bool {
        !Self.runningEngines(named: settings.engineAppName).isEmpty
    }

    // MARK: - 所有権

    // 「nagara が起こしたエンジンだけを片付ける」を成立させるには、印を2つ持つ必要がある。
    //
    //  1. 起こしたのは自分か  ―― pid をファイルに書いて、プロセスをまたいで残す。
    //     メモリだけに持つと、再ビルド・強制終了・クラッシュで nagara だけが入れ替わった
    //     ときに、居座ったエンジンが「誰のものでもない」ことになって永久に落ちなくなる
    //  2. あなたが使い始めていないか ―― nagara は隠して起こすので、
    //     窓が出てきた／前面に来たなら、それはあなたが自分で使い始めたということ。
    //     そこから先は触らない。**片道切符で、二度と取り返さない**
    //
    // 2 は「見えている＝作業中」と決めつける代理指標でしかない。AivisSpeech の API には
    // 他のクライアントの利用状況を返す口が無いので、これ以上正確には測れない。
    // 外れる方向が「落とさない」側なので、この妥協を選んだ。

    private struct Ownership: Codable {
        let pid: pid_t
    }

    private static let ownerFileURL =
        Settings.directory.appendingPathComponent("engine-owner.json")

    /// 前回の nagara が起こしたエンジンが、まだ同じ pid で生きていれば引き継ぐ
    private func restoreOwnership() {
        guard let data = try? Data(contentsOf: Self.ownerFileURL),
              let owned = try? JSONDecoder().decode(Ownership.self, from: data)
        else { return }
        guard Self.runningEngines(named: settings.engineAppName)
            .contains(where: { $0.processIdentifier == owned.pid })
        else {
            try? FileManager.default.removeItem(at: Self.ownerFileURL)
            return
        }
        launchedByUs = true
        ownedPID = owned.pid
        Log.write("engine: 前回 nagara が起こしたエンジン (pid \(owned.pid)) を引き継いだ")
    }

    private func claimOwnership() {
        launchedByUs = true
        launchedAt = Date()
        rememberEnginePID()
    }

    private func rememberEnginePID() {
        guard launchedByUs, ownedPID == nil else { return }
        guard let pid = Self.runningEngines(named: settings.engineAppName)
            .first?.processIdentifier else { return }
        ownedPID = pid
        if let data = try? JSONEncoder().encode(Ownership(pid: pid)) {
            try? data.write(to: Self.ownerFileURL, options: .atomic)
        }
    }

    private func releaseOwnership(reason: String) {
        guard launchedByUs else { return }
        launchedByUs = false
        ownedPID = nil
        launchedAt = nil
        try? FileManager.default.removeItem(at: Self.ownerFileURL)
        Log.write("engine: \(reason)ので、以後 nagara からは終了させない")
    }

    /// 起こした直後は窓を押し戻している最中なので、見え方を判断材料にしない
    private var hidingHasSettled: Bool {
        guard let launchedAt else { return true }
        return Date().timeIntervalSince(launchedAt) > Self.hideSettleSeconds
    }

    private func engineIsVisible() -> Bool {
        Self.runningEngines(named: settings.engineAppName).contains { !$0.isHidden }
    }

    /// 前面に出てきた瞬間を拾う。隠したままの窓を Dock から呼び出した場合もここに来る
    private func watchForUserTakeover() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, self.launchedByUs, self.hidingHasSettled else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  Self.isEngine(app, named: self.settings.engineAppName)
            else { return }
            self.releaseOwnership(reason: "AivisSpeech が前面に出た")
        }
    }

    /// 最後に使ってから十分に経っていれば落とす。
    /// 自分で起こしたものだけが対象で、手で開かれたものにも、
    /// あなたが途中から使い始めたものにも触らない
    @discardableResult
    func quitIfIdle() -> Bool {
        guard launchedByUs, settings.engineIdleQuitMinutes > 0 else { return false }
        // 隠して起こしたはずのエンジンが姿を見せているなら、あなたが自分で開いたということ。
        // 隠さない設定のときは見え方に意味が無いので、前面化の通知だけを頼りにする
        if settings.hideEngineOnLaunch, hidingHasSettled, engineIsVisible() {
            releaseOwnership(reason: "AivisSpeech の窓が開いた")
            return false
        }
        let idle = Date().timeIntervalSince(lastUsed)
        guard idle >= Double(settings.engineIdleQuitMinutes) * 60 else { return false }
        Log.write("engine: \(settings.engineIdleQuitMinutes)分使われなかったので終了させる")
        return quit()
    }

    /// nagara が起こしたエンジンだけを終了させる
    func quitIfWeLaunchedIt() {
        guard launchedByUs, settings.quitEngineOnExit else { return }
        Log.write("engine: 自分で起こしたので終了させる")
        _ = quit()
    }

    @discardableResult
    func quit() -> Bool {
        let running = Self.runningEngines(named: settings.engineAppName)
        guard !running.isEmpty else { return false }
        for app in running { app.terminate() }
        launchedByUs = false
        ownedPID = nil
        launchedAt = nil
        try? FileManager.default.removeItem(at: Self.ownerFileURL)
        return true
    }

    private static func isEngine(_ app: NSRunningApplication, named name: String) -> Bool {
        app.localizedName == name || app.bundleIdentifier?.contains("AivisSpeech") == true
    }

    private static func runningEngines(named name: String) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { isEngine($0, named: name) }
    }

    // MARK: - 話者

    func speakers() async throws -> [Speaker] {
        let (data, response) = try await session.data(from: base.appendingPathComponent("speakers"))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AivisError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { entry in
            guard let name = entry["name"] as? String,
                  let uuid = entry["speaker_uuid"] as? String,
                  let styles = entry["styles"] as? [[String: Any]]
            else { return nil }
            let parsed = styles.compactMap { style -> Speaker.Style? in
                guard let id = style["id"] as? Int, let styleName = style["name"] as? String
                else { return nil }
                return Speaker.Style(id: id, name: styleName)
            }
            return Speaker(id: uuid, name: name, styles: parsed)
        }
    }

    // MARK: - 合成

    /// 1文ぶんの WAV を返す。
    ///
    /// speedScale は 1.0 のまま触らない。速度は再生側（AVAudioUnitTimePitch）で変える。
    /// ここで速くすると、再生中に速度を変えられず、抑揚も崩れる。DESIGN.md 参照。
    func synthesize(text: String, speakerId: Int) async throws -> Data {
        lastUsed = Date()
        let query = try await audioQuery(text: text, speakerId: speakerId)
        let wav = try await synthesis(query: query, speakerId: speakerId)
        lastUsed = Date()
        return wav
    }

    private func audioQuery(text: String, speakerId: Int) async throws -> [String: Any] {
        var components = URLComponents(
            url: base.appendingPathComponent("audio_query"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "speaker", value: String(speakerId)),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AivisError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AivisError.badResponse(-1)
        }
        // 再生側の形式を1つに固定しておく。文ごとに違う形式が返ると継ぎ目で破綻する
        json["outputSamplingRate"] = Player.sampleRate
        json["outputStereo"] = false
        return json
    }

    private func synthesis(query: [String: Any], speakerId: Int) async throws -> Data {
        var components = URLComponents(
            url: base.appendingPathComponent("synthesis"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "speaker", value: String(speakerId))]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/wav", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: query)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AivisError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }
}
