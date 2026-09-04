import Foundation

// Markdown をそのまま合成に流すと「バッククォート バッククォート」を延々聞かされる。
// 既存の読み上げツールが軒並み弱いのがここなので、最初から真面目にやる。
//
// 方針は「読んで意味のあるものだけ残す」。飾りは落とし、構造は句点に変える。
enum Sanitizer {

    static func speakable(from markdown: String, skipCodeBlocks: Bool) -> String {
        var text = markdown

        // 1. フェンス付きコードブロック。既定では丸ごと落とす
        text = replace(text, pattern: "(?ms)^[ \\t]*(```|~~~).*?^[ \\t]*\\1[ \\t]*$",
                       with: skipCodeBlocks ? "" : "$0")

        // 2. HTML コメントとタグ
        text = replace(text, pattern: "(?s)<!--.*?-->", with: "")
        text = replace(text, pattern: "(?s)<[^>]+>", with: "")

        // 3. 画像は読み上げようがない
        text = replace(text, pattern: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "")

        // 4. リンクは表示文字だけ残す。URL を音読されても困る
        text = replace(text, pattern: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1")

        // 5. 裸の URL
        text = replace(text, pattern: "https?://[^\\s、。）\\)]+", with: "リンク")

        var lines: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine

            // 表の区切り行（|---|---|）は読む意味がない
            if isTableSeparator(line) { continue }

            // 水平線
            if isHorizontalRule(line) { continue }

            // 表の行はセルを「、」で繋ぐ
            if line.contains("|") && line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                let cells = line.split(separator: "|").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
                line = cells.joined(separator: "、")
            }

            // 見出しの # と引用の >
            line = replace(line, pattern: "^\\s*#{1,6}\\s*", with: "")
            line = replace(line, pattern: "^\\s*>\\s?", with: "")

            // 箇条書きの記号と番号
            line = replace(line, pattern: "^\\s*[-*+]\\s+", with: "")
            line = replace(line, pattern: "^\\s*\\d+[.)]\\s+", with: "")

            // 強調とインラインコードの記号だけ剥がす。中身は残す
            line = replace(line, pattern: "`{1,3}([^`]*)`{1,3}", with: "$1")
            line = replace(line, pattern: "\\*\\*([^*]+)\\*\\*", with: "$1")
            line = replace(line, pattern: "__([^_]+)__", with: "$1")
            line = replace(line, pattern: "(?<![*\\w])\\*([^*\\n]+)\\*(?![*\\w])", with: "$1")
            line = replace(line, pattern: "~~([^~]+)~~", with: "$1")

            // 絵文字混じりの装飾記号。読み上げでは雑音にしかならない
            line = replace(line, pattern: "[│┃┌┐└┘├┤┬┴┼─━▸▾►▪◦]", with: "")

            line = line.trimmingCharacters(in: .whitespaces)
            lines.append(line)
        }

        // 空行の連続を1つに畳む
        var compacted: [String] = []
        for line in lines {
            if line.isEmpty, compacted.last?.isEmpty ?? true { continue }
            compacted.append(line)
        }

        return compacted.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 文に割る。1文ずつ合成することで、先読みも「1文戻る」も成り立つ
    static func sentences(from text: String, maxLength: Int = 90) -> [String] {
        var result: [String] = []
        var current = ""

        for character in text {
            if character == "\n" {
                if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                    result.append(current.trimmingCharacters(in: .whitespaces))
                }
                current = ""
                continue
            }
            current.append(character)
            if "。！？!?".contains(character) {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            result.append(current.trimmingCharacters(in: .whitespaces))
        }

        // 句点が来ないまま伸びた行は読点で割る。長すぎると合成待ちが目立つ
        var split: [String] = []
        for sentence in result {
            if sentence.count <= maxLength {
                split.append(sentence)
                continue
            }
            var buffer = ""
            for character in sentence {
                buffer.append(character)
                if buffer.count >= maxLength, "、,） )".contains(character) {
                    split.append(buffer)
                    buffer = ""
                }
            }
            if !buffer.isEmpty { split.append(buffer) }
        }

        return split.filter { !$0.isEmpty }
    }

    // 履歴メニューに出す見出し。長い応答でも一目で見分けられる程度に
    static func title(for text: String, limit: Int = 34) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if flat.count <= limit { return flat }
        return String(flat.prefix(limit)) + "…"
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        return trimmed.allSatisfy { $0 == "-" } || trimmed.allSatisfy { $0 == "=" }
            || trimmed.allSatisfy { $0 == "_" }
    }

    private static func replace(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
