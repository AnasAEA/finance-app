import Foundation

/// Test-only source-shape checks shared by the checkpoint freeze suites.
/// This is not Swift type analysis. It recognizes identifiers and punctuation,
/// skips nested comments and string text, and retains executable interpolation.
/// Member calls therefore do not depend on receiver names or whitespace.
enum CheckpointWriteSource {
    static let writerPath = "Persistence/EndedMonthCheckpointWriter.swift"
    static let repositoryPath = "Persistence/PeriodCheckpointRepository.swift"
    static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("FinanceApp")

    struct Declaration {
        let signature: [String]
        let body: [String]
        var complete: [String] { signature + ["{"] + body + ["}"] }
    }

    enum SourceError: Error { case malformedSource, missingOrOverloadedFunction(String) }

    static func read(_ path: String) throws -> [String] {
        try tokens(String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8))
    }

    static func tokens(_ source: String) throws -> [String] {
        var lexer = Lexer(characters: Array(source))
        return try lexer.code()
    }

    static func occurrences(_ pattern: [String], in tokens: [String]) -> [Int] {
        guard !pattern.isEmpty, tokens.count >= pattern.count else { return [] }
        return (0...(tokens.count - pattern.count)).filter {
            tokens[$0..<($0 + pattern.count)].elementsEqual(pattern)
        }
    }

    static func count(_ source: String, in tokens: [String]) throws -> Int {
        occurrences(try self.tokens(source), in: tokens).count
    }

    static func function(_ name: String, in tokens: [String]) throws -> Declaration {
        let starts = occurrences(["func", name, "("], in: tokens)
        guard starts.count == 1, let start = starts.first else {
            throw SourceError.missingOrOverloadedFunction(name)
        }
        // Balance the entire parameter list, including closure defaults. The
        // first brace in a declaration need not be the function body.
        let parameterEnd = try closing("(", ")", from: start + 2, in: tokens)
        guard let opening = tokens.indices.dropFirst(parameterEnd + 1)
            .first(where: { tokens[$0] == "{" }) else { throw SourceError.malformedSource }
        let end = try closing("{", "}", from: opening, in: tokens)
        return Declaration(
            signature: Array(tokens[start..<opening]),
            body: Array(tokens[(opening + 1)..<end])
        )
    }

    private static func closing(
        _ open: String, _ close: String, from start: Int, in tokens: [String]
    ) throws -> Int {
        var depth = 0
        for index in start..<tokens.count {
            if tokens[index] == open { depth += 1 }
            if tokens[index] == close { depth -= 1 }
            if depth == 0 { return index }
        }
        throw SourceError.malformedSource
    }

    /// One entry per call site, including repeated calls in the same file.
    /// The authorization base contains no unrelated production member store
    /// calls, so no receiver-specific or unrelated-call allowlist is needed.
    static func productionStoreCallSites() throws -> [String] {
        // Relative paths also work when #filePath and Foundation disagree on
        // a symlink spelling such as /tmp versus /private/tmp.
        guard let files = FileManager.default.enumerator(atPath: appRoot.path)
        else { throw SourceError.malformedSource }
        var sites: [String] = []
        for case let path as String in files where path.hasSuffix(".swift") {
            guard path != repositoryPath else { continue }
            let count = try count(".store(", in: read(path))
            sites.append(contentsOf: repeatElement(path, count: count))
        }
        return sites.sorted()
    }

    private struct Lexer {
        let characters: [Character]
        var index = 0

        func matches(_ text: String) -> Bool {
            let pattern = Array(text)
            guard index + pattern.count <= characters.count else { return false }
            return characters[index..<(index + pattern.count)].elementsEqual(pattern)
        }

        mutating func code(interpolation: Bool = false) throws -> [String] {
            var result: [String] = []
            var parentheses = 0
            while index < characters.count {
                let character = characters[index]
                if character.isWhitespace { index += 1; continue }
                if matches("//") {
                    while index < characters.count && characters[index] != "\n" { index += 1 }
                    continue
                }
                if matches("/*") {
                    index += 2
                    var depth = 1
                    while index < characters.count && depth > 0 {
                        if matches("/*") { depth += 1; index += 2 }
                        else if matches("*/") { depth -= 1; index += 2 }
                        else { index += 1 }
                    }
                    guard depth == 0 else { throw SourceError.malformedSource }
                    continue
                }
                var quote = index
                while quote < characters.count && characters[quote] == "#" { quote += 1 }
                if quote < characters.count && characters[quote] == "\"" {
                    result += try string(hashes: quote - index)
                    continue
                }
                if character == "`" {
                    index += 1
                    let start = index
                    while index < characters.count && characters[index] != "`" { index += 1 }
                    guard index < characters.count else { throw SourceError.malformedSource }
                    result.append(String(characters[start..<index]))
                    index += 1
                    continue
                }
                if character.isLetter || character.isNumber || character == "_" || character == "$" {
                    let start = index
                    repeat { index += 1 } while index < characters.count && (
                        characters[index].isLetter || characters[index].isNumber
                            || characters[index] == "_" || characters[index] == "$"
                    )
                    result.append(String(characters[start..<index]))
                    continue
                }
                if character == ")" && interpolation && parentheses == 0 {
                    index += 1
                    return result
                }
                if character == "(" { parentheses += 1 }
                if character == ")" { parentheses -= 1 }
                result.append(String(character))
                index += 1
            }
            guard !interpolation else { throw SourceError.malformedSource }
            return result
        }

        mutating func string(hashes: Int) throws -> [String] {
            index += hashes
            let quotes = matches("\"\"\"") ? 3 : 1
            index += quotes
            let terminator = String(repeating: "\"", count: quotes) + String(repeating: "#", count: hashes)
            let escape = "\\" + String(repeating: "#", count: hashes)
            var result = ["<string>"]
            while index < characters.count {
                if matches(terminator) {
                    index += terminator.count
                    result.append("</string>")
                    return result
                }
                if matches(escape) {
                    index += escape.count
                    if matches("(") {
                        index += 1
                        result += ["<interpolation>"] + (try code(interpolation: true)) + ["</interpolation>"]
                    } else {
                        index += 1
                    }
                } else {
                    index += 1
                }
            }
            throw SourceError.malformedSource
        }
    }
}
