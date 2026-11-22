import Foundation

/// 单词释义结果
struct WordLookupResult {
    let word: String
    let definition: String
    /// 释义来源展示文案
    let source: String
}

/// 单词释义：优先用当前 AI 引擎结合语境解释，失败时回退到免费在线词典（dictionaryapi.dev）。
struct WordLookupService {
    let aiService: AIService

    func lookup(word: String, sentence: String) async -> WordLookupResult? {
        if let explanation = await aiService.explainWord(word, sentence: sentence) {
            return WordLookupResult(word: word, definition: explanation, source: "AI 解释")
        }
        return await Self.freeDictionary(word: word)
    }

    // MARK: - 免费在线词典

    /// dictionaryapi.dev：免费、无需 API Key，提供英文释义
    private static func freeDictionary(word: String) async -> WordLookupResult? {
        guard let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(encoded)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let entries = try JSONDecoder().decode([Entry].self, from: data)
            guard let entry = entries.first,
                  let meaning = entry.meanings.first,
                  let definition = meaning.definitions.first else { return nil }

            var lines: [String] = []
            if let phonetic = entry.phonetic ?? entry.phonetics?.compactMap(\.text).first, !phonetic.isEmpty {
                lines.append(phonetic)
            }
            var meaningLine = ""
            if let partOfSpeech = meaning.partOfSpeech, !partOfSpeech.isEmpty {
                meaningLine += "\(partOfSpeech). "
            }
            meaningLine += definition.definition
            lines.append(meaningLine)
            if let example = definition.example, !example.isEmpty {
                lines.append("例句：\(example)")
            }
            return WordLookupResult(
                word: word,
                definition: lines.joined(separator: "\n"),
                source: "Free Dictionary（英文释义）"
            )
        } catch {
            return nil
        }
    }

    private struct Entry: Decodable {
        struct Phonetic: Decodable {
            let text: String?
        }
        struct Meaning: Decodable {
            struct Definition: Decodable {
                let definition: String
                let example: String?
            }
            let partOfSpeech: String?
            let definitions: [Definition]
        }
        let phonetic: String?
        let phonetics: [Phonetic]?
        let meanings: [Meaning]
    }
}
