import Foundation

/// 搜索框里的内容：小写、去掉首尾空白；全是字母数字（可以夹空格和 '）时还按拼音比
struct SearchQuery {
    let text: String
    /// 按拼音比用的字母（去掉空格和 '）；搜索词里有汉字等其它字符时为 nil
    let pinyinLetters: [UInt8]?

    init?(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        self.text = text
        let letters = text.unicodeScalars.filter { $0 != " " && $0 != "'" }
        if letters.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil) }) {
            pinyinLetters = letters.map { UInt8($0.value) }
        } else {
            pinyinLetters = nil
        }
    }
}

/// 一个能被搜到的东西（App、文件夹）：名字直接包含搜索词，或者按拼音对得上
struct SearchKey {
    /// 显示名和别的能搜到它的名字（小写）。别名比如 .app 的文件名：显示中文名的 App 文件名多半是英文（微信 → WeChat）；
    /// iPhone/iPad App 反过来，显示的是英文名，包里才有中文名（rednote → 小红书）
    let texts: [String]
    /// 上面带汉字的名字各自的拼音
    let pinyins: [[[UInt8]]]

    init(name: String, aliases: [String] = []) {
        let names = [name] + aliases.filter { !$0.isEmpty }
        texts = names.map { $0.lowercased() }
        pinyins = names.compactMap(Pinyin.syllables(of:))
    }

    func matches(_ query: SearchQuery) -> Bool {
        if texts.contains(where: { $0.contains(query.text) }) { return true }
        guard let letters = query.pinyinLetters else { return false }
        return pinyins.contains { Pinyin.matches(letters, syllables: $0) }
    }
}

/// 拼音搜索：xiaohongshu、xhs、xiaohs、hongshu 都能找到「小红书」
enum Pinyin {
    private static let lock = NSLock()
    /// 名字 → 拼音音节；算一次存起来（主界面和设置里的搜索都用）
    private static var cache: [String: [[UInt8]]] = [:]

    /// 名字里每个字一个音节，连着的字母、数字算一段：小红书 → [xiao, hong, shu]，QQ音乐 → [qq, yin, yue]。
    /// 名字里没有汉字返回 nil
    static func syllables(of name: String) -> [[UInt8]]? {
        guard name.contains(where: isHan) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[name] { return cached }
        let result = computeSyllables(of: name)
        cache[name] = result
        return result
    }

    /// 从名字的任意一个字开始、连续往后，每个字用它拼音的开头一段（至少一个字母）去对搜索词，最后一个字可以只打一半。
    /// 全拼、首字母、混着打都行：xiaohongshu、xhs、xiaohs、xhshu
    static func matches(_ query: [UInt8], syllables: [[UInt8]]) -> Bool {
        let q = query.count, s = syllables.count
        guard q > 0, s > 0 else { return false }
        // ok[i * (s + 1) + j]：搜索词从第 i 个字母起的部分，能从第 j 个字开始连续对上
        var ok = [Bool](repeating: false, count: (q + 1) * (s + 1))
        for j in 0...s { ok[q * (s + 1) + j] = true }
        for i in stride(from: q - 1, through: 0, by: -1) {
            for j in stride(from: s - 1, through: 0, by: -1) {
                let syllable = syllables[j]
                var k = 0
                while k < syllable.count, i + k < q, sameLetter(typed: query[i + k], syllable[k]) {
                    k += 1
                    if ok[(i + k) * (s + 1) + j + 1] {
                        ok[i * (s + 1) + j] = true
                        break
                    }
                }
            }
        }
        return (0..<s).contains { ok[$0] }
    }

