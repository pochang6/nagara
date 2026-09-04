import Foundation

// 届いたテキストの控え。
//
// Stop フックは応答のたびに投げてくるが、既定では鳴らさずここに積むだけ。
// 「これは聴きたい」と思った時点で、それはもう手元にある ―― という形にするための箱。
struct Utterance: Identifiable {
    let id = UUID()
    let text: String
    let title: String
    let source: String
    let receivedAt: Date

    init(text: String, source: String) {
        self.text = text
        self.source = source
        self.title = Sanitizer.title(for: text)
        self.receivedAt = Date()
    }
}

final class History {
    private(set) var items: [Utterance] = []   // 新しいものが先頭
    private var settings: Settings

    var onChange: (() -> Void)?

    init(settings: Settings) {
        self.settings = settings
    }

    func update(settings: Settings) {
        self.settings = settings
        trim()
    }

    var latest: Utterance? { items.first }

    /// 積むかどうかを決める。
    /// 「再生しました」のような短い操作応答まで朗読するようになると使い物にならない
    @discardableResult
    func add(text: String, source: String) -> Utterance? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let speakable = Sanitizer.speakable(from: trimmed, skipCodeBlocks: settings.skipCodeBlocks)
        guard speakable.count >= settings.minimumLength else {
            Log.write("history: 短すぎるので積まない (\(speakable.count)文字)")
            return nil
        }
        // 同じ応答が二重に届くことがある（フックと手動送信が重なるなど）
        if let first = items.first, first.text == trimmed {
            Log.write("history: 直前と同じなので積まない")
            return first
        }

        let item = Utterance(text: trimmed, source: source)
        items.insert(item, at: 0)
        trim()
        onChange?()
        Log.write("history: 受け取った [\(source)] \(item.title)")
        return item
    }

    func item(with id: UUID) -> Utterance? {
        items.first { $0.id == id }
    }

    func clear() {
        items.removeAll()
        onChange?()
    }

    private func trim() {
        let limit = max(1, settings.historyLimit)
        if items.count > limit {
            items.removeLast(items.count - limit)
        }
    }
}
