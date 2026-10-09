import Foundation
import NaturalLanguage

/// Centralized response and speech persona policy for Pinebot.
/// Enforces concise, natural Jarvis-like spoken responses while preserving rich chat output.
public enum ResponsePolicy {
    
    /// Concise Jarvis persona system prompt for all model providers and escalation.
    public static let standardPersonaSystemPrompt: String = """
    You are Pinebot, a concise, highly capable desktop companion inspired by Jarvis.
    Keep all spoken responses to 1 natural sentence (maximum 18 words).
    For informational questions, keep responses to at most 2 short sentences.
    Never use conversational filler, robotic pleasantries (e.g. 'Sure!', 'Certainly!', 'I have...'), or diagnostic commentary.
    State actions and answers directly and naturally.
    """
    
    /// System prompt for computer / desktop action tasks.
    public static let computerActionSystemPrompt: String = """
    You are Pinebot executing desktop actions.
    Report actions concisely and truthfully. Never claim an action succeeded unless verified.
    """
    
    /// Cleans raw response text for spoken audio (TTS).
    /// Strips markdown syntax, urls, code blocks, bullet points, robotic filler, and escalation notes,
    /// bounding the spoken output to natural short sentences.
    public static func spokenCleaned(_ rawText: String) -> String {
        var text = rawText
        
        // 1. Remove escalation notes like "*(Note: ...)*" or "[Note: ...]"
        text = text.replacingOccurrences(of: #"\*\([Nn]ote:.*?\)\*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[[Nn]ote:.*?\]"#, with: "", options: .regularExpression)
        
        // 2. Remove code blocks ```...``` entirely
        text = text.replacingOccurrences(of: #"```[\s\S]*?```"#, with: "", options: .regularExpression)
        
        // 3. Remove inline code backticks `code` -> code
        text = text.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        
        // 4. Remove markdown header lines entirely (### Header)
        text = text.replacingOccurrences(of: #"(?m)^#{1,6}\s+.*$"#, with: "", options: .regularExpression)
        
        // 5. Remove markdown links [title](url) -> title
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)
        
        // 6. Remove bold/italics: **bold** or *italic*
        text = text.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\*([^*]+)\*"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"__([^_]+)__"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"_([^_]+)_"#, with: "$1", options: .regularExpression)
        
        // 7. Remove list markers (- item, * item, 1. item)
        text = text.replacingOccurrences(of: #"(?m)^\s*[-*•]\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*\d+\.\s+"#, with: "", options: .regularExpression)
        
        // 8. Normalize whitespace and newlines first so leading whitespace does not block filler removal
        let lines = text.components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        text = lines.joined(separator: " ")
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        if text.isEmpty {
            return ""
        }
        
        // 9. Remove common robotic filler phrases iteratively at start
        let fillerPrefixes = [
            "sure, ", "sure! ", "sure. ",
            "certainly! ", "certainly, ", "certainly. ",
            "of course! ", "of course, ", "of course. ",
            "here you go: ", "here you go! ", "here you go, ",
            "here is your song: ", "here is your song. ", "here's your song: ",
            "here is: ", "here is ", "here are: ", "here are ", "here's: ", "here's ",
            "as requested, ", "as requested: ",
            "i have ", "i've ",
            "i can help with that. ", "i would be happy to help. "
        ]
        
        var matched = true
        while matched {
            matched = false
            let lower = text.lowercased()
            for prefix in fillerPrefixes {
                if lower.hasPrefix(prefix) {
                    text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    matched = true
                    break
                }
            }
        }
        
        if text.isEmpty {
            return ""
        }
        
        // 10. Extract grammatical sentences using NLTokenizer to preserve decimals ("3.5", "1.0") and abbreviations
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty {
                sentences.append(s)
            }
            return true
        }
        
        if sentences.isEmpty {
            sentences = [text]
        }
        
        let candidateSentences = Array(sentences.prefix(2))
        if candidateSentences.count == 1 {
            return shortenToClauseBoundary(candidateSentences[0], maxWords: 18)
        } else {
            let s0 = shortenToClauseBoundary(candidateSentences[0], maxWords: 18)
            let remainingWords = 30 - countWords(s0)
            if remainingWords >= 4 {
                let s1 = shortenToClauseBoundary(candidateSentences[1], maxWords: remainingWords)
                return s0 + " " + s1
            } else {
                return s0
            }
        }
    }
    
    private static func countWords(_ s: String) -> Int {
        s.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
    }
    
    private static func shortenToClauseBoundary(_ sentence: String, maxWords: Int) -> String {
        let words = sentence.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if words.count <= maxWords {
            return sentence
        }
        
        // Attempt to find a natural clause delimiter
        let clauseDelimiters = ["; ", ": ", " — ", " – ", " - ", ", and ", ", but ", ", so ", ", which ", ", "]
        
        var bestClause: String? = nil
        var bestWordCount = 0
        
        for delim in clauseDelimiters {
            let parts = sentence.components(separatedBy: delim)
            if parts.count > 1 {
                var cumulative = ""
                for (idx, part) in parts.enumerated() {
                    let candidate = idx == 0 ? part : cumulative + delim + part
                    let candidateWords = countWords(candidate)
                    if candidateWords >= 4 && candidateWords <= maxWords && candidateWords > bestWordCount {
                        bestWordCount = candidateWords
                        bestClause = candidate
                    }
                    cumulative = candidate
                }
            }
        }
        
        if let clause = bestClause {
            let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
            let punctuation: Set<Character> = [".", "!", "?"]
            if let last = trimmed.last, punctuation.contains(last) {
                return trimmed
            } else {
                let clean = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ",;:-— "))
                return clean + "."
            }
        }
        
        // Grammar takes priority over exact count: preserve whole brief sentence rather than severing words mid-clause
        return sentence
    }
}
