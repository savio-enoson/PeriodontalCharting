import sys
import json
import re

def levenshtein(ref, hyp):
    m, n = len(ref), len(hyp)
    dp = [[0] * (n + 1) for _ in range(m + 1)]
    for i in range(m + 1):
        dp[i][0] = i
    for j in range(n + 1):
        dp[0][j] = j
    for i in range(1, m + 1):
        for j in range(1, n + 1):
            cost = 0 if ref[i - 1] == hyp[j - 1] else 1
            dp[i][j] = min(dp[i - 1][j] + 1,      # deletion
                           dp[i][j - 1] + 1,      # insertion
                           dp[i - 1][j - 1] + cost) # substitution
    return dp[m][n]

def normalize_word(word):
    mapping = {
        "satu": "1", "dua": "2", "tiga": "3", "empat": "4", "lima": "5",
        "enam": "6", "tujuh": "7", "delapan": "8", "sembilan": "9", "nol": "0",
        "gak": "tidak", "ndak": "tidak", "nggak": "tidak",
        "min": "minus", "tiopi": "bop", "piope": "bop",
        "purkasi": "furkasi", "vurkasi": "furkasi",
        "rasesi": "resesi", "recesi": "resesi", "recession": "resesi",
        "poket": "probing", "pokat": "probing", "pocket": "probing",
        "paleto": "palatal", "pelatal": "palatal", "vokal": "bukal"
    }
    return mapping.get(word, word)

def normalize_text(text):
    text = text.lower()
    text = text.replace('\n', ' ')
    text = re.sub(r'[^\w\s-]', ' ', text)
    
    # Strip spaces after anatomy prefixes to match STT compound words
    text = re.sub(r'\b(disto|mesio|mid)\s+', r'\1', text)
    
    def split_large_numbers(match):
        num_str = match.group(0)
        return " ".join(list(num_str))
    
    text = re.sub(r'\b\d{2,}\b', split_large_numbers, text)
    text = text.replace('-', ' ')
    
    words = text.split()
    
    # Filter out ghost words and non-diagnostic fillers
    ignore_words = {"gigi", "ada", "pada", "ke", "di", "bagian"}
    words = [w for w in words if w not in ignore_words]
    
    return [normalize_word(w) for w in words]

def parse_log_for_words(log_path):
    all_text = ""
    with open(log_path, 'r') as f:
        for line in f:
            if line.startswith("EARLY COMMIT:"):
                text = line[13:].split("->")[0].strip()
                if text:
                    all_text += " " + text
            elif line.startswith("COMMIT:"):
                text = line[7:].strip()
                if text:
                    all_text += " " + text
                    
    return normalize_text(all_text)

def main():
    if len(sys.argv) < 3:
        print("Usage: compute_wer.py <log_file> <reference_txt>")
        return
    log_path = sys.argv[1]
    ref_path = sys.argv[2]
    
    with open(ref_path, 'r') as f:
        ref_text = f.read()
    
    ref_words = normalize_text(ref_text)
    hyp_words = parse_log_for_words(log_path)
    
    distance = levenshtein(ref_words, hyp_words)
    wer = distance / len(ref_words) if len(ref_words) > 0 else 0
    
    print(f"Reference Words: {len(ref_words)}")
    print(f"Hypothesis Words: {len(hyp_words)}")
    print(f"Levenshtein Distance: {distance}")
    print(f"WER: {wer * 100:.2f}%")
    
if __name__ == "__main__":
    main()
