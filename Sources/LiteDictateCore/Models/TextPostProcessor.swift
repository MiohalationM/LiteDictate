import Darwin
import Foundation

public struct AliasRule: Codable, Equatable, Sendable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// Loads user `vocab.txt` (<= 50 entries) and `aliases.json` post-processing rules.
/// Caps config file reads at 256 KiB before reading into memory (P2-4). Never logs transcripts or prompts.
public final class TextPostProcessor: Sendable {
    public static let maxConfigFileBytes: UInt64 = 256 * 1024 // 256 KiB

    public let vocabulary: [String]
    public let aliases: [AliasRule]

    public init(vocabulary: [String] = [], aliases: [AliasRule] = []) {
        self.vocabulary = Self.sanitizeVocabulary(vocabulary)
        self.aliases = Self.sortAliasesLongestFirst(aliases)
    }

    public static func load(vocabPath: String, aliasesPath: String) -> TextPostProcessor {
        let vocab = loadVocabulary(fromPath: vocabPath)
        let aliases = loadAliases(fromPath: aliasesPath)
        return TextPostProcessor(vocabulary: vocab, aliases: aliases)
    }

    private static func isWithinSizeBudget(path: String) -> Bool {
        var st = Darwin.stat()
        guard path.withCString({ fstatat(AT_FDCWD, $0, &st, 0) }) == 0 else { return false }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return false }
        return st.st_size >= 0 && UInt64(st.st_size) <= maxConfigFileBytes
    }

    public static func loadVocabulary(fromPath path: String) -> [String] {
        guard isWithinSizeBudget(path: path),
              let content = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            return []
        }
        let lines = content.components(separatedBy: .newlines)
        return sanitizeVocabulary(lines)
    }

    public static func sanitizeVocabulary(_ entries: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(min(entries.count, LiteDictateConstants.maxVocabEntries))
        for raw in entries {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
            if result.count >= LiteDictateConstants.maxVocabEntries {
                break
            }
        }
        return result
    }

    public static func loadAliases(fromPath path: String) -> [AliasRule] {
        guard isWithinSizeBudget(path: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        else {
            return []
        }
        // Support both `{"Swift UI": "SwiftUI"}` map and `[{"from": "...", "to": "..."}]` array.
        if let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            let rules = dict.compactMap { key, val -> AliasRule? in
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : AliasRule(from: key, to: val)
            }
            return sortAliasesLongestFirst(rules)
        }
        if let arr = try? JSONDecoder().decode([AliasRule].self, from: data) {
            return sortAliasesLongestFirst(arr.filter { !$0.from.isEmpty })
        }
        return []
    }

    private static func sortAliasesLongestFirst(_ rules: [AliasRule]) -> [AliasRule] {
        rules.sorted { lhs, rhs in
            if lhs.from.count != rhs.from.count {
                return lhs.from.count > rhs.from.count
            }
            return lhs.from < rhs.from
        }
    }

    /// Maps hotwords cleanly per model capability (Section 4.3):
    /// - `supportsVocabulary`: passes `vocabulary` list (<= 50 entries)
    /// - else `supportsContextPrompt || supportsInitialPrompt`: passes lightweight `contextPrompt`
    /// - else: passes neither so incompatible models never error.
    public func inferencePromptParameters(for capabilities: ModelCapabilities) -> (vocabulary: [String]?, contextPrompt: String?) {
        guard !vocabulary.isEmpty else { return (nil, nil) }
        if capabilities.supportsVocabulary {
            return (vocabulary, nil)
        }
        if capabilities.supportsContextPrompt || capabilities.supportsInitialPrompt {
            let prompt = vocabulary.joined(separator: ", ")
            return (nil, prompt)
        }
        return (nil, nil)
    }

    /// Applies deterministic longest-key-first alias replacements on transcribed text.
    public func applyAliases(to text: String) -> String {
        guard !text.isEmpty, !aliases.isEmpty else { return text }
        var output = text
        for rule in aliases {
            output = output.replacingOccurrences(of: rule.from, with: rule.to)
        }
        return output
    }
}
