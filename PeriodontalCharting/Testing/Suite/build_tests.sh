#!/bin/zsh
# build_tests.sh — Recompile the regression test binary from the latest source
set -e

PROJ=/Users/vio/PycharmProjects/Periodontology/PeriodontalCharting
SDK=$(xcrun --sdk macosx --show-sdk-path)

SOURCES=(
  "$PROJ/PeriodontalCharting/Testing/Suite/run_regression_tests.swift"
  # NLP — Tokenizer
  "$PROJ/PeriodontalCharting/NLP/Tokenizer/VoiceTokenizer.swift"
  "$PROJ/PeriodontalCharting/NLP/Tokenizer/VoiceTokenizer+Helpers.swift"
  "$PROJ/PeriodontalCharting/NLP/Tokenizer/VoiceTokenizer+Parsing.swift"
  "$PROJ/PeriodontalCharting/NLP/Tokenizer/TokenizerManager.swift"
  "$PROJ/PeriodontalCharting/NLP/Tokenizer/MLTokenizerState.swift"
  "$PROJ/PeriodontalCharting/NLP/Tokenizer/MLVoiceTokenizer.swift"
  "$PROJ/PeriodontalCharting/NLP/Tokenizer/BertTokenizer.swift"
  # NLP — Models & Parser
  "$PROJ/PeriodontalCharting/NLP/Models/VoiceToken.swift"
  "$PROJ/PeriodontalCharting/NLP/Parser/StatefulParser.swift"
  "$PROJ/PeriodontalCharting/NLP/Parser/StatefulParser+Flush.swift"
  "$PROJ/PeriodontalCharting/NLP/Parser/StatefulParser+Lookahead.swift"
  # App Models
  "$PROJ/PeriodontalCharting/Models/Models.swift"
  "$PROJ/PeriodontalCharting/Models/ChartProcessor.swift"
  "$PROJ/PeriodontalCharting/Models/PatientChart.swift"
  # Configuration
  "$PROJ/PeriodontalCharting/Configuration/ChartingConfiguration.swift"
  "$PROJ/PeriodontalCharting/Configuration/ChartingCursor.swift"
  # Debug utilities
  "$PROJ/PeriodontalCharting/Debug/ChartTestingUtilities.swift"
)

echo "Compiling regression test binary..."
swiftc \
  -sdk "$SDK" \
  -target arm64-apple-macosx14.0 \
  -framework SwiftUI \
  -framework Combine \
  -framework CoreML \
  -D REGRESSION_TEST \
  -o "$PROJ/run_tests" \
  "${SOURCES[@]}" \
  2>&1

echo "Done. Binary at: $PROJ/run_tests"