    /// ü 存成 v（和输入法一样打 lv），打 u 也算
    private static func sameLetter(typed: UInt8, _ letter: UInt8) -> Bool {
        typed == letter || (letter == UInt8(ascii: "v") && typed == UInt8(ascii: "u"))
    }

    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.isIdeographic }
    }

    /// 系统分词按词给出读音，多音字按词读（音乐 → yinyue，银行 → yinhang），再按字切开
    private static func computeSyllables(of name: String) -> [[UInt8]] {
        let text = name as NSString
        guard let tokenizer = CFStringTokenizerCreate(nil, name as CFString, CFRange(location: 0, length: text.length),
                                                      kCFStringTokenizerUnitWord, Locale(identifier: "zh_Hans") as CFLocale)
        else { return name.filter(isHan).map { plainLetters(readingOf: $0) } }
        var result: [[UInt8]] = []
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let word = Array(text.substring(with: NSRange(location: range.location, length: range.length)))
            if word.allSatisfy(isHan) {
                let reading = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
                result += split(plainLetters(reading ?? ""), perCharacter: word.map { plainLetters(readingOf: $0) })
                continue
            }
            // 字母、数字连着的算一段（QQ、360），中间夹的汉字逐字转
            var run: [UInt8] = []
            for character in word {
                let letters = isHan(character) ? plainLetters(readingOf: character) : plainLetters(String(character))
                if isHan(character) || letters.isEmpty {
                    if !run.isEmpty { result.append(run) }
                    run = []
                    if !letters.isEmpty { result.append(letters) }
                } else {
                    run += letters
                }
            }
            if !run.isEmpty { result.append(run) }
        }
        return result
    }

    /// 一个字单独转的拼音（多音字取最常见的读法）
    private static func plainLetters(readingOf character: Character) -> [UInt8] {
        plainLetters(String(character).applyingTransform(.mandarinToLatin, reverse: false) ?? "")
    }

    /// 去掉声调，ü 换成 v，只留小写字母和数字
    private static func plainLetters(_ text: String) -> [UInt8] {
        let decomposed = text.lowercased().decomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "u\u{308}", with: "v")
        return decomposed.unicodeScalars.compactMap { scalar in
            scalar.isASCII && (scalar.properties.isLowercase || scalar.properties.numericType != nil) ? UInt8(scalar.value) : nil
        }
    }

    /// 把一个词的读音按字切开。逐字转会把多音字读错（音乐 → yin le），整词的读音是对的（yinyue）但连在一起：
    /// 找一种切法，让和逐字读音一样的字最多，而且每段都像个拼音（有元音、不以 i u v 开头、最长 6 个字母）
    private static func split(_ reading: [UInt8], perCharacter: [[UInt8]]) -> [[UInt8]] {
        let n = perCharacter.count, m = reading.count
        guard n > 0, m >= n, reading != Array(perCharacter.joined()) else { return perCharacter }
        // best[i][j]：前 i 个字正好用掉读音的前 j 个字母时，最多几个字和逐字读音一样；-1 表示切不出来
        var best = Array(repeating: Array(repeating: -1, count: m + 1), count: n + 1)
        var start = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        best[0][0] = 0
        for i in 1...n {
            for j in 1...m {
                for length in 1...min(6, j) where best[i - 1][j - length] >= 0 {
                    let part = Array(reading[(j - length)..<j])
                    let same = part == perCharacter[i - 1]
                    guard same || looksLikeSyllable(part) else { continue }
                    let score = best[i - 1][j - length] + (same ? 1 : 0)
                    if score > best[i][j] {
                        best[i][j] = score
                        start[i][j] = j - length
                    }
                }
            }
        }
        guard best[n][m] >= 0 else { return perCharacter }
        var parts: [[UInt8]] = []
        var end = m
        for i in stride(from: n, to: 0, by: -1) {
            parts.append(Array(reading[start[i][end]..<end]))
            end = start[i][end]
        }
        return parts.reversed()
    }

    private static let vowels = Set("aeiouv".utf8)
    /// 拼音音节不会以 i、u、ü 开头（写成 y、w）
    private static let impossibleFirstLetters = Set("iuv".utf8)

    private static func looksLikeSyllable(_ part: [UInt8]) -> Bool {
        guard let first = part.first, !impossibleFirstLetters.contains(first) else { return false }
        return part.contains { vowels.contains($0) }
    }
}
