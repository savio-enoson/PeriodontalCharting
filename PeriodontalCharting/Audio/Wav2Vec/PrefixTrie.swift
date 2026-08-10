import Foundation

class TrieNode {
    var children: [Character: TrieNode] = [:]
    var isWord: Bool = false
}

class PrefixTrie {
    let root = TrieNode()
    
    init(lexiconPath: String? = nil) {
        if let path = lexiconPath {
            load(from: path)
        }
    }
    
    func insert(word: String) {
        var current = root
        for char in word {
            if current.children[char] == nil {
                current.children[char] = TrieNode()
            }
            current = current.children[char]!
        }
        current.isWord = true
    }
    
    func load(from path: String) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("Failed to load lexicon from \(path)")
            return
        }
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let parts = line.components(separatedBy: "\t")
            if let word = parts.first, !word.isEmpty {
                insert(word: word)
            }
        }
    }
    
    init(lexiconPath: String) {
        guard let data = try? String(contentsOfFile: lexiconPath, encoding: .utf8) else {
            print("Failed to load lexicon from \(lexiconPath)")
            return
        }
        
        for line in data.components(separatedBy: .newlines) {
            if line.isEmpty { continue }
            let parts = line.components(separatedBy: "\t")
            if parts.count > 0 {
                let word = parts[0]
                self.insert(word: word)
            }
        }
    }
    
    init(words: [String]) {
        for word in words {
            self.insert(word: word)
        }
    }
    
    /// Returns true if the string is either a valid prefix or a completed word.
    /// It handles space boundaries by resetting the search to the root for the next word.
    func isValidPrefix(sequence: String) -> Bool {
        var current = root
        
        // We split by space to evaluate only the current word being formed
        let words = sequence.split(separator: " ", omittingEmptySubsequences: false)
        guard let currentWord = words.last else { return true }
        
        // If the sequence ends with a space, it means the previous word was finalized.
        // We must ensure the previously finalized word was valid!
        if sequence.hasSuffix(" ") {
            if words.count > 1 {
                let prevWord = String(words[words.count - 2])
                if !isWord(prevWord) { return false }
            }
            return true // It's at the root for a new word
        }
        
        // Otherwise, check if the current word chunk is a valid prefix
        for char in currentWord {
            if let next = current.children[char] {
                current = next
            } else {
                return false
            }
        }
        
        return true
    }
    
    func isWord(_ word: String) -> Bool {
        var current = root
        for char in word {
            if let next = current.children[char] {
                current = next
            } else {
                return false
            }
        }
        return current.isWord
    }
}
