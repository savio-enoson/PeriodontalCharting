#!/bin/zsh
cd /Users/vio/XCodeProjects/PeriodontalCharting/PeriodontalCharting/Testing/Suite
zsh build_tests.sh
echo "Running tests (this takes ~3-4 minutes)..."
/Users/vio/XCodeProjects/PeriodontalCharting/.build/run_tests > test_out.txt

echo "Extracting outputs..."
awk '/Starting DR LUCKY/{flag=1; next} /Starting STUDENT/{flag=0} flag' test_out.txt > dr_lucky_out.txt
awk '/Starting STUDENT/{flag=1; next} /=== IDEAL TRANSCRIPT TESTS ===/{flag=0} flag' test_out.txt > student_out.txt

echo "=== DR LUCKY AUDIO EVAL ===" > eval_results.txt
python3 compute_wer.py dr_lucky_out.txt dr_lucky_ground_fixed.txt >> eval_results.txt
grep "DR LUCKY DIFFS:" test_out.txt >> eval_results.txt
grep "RTF:" dr_lucky_out.txt >> eval_results.txt

echo "\n=== STUDENT AUDIO EVAL ===" >> eval_results.txt
python3 compute_wer.py student_out.txt ../Raw/student_ground.txt >> eval_results.txt
grep "STUDENT DIFFS:" test_out.txt >> eval_results.txt
grep "RTF:" student_out.txt >> eval_results.txt

echo "\n=== IDEAL TEXT REGRESSION EVAL ===" >> eval_results.txt
grep "IDEAL" test_out.txt | grep "DIFFS" >> eval_results.txt

cat eval_results.txt
