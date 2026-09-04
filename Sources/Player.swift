import AVFoundation
import Foundation

// 再生の中身。nagara の存在意義はここに集約されている。
//
// 設計の要点は3つ。
//  1. 文ごとに合成してキューに積む。だから長文でも最初の1文ができ次第で鳴り始める
//  2. 速度は AVAudioUnitTimePitch で変える。声の高さが保たれ、再生中でも切り替わる
//  3. 文の境界をそのまま「戻る」の単位にする。15秒戻しより読み上げには合っている
final class Player {

    static let sampleRate = 44100

    enum State {
        case idle
        case playing
        case paused
    }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(
        standardFormatWithSampleRate: Double(Player.sampleRate), channels: 1)!

    private let aivis: Aivis
    private var settings: Settings

    private var sentences: [String] = []
    private var buffers: [Int: AVAudioPCMBuffer] = [:]
    private var scheduleIndex = 0          // 次に engine へ積む文
    private var currentIndex = 0           // いま鳴っている文
    private var scheduledCount = 0
    private var generation = 0             // 停止・シーク後に古い完了通知を捨てるための世代
    private var prefetchTask: Task<Void, Never>?

    private let prefetchDepth = 3

    private(set) var state: State = .idle {
        didSet { if oldValue != state { onStateChange?(state) } }
    }

    var onStateChange: ((State) -> Void)?
    var onProgress: ((Int, Int) -> Void)?
    var onError: ((String) -> Void)?

    var rate: Float {
        get { timePitch.rate }
        set { timePitch.rate = max(0.5, min(3.0, newValue)) }
    }

    /// 音量はプレイヤーノード側で変える。
    /// mainMixerNode を触ると engine 全体の出力が動くので、こちらのほうが行儀がよい。
    /// 再生中に変えてもその場で効く
    var volume: Float {
        get { node.volume }
        set { node.volume = max(0.0, min(1.0, newValue)) }
    }

    var progress: (index: Int, total: Int) { (currentIndex, sentences.count) }

    var currentSentence: String? {
        sentences.indices.contains(currentIndex) ? sentences[currentIndex] : nil
    }

