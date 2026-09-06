import Foundation

// 読み間違いの拾いかた。
//
// AivisSpeech は「この文字列をどう読むか」を audio_query で必ず答える。合成しなくても分かる。
// 一方 macOS にも読みの推定器が入っている（CFStringTokenizer の Latin transcription）。
// 素性のまるで違う2つを突き合わせ、**食い違ったところだけ**を候補として拾う。
//
// どちらが正しいかはここでは決めない。実際どちらも外す（「担々麺」は macOS が、
// 「再生中」は AivisSpeech が外した）。決めるのは AI エージェントか本人で、
// nagara は「ここが怪しい」と指差すところまでを引き受ける。
enum Yomi {

    struct Candidate: Codable, Equatable {
        let surface: String
        /// AivisSpeech がいま読む読み
        let engine: String
        /// macOS 側の読み。正解ではなく、あくまで別の意見
        let guess: String
        /// どの文で見つけたか。人名のような文脈依存を判断するのに要る
        let context: String
        let seenAt: Date

        var dictionary: [String: Any] {
            [
                "surface": surface,
                "engine": engine,
                "guess": guess,
                "context": context,
                "seenAt": ISO8601DateFormatter().string(from: seenAt),
            ]
        }
    }

    // MARK: - 語の切り出し

    /// 漢字を含む語だけを見る。かなだけの語で読みを外すことはまず無い
    static func words(in text: String) -> [(word: String, context: String)] {
        var found: [(String, String)] = []
        var seen = Set<String>()

        func take(_ word: String, _ sentence: String) {
            // 送り仮名の付いた語は外す。「保た」だけを単体で読ませると
            // 「タモテタ」のような妙な読みが返り、食い違いの山になる。
            // 拾いたいのは固有名詞と熟語で、そこは送り仮名を持たない
            guard word.count >= 2, word.count <= 16,
                  hasKanji(word), !hasHiragana(word), !seen.contains(word)
            else { return }
            seen.insert(word)
            found.append((word, String(sentence.prefix(60))))
        }

        for sentence in Sanitizer.sentences(from: text) {
            let cf = sentence as CFString
            let text = sentence as NSString
            let tokenizer = CFStringTokenizerCreate(
                kCFAllocatorDefault, cf, CFRangeMake(0, CFStringGetLength(cf)),
                kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale)
            var previous: NSRange?
            while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
                let cfRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                let range = NSRange(location: cfRange.location, length: cfRange.length)
                take(text.substring(with: range), sentence)
                // 隣り合う語をくっつけたものも見る。
                // engine の切りかたと macOS の切りかたは同じではない。
                // 「生中継」は macOS が「生」＋「中継」に割るので、割れたままだと
                // engine が丸ごと読み違えていることに気づけない
                if let previous, previous.location + previous.length == range.location {
                    take(text.substring(with: NSUnionRange(previous, range)), sentence)
                }
                previous = range
            }
        }
        return found
    }

    private static func hasKanji(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains(Int($0.value)) }
    }

    private static func hasHiragana(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3041...0x309F).contains(Int($0.value)) }
    }

    // MARK: - macOS 側の読み

    /// 取れなければ nil。取れないものを「食い違い」に数えると空振りだらけになる
    static func macReading(_ word: String) -> String? {
        let cf = word as CFString
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, cf, CFRangeMake(0, CFStringGetLength(cf)),
            kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale)
        var latin = ""
        var pieces = 0
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            guard let part = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
            else { return nil }
            // 「々」のように転写できない字が混じると、そこだけ記号が返る。
            // そういう語は macOS 側が分かっていないので、意見として採らない
            guard part.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == " " || $0 == "'") })
            else { return nil }
            latin += part
            pieces += 1
        }
        guard !latin.isEmpty else { return nil }
        // 1字ずつに割れた語は、macOS が語として知らなかったということ。意見として弱い
        guard pieces < word.count else { return nil }

        let mutable = NSMutableString(string: latin) as CFMutableString
        guard CFStringTransform(mutable, nil, kCFStringTransformLatinKatakana, false) else {
            return nil
        }
        return (mutable as String).replacingOccurrences(of: " ", with: "")
    }

    // MARK: - 突き合わせ

    /// 長音の書きかたの違いで食い違いにしない。
    ///
    /// AivisSpeech は「こうもく」を「コオモク」と書き、macOS 経由では「コウモク」になる。
    /// 「せい」も「セエ」と「セイ」に割れる。どちらも同じ音なので、
    /// オ段の後ろのウ／エ段の後ろのイを寄せてから比べる
    static func normalize(_ kana: String) -> String {
        var out: [Character] = []
        for character in kana {
            if character == "ー" { continue }
            var next = character
            if next == "ヂ" { next = "ジ" }
            if next == "ヅ" { next = "ズ" }
            if let previous = out.last {
                if next == "ウ", vowel(previous) == "オ" { next = "オ" }
                if next == "イ", vowel(previous) == "エ" { next = "エ" }
            }
            out.append(next)
        }
        return String(out)
    }

    /// そのモーラの母音。長音を寄せるためだけに使う
    private static func vowel(_ kana: Character) -> Character? {
        if "アカサタナハマヤラワガザダバパャヮファヴァ".contains(kana) { return "ア" }
        if "イキシチニヒミリギジヂビピ".contains(kana) { return "イ" }
        if "ウクスツヌフムユルグズヅブプュヴ".contains(kana) { return "ウ" }
        if "エケセテネヘメレゲゼデベペェ".contains(kana) { return "エ" }
        if "オコソトノホモヨロヲゴゾドボポョ".contains(kana) { return "オ" }
        return nil
    }

    static func disagrees(engine: String, guess: String) -> Bool {
        !engine.isEmpty && !guess.isEmpty && normalize(engine) != normalize(guess)
    }

    // MARK: - 溜め場

    /// 見つけた候補と、登録しないと決めた語。
    /// 決めた語を覚えておかないと、読むたびに同じものを差し出し続けることになる
    struct Store: Codable {
        var pending: [Candidate] = []
        var ignored: [String] = []
    }

    static let fileURL = Settings.directory.appendingPathComponent("yomi.json")
    private static let limit = 200

    static func load() -> Store {
        guard let data = try? Data(contentsOf: fileURL),
              let store = try? JSONDecoder.yomi.decode(Store.self, from: data)
        else { return Store() }
        return store
    }

    static func save(_ store: Store) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(store) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    @discardableResult
    static func append(_ candidates: [Candidate]) -> [Candidate] {
        var store = load()
        var added: [Candidate] = []
        for candidate in candidates {
            guard !store.ignored.contains(candidate.surface),
                  !store.pending.contains(where: { $0.surface == candidate.surface })
            else { continue }
            store.pending.append(candidate)
            added.append(candidate)
        }
        if store.pending.count > limit {
            store.pending.removeFirst(store.pending.count - limit)
        }
        if !added.isEmpty {
            save(store)
            Log.write("yomi: 怪しい読みを \(added.count)語 見つけた（\(added.map(\.surface).joined(separator: "、"))）")
        }
        return added
    }

    /// 片付いた語を落とす。登録したときも、見送ったときもここを通る
    static func resolve(surface: String, ignore: Bool) {
        var store = load()
        store.pending.removeAll { $0.surface == surface }
        if ignore, !store.ignored.contains(surface) {
            store.ignored.append(surface)
        }
        save(store)
    }
}

extension JSONDecoder {
    /// Store の日付は ISO8601 で書いている
    static var yomi: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
