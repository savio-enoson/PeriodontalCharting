import sys
from compute_wer import normalize_text, parse_log_for_words

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
                
                if min_cost == cost_sub:
                    ops[i][j] = ops[i-1][j-1] + [('SUB', ref[i-1], hyp[j-1])]
                elif min_cost == cost_del:
                    ops[i][j] = ops[i-1][j] + [('DEL', ref[i-1], '')]
                else:
                    ops[i][j] = ops[i][j-1] + [('INS', '', hyp[j-1])]
                    
    return ops[m][n]

def main():
    log_path = sys.argv[1]
    ref_path = sys.argv[2]
    
    with open(ref_path, 'r') as f:
        ref_text = f.read()
    
    ref_words = normalize_text(ref_text)
    hyp_words = parse_log_for_words(log_path)
    
    operations = levenshtein_ops(ref_words, hyp_words)
    
    errors = {}
    for op, ref, hyp in operations:
        if op == 'SUB':
            key = f"SUB '{ref}' -> '{hyp}'"
            errors[key] = errors.get(key, 0) + 1
        elif op == 'DEL':
            key = f"DEL '{ref}'"
            errors[key] = errors.get(key, 0) + 1
    
    sorted_errors = sorted(errors.items(), key=lambda x: x[1], reverse=True)
    print(f"Top Errors for {log_path}:")
    for k, v in sorted_errors[:20]:
        print(f"  {k}: {v} times")

if __name__ == "__main__":
    main()