    init(aivis: Aivis, settings: Settings) {
        self.aivis = aivis
        self.settings = settings

        engine.attach(node)
        engine.attach(timePitch)
        engine.connect(node, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        timePitch.rate = settings.rate
        node.volume = settings.volume
        // 引き伸ばし・詰めのときの重ね合わせ回数。既定の 8 より上げると音の濁りが減る。
        // CPU は食うが、1本の音声を鳴らすだけなので気にする量ではない
        timePitch.overlap = 16
        engine.prepare()
    }

    func update(settings: Settings) {
        self.settings = settings
    }

    // MARK: - 操作

    func load(text: String) {
        let speakable = Sanitizer.speakable(from: text, skipCodeBlocks: settings.skipCodeBlocks)
        let split = Sanitizer.sentences(from: speakable)
        reset()
        sentences = split
        Log.write("player: \(split.count)文を読み込んだ")
    }

    func play() {
        guard !sentences.isEmpty else {
            onError?("読むものがありません")
            return
        }
        if state == .paused {
            startEngineIfNeeded()
            node.play()
            state = .playing
            return
        }
        guard state != .playing else { return }
        startEngineIfNeeded()
        node.play()
        state = .playing
        startPrefetch()
        pump()
    }

    func pause() {
        guard state == .playing else { return }
        node.pause()
        state = .paused
    }

    func togglePlayPause() {
        switch state {
        case .playing: pause()
        case .paused, .idle: play()
        }
    }

    func stop() {
        reset()
        state = .idle
        Log.write("player: 停止")
    }

    /// 1文戻る。文の境界に着地するので、15秒戻しのように文の途中で始まらない
    func previousSentence() {
        guard !sentences.isEmpty else { return }
        restart(from: max(0, currentIndex - 1))
    }

    func nextSentence() {
        guard !sentences.isEmpty else { return }
        guard currentIndex + 1 < sentences.count else {
            stop()
            return
        }
        restart(from: currentIndex + 1)
    }

    /// 速度を1段ずつ上げ下げする。
    ///
    /// 以前は 1.0 → 1.2 → 1.5 → 1.0 と一方向に回していたが、
    /// 上げすぎたときに戻すのに一周させられるのが苦痛だった。端では止まる（巻き戻らない）。
    @discardableResult
    func stepRate(_ direction: Int) -> Float {
        let ladder = settings.rateLadder.isEmpty ? [1.0, 1.2, 1.5] : settings.rateLadder.sorted()
        let current = rate
        let next: Float
        if direction > 0 {
            next = ladder.first { $0 > current + 0.001 } ?? ladder.last!
        } else {
            next = ladder.last { $0 < current - 0.001 } ?? ladder.first!
        }
        rate = next
        Log.write("player: 速度 \(next)")
        return next
    }

    /// 音量を1段ずつ上げ下げする。速度と同じく端では止まる（巻き戻らない）
    @discardableResult
    func stepVolume(_ direction: Int) -> Float {
        let ladder = settings.volumeLadder.isEmpty
            ? [0.2, 0.4, 0.6, 0.8, 1.0] : settings.volumeLadder.sorted()
        let current = volume
        let next: Float
        if direction > 0 {
            next = ladder.first { $0 > current + 0.001 } ?? ladder.last!
        } else {
            next = ladder.last { $0 < current - 0.001 } ?? ladder.first!
        }
        volume = next
        Log.write("player: 音量 \(Int((next * 100).rounded()))%")
        return next
    }

    // MARK: - 内部

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            Log.write("player: engine.start に失敗 \(error.localizedDescription)")
            onError?("音声エンジンを開始できませんでした")
        }
    }

    private func reset() {
        generation &+= 1
        prefetchTask?.cancel()
        prefetchTask = nil
        node.stop()
        // stop() だけでは積んだぶんが残ることがある。reset() で明示的に捨てる
        node.reset()
        buffers.removeAll()
        sentences = []
        scheduleIndex = 0
        currentIndex = 0
        scheduledCount = 0
        // 状態も戻すこと。ここを .playing のままにすると、
        // 再生中に load したとき play() の「すでに再生中なら何もしない」に弾かれて
        // 黙って止まる。声を切り替えたら再生が止まる、という形で出た
        state = .idle
    }

    private func restart(from index: Int) {
        generation &+= 1
        prefetchTask?.cancel()
        node.stop()
        scheduleIndex = index
        currentIndex = index
        scheduledCount = 0
        startEngineIfNeeded()
        node.play()
        state = .playing
        startPrefetch()
        pump()
        onProgress?(currentIndex, sentences.count)
    }

    /// 先読み。再生中の文の少し先までを合成しておく。
    /// 全文を先に合成しないのは、長文だと鳴り始めるまで待たされるから
    private func startPrefetch() {
        prefetchTask?.cancel()
        let generationAtStart = generation
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.aivis.ensureRunning()
            } catch {
                await MainActor.run {
                    Log.write("player: エンジンを用意できない \(error.localizedDescription)")
                    self.onError?(error.localizedDescription)
                    self.state = .idle
                }
                return
            }

            while !Task.isCancelled {
                let target = await MainActor.run { () -> Int? in
                    guard generationAtStart == self.generation else { return nil }
                    let limit = min(self.sentences.count, self.currentIndex + self.prefetchDepth)
                    for index in self.currentIndex..<max(self.currentIndex, limit)
                    where self.buffers[index] == nil {
                        return index
                    }
                    return -1
                }
                guard let target else { return }
                if target < 0 {
                    // 先読みが追いついている。少し待って様子を見る
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    let finished = await MainActor.run {
                        generationAtStart != self.generation
                            || (self.state == .idle && self.buffers.isEmpty)
                    }
                    if finished { return }
                    continue
                }

                let sentence = await MainActor.run { () -> String? in
                    self.sentences.indices.contains(target) ? self.sentences[target] : nil
                }
                guard let sentence else { return }

                do {
                    let speakerId = await MainActor.run { self.settings.speakerId }
                    let wav = try await self.aivis.synthesize(text: sentence, speakerId: speakerId)
                    guard let buffer = self.makeBuffer(from: wav) else { continue }
                    await MainActor.run {
                        guard generationAtStart == self.generation else { return }
                        self.buffers[target] = buffer
                        self.pump()
                    }
                } catch {
                    // 「戻る」や停止で先読みを畳んだときの取り消しは失敗ではない。
                    // これを警告として出すと、正常な操作のたびに ⚠︎ が点いてしまう
                    if error is CancellationError || (error as? URLError)?.code == .cancelled {
                        return
                    }
                    await MainActor.run {
                        Log.write("player: 合成に失敗 (\(target)文目) \(error.localizedDescription)")
                        self.onError?(error.localizedDescription)
                        // 1文落としても読み進める。1文の失敗で全部止まるほうが困る
                        guard generationAtStart == self.generation else { return }
                        self.buffers[target] = self.silence()
                        self.pump()
                    }
                }
            }
        }
    }

    /// 用意できているぶんを engine へ積む。積みっぱなしにすると
    /// 「戻る」が効かなくなるので、先行は数文ぶんに留める
    private func pump() {
        let generationAtPump = generation
        while scheduleIndex < sentences.count,
              scheduledCount < prefetchDepth,
              let buffer = buffers[scheduleIndex] {
            let index = scheduleIndex
            scheduleIndex += 1
            scheduledCount += 1
            node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) {
                [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, generationAtPump == self.generation else { return }
                    self.scheduledCount = max(0, self.scheduledCount - 1)
                    self.currentIndex = min(index + 1, self.sentences.count)
                    self.onProgress?(self.currentIndex, self.sentences.count)
                    if self.currentIndex >= self.sentences.count {
                        Log.write("player: 最後まで読み終えた")
                        self.stop()
                    } else {
                        self.pump()
                    }
                }
            }
        }
    }

    // MARK: - WAV → バッファ

    private func makeBuffer(from wav: Data) -> AVAudioPCMBuffer? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nagara-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try wav.write(to: url)
            let file = try AVAudioFile(forReading: url)
            let frames = AVAudioFrameCount(file.length)
            guard frames > 0 else { return nil }

            guard let source = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: frames) else { return nil }
            try file.read(into: source)

            // 形式は audio_query 側で固定しているが、モデルによって差が出ても
            // 落ちないように変換の逃げ道を残しておく
            if file.processingFormat == format { return source }
            guard let converter = AVAudioConverter(from: file.processingFormat, to: format),
                  let output = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(
                        Double(frames) * format.sampleRate / file.processingFormat.sampleRate) + 1024)
            else { return source }

            var consumed = false
            var conversionError: NSError?
            converter.convert(to: output, error: &conversionError) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return source
            }
            if let conversionError {
                Log.write("player: 変換に失敗 \(conversionError.localizedDescription)")
                return nil
            }
            return output
        } catch {
            Log.write("player: WAV を読めなかった \(error.localizedDescription)")
            return nil
        }
    }

    /// 合成に失敗した文のぶんの無音。読み飛ばしたことが間で分かる
    private func silence() -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(format.sampleRate * 0.25)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        return buffer
    }
}
