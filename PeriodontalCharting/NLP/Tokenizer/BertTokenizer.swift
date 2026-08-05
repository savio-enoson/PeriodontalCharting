import Foundation

final class BertTokenizer: @unchecked Sendable {
    var vocab: [String: Int] = [:]
    
    let padTokenId = 0
    let unkTokenId = 1
    let clsTokenId = 2
    let sepTokenId = 3
    
    init() {
        var url = Bundle.main.url(forResource: "vocab", withExtension: "txt")
        #if DEBUG
        if url == nil {
            url = URL(fileURLWithPath: "/Users/vio/PycharmProjects/Periodontology/PeriodontalCharting/PeriodontalCharting/AI/vocab.txt")
        }
        #endif
        if let url = url,
           let content = try? String(contentsOf: url, encoding: .utf8) {
            let lines = content.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                if !line.isEmpty {
                    vocab[line] = index
                }
            }
        } else {
            print("WARNING: Could not load vocab.txt from Bundle.main")
        }
    }
    
    func encode(_ word: String) -> [Int] {
        let text = word.lowercased()
        var tokens: [Int] = []
        var start = 0
        let chars = Array(text)
        
        while start < chars.count {
            var end = chars.count
            var match: Int? = nil
            
            while start < end {
                let substr = String(chars[start..<end])
                let searchStr = start == 0 ? substr : "##" + substr
                if let id = vocab[searchStr] {
                    match = id
                    break
                }
                end -= 1
            }
            
            if let matchId = match {
                tokens.append(matchId)
                start = end
            } else {
                return [unkTokenId]
            }
        }
        return tokens
    }
}
