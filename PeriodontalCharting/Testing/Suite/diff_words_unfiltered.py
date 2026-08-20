import sys
import re

def normalize_word(word):
    mapping = {
        "satu": "1", "dua": "2", "tiga": "3", "empat": "4", "lima": "5",
        "enam": "6", "tujuh": "7", "delapan": "8", "sembilan": "9", "nol": "0",
        "gak": "tidak", "ndak": "tidak", "nggak": "tidak", "ga": "tidak",
        "min": "minus", "tiopi": "bop", "piope": "bop",
        "purkasi": "furkasi", "vurkasi": "furkasi",
        "rasesi": "resesi", "recesi": "resesi", "recession": "resesi",
        "poket": "probing", "pokat": "probing", "pocket": "probing",
        "paleto": "palatal", "pelatal": "palatal", "vokal": "bukal"
    }
    return mapping.get(word, word)

def normalize_text_unfiltered(text):
    text = text.lower()
    text = text.replace('\n', ' ')
    text = re.sub(r'[^\w\s-]', ' ', text)
    text = re.sub(r'\b(disto|mesio|mid)\s+', r'\1', text)
    def split_large_numbers(match):
        return " ".join(list(match.group(0)))
    text = re.sub(r'\b\d{2,}\b', split_large_numbers, text)
    text = text.replace('-', ' ')
    words = text.split()
    return [normalize_word(w) for w in words]

def parse_log_for_words_unfiltered(log_path):
    all_text = ""
    with open(log_path, 'r') as f:
        for line in f:
            if line.startswith("EARLY COMMIT:"):
                text = line[13:].split("->")[0].strip()
                if text: all_text += " " + text
            elif line.startswith("COMMIT:"):
                text = line[7:].strip()
                if text: all_text += " " + text
            elif line.startswith("FINAL COMMIT:"):
                text = line[13:].strip()
                if text: all_text += " " + text
    return normalize_text_unfiltered(all_text)

def levenshtein_ops(ref, hyp):
    m, n = len(ref), len(hyp)
    dp = [[0] * (n + 1) for _ in range(m + 1)]
    ops = [[[] for _ in range(n + 1)] for _ in range(m + 1)]
    for i in range(m + 1):
        dp[i][0] = i
        if i > 0: ops[i][0] = ops[i-1][0] + [('DEL', ref[i-1], '')]
    for j in range(n + 1):
        dp[0][j] = j
        if j > 0: ops[0][j] = ops[0][j-1] + [('INS', '', hyp[j-1])]
    for i in range(1, m + 1):
        for j in range(1, n + 1):
            if ref[i - 1] == hyp[j - 1]:
                dp[i][j] = dp[i - 1][j - 1]
                ops[i][j] = ops[i - 1][j - 1] + [('MATCH', ref[i-1], hyp[j-1])]
            else:
                cost_del = dp[i - 1][j] + 1
                cost_ins = dp[i][j - 1] + 1
                cost_sub = dp[i - 1][j - 1] + 1
                min_cost = min(cost_del, cost_ins, cost_sub)
                dp[i][j] = min_cost
                if min_cost == cost_sub: ops[i][j] = ops[i-1][j-1] + [('SUB', ref[i-1], hyp[j-1])]
                elif min_cost == cost_del: ops[i][j] = ops[i-1][j] + [('DEL', ref[i-1], '')]
                else: ops[i][j] = ops[i][j-1] + [('INS', '', hyp[j-1])]
    return ops[m][n]

log_path = sys.argv[1]
ref_path = sys.argv[2]
with open(ref_path, 'r') as f:
    ref_text = f.read()
ref_words = normalize_text_unfiltered(ref_text)
hyp_words = parse_log_for_words_unfiltered(log_path)
operations = levenshtein_ops(ref_words, hyp_words)
errors = {}
for op, ref, hyp in operations:
    if op == 'SUB': key = f"SUB '{ref}' -> '{hyp}'"
    elif op == 'DEL': key = f"DEL '{ref}'"
    elif op == 'INS': key = f"INS '{hyp}'"
    else: continue
    errors[key] = errors.get(key, 0) + 1
sorted_errors = sorted(errors.items(), key=lambda x: x[1], reverse=True)
print(f"Top Errors for {log_path}:")
for k, v in sorted_errors[:30]:
    print(f"  {k}: {v} times")
