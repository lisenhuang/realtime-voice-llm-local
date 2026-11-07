import Foundation
import SwiftUI

enum WebSearchProvider: String, CaseIterable { case appTools, model }
struct WebSearchCheck: Codable, Sendable {
    let model: String
    let effort: String
    let passed: Bool
    let seconds: Double
    let date: Date
    let detail: String
    var isRecentSuccess: Bool { passed && Date().timeIntervalSince(date) < 7 * 24 * 3600 }
    var summary: String { "\(passed ? "Verified" : "Not verified") · \(String(format: "%.1f", seconds))s · \(ChatGPTModel.effortLabel(effort))" }
}
struct TranscriptCitation: Codable, Sendable, Identifiable {
    var id: String { "\(start):\(end):\(url)" }
    let start: Int
    let end: Int
    let url: String
    let title: String
    var link: URL? {
        guard let link = URL(string: url), link.scheme == "https" || link.scheme == "http", link.host != nil, link.user == nil, link.password == nil else { return nil }
        return link
    }
}
extension TranscriptLine {
    var attributedText: AttributedString {
        let characters = Array(text.unicodeScalars)
        var output = AttributedString(); var cursor = 0
        for (index, citation) in citations.sorted(by: { $0.start < $1.start }).enumerated() {
            guard let url = citation.link, citation.start >= cursor, citation.end > citation.start, citation.end <= characters.count else { continue }
            output += AttributedString(String(String.UnicodeScalarView(characters[cursor..<citation.start])))
            let source = String(String.UnicodeScalarView(characters[citation.start..<citation.end]))
            var link = AttributedString(source.contains("") ? " [\(index + 1)]" : source)
            link.link = url; output += link; cursor = citation.end
        }
        output += AttributedString(String(String.UnicodeScalarView(characters[cursor...])))
        return output
    }
}
// Citation control tokens belong in the transcript, never in spoken audio.
struct SpokenTextFilter {
    static func comparisonText(_ text: String) -> String {
        var filter = SpokenTextFilter()
        return filter.append(text).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    private var inCitation = false
    mutating func append(_ text: String) -> String {
        var result = ""
        for character in text {
            if character == "" { inCitation = true }
            else if character == "" { inCitation = false }
            else if !inCitation { result.append(character) }
        }
        return result
    }
}
enum HostedSearch {
    static func request(model: String, effort: String?) -> [String: Any] {
        var body: [String: Any] = ["model": model, "store": false, "stream": true,
            "tools": [["type":"web_search"]], "tool_choice": "required",
            "input": [["role":"user", "content":"Search the web for the official OpenAI Responses API web search documentation. Give one short sentence and cite its official documentation URL."]],
            "instructions":"Perform one brief web search using the provided web_search tool. Do not merely describe your capabilities. Cite a source in your answer."]
        if let effort, ChatGPTModel.apiReasoningLevels.contains(effort) { body["reasoning"] = ["effort":effort] }
        return body
    }
    static func completedSearchCount(_ output: [[String: Any]]) -> Int {
        output.filter { $0["type"] as? String == "web_search_call" && $0["status"] as? String == "completed" }.count
    }
    static func citations(_ output: [[String: Any]], offset: Int = 0) -> [TranscriptCitation] {
        var result: [TranscriptCitation] = []; var position = offset
        for item in output where item["type"] as? String == "message" {
            for part in item["content"] as? [[String: Any]] ?? [] {
                guard let text = part["text"] as? String else { continue }
                for annotation in part["annotations"] as? [[String: Any]] ?? [] where annotation["type"] as? String == "url_citation" {
                    guard let url = annotation["url"] as? String else { continue }
                    let source = TranscriptCitation(start: position + (annotation["start_index"] as? Int ?? 0), end: position + (annotation["end_index"] as? Int ?? 0), url: url, title: annotation["title"] as? String ?? url)
                    if source.link != nil { result.append(source) }
                }
                position += text.unicodeScalars.count
            }
        }
        return result
    }
    static func textLength(_ output: [[String: Any]]) -> Int {
        output.filter { $0["type"] as? String == "message" }.flatMap { $0["content"] as? [[String: Any]] ?? [] }.compactMap { $0["text"] as? String }.reduce(0) { $0 + $1.unicodeScalars.count }
    }
}

actor WebProbeEvents {
    private var names = Set<String>()
    private var completions = 0
    func observe(_ name: String) {
        names.insert(name)
        if name == "response.web_search_call.completed" { completions += 1 }
    }
    func result() -> (completed: Int, names: String) { (completions, names.sorted().joined(separator: ", ")) }
}
