#!/bin/zsh
# build_tests.sh — Recompile the regression test binary from the latest source
set -e

# Dynamically resolve project root relative to this script's location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
PROJ="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SDK=$(xcrun --sdk macosx --show-sdk-path)

SOURCES=(
  "$PROJ/PeriodontalCharting/Testing/Suite/run_regression_tests.swift"
  # Audio — Wav2Vec2
  # Audio — Wav2Vec
  "$PROJ/PeriodontalCharting/Audio/Wav2Vec/Wav2VecEngine.swift"
  "$PROJ/PeriodontalCharting/Audio/Wav2Vec/PrefixTrie.swift"
  "$PROJ/PeriodontalCharting/Audio/Wav2Vec/CTCDecoder.swift"
  "$PROJ/PeriodontalCharting/Audio/Wav2Vec/Wav2VecViewModel.swift"
  "$PROJ/PeriodontalCharting/Audio/Wav2Vec/Wav2VecAudioCapture.swift"
  # NLP — Tokenizer
  "$PROJ/PeriodontalCharting/NLP/Tokenizer/VoiceTokenizer.swift"
  "$PROJ/PeriodontalCharting/NLP/Tokenizer/VoiceTokenizer+Helpers.swift"
  "$PROJ/PeriodontalCharting/NLP/Tokenizer/VoiceTokenizer+Parsing.swift"
  "$PROJ/PeriodontalCharting/NLP/Tokenizer/TokenizerManager.swift"
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
  "$PROJ/PeriodontalCharting/Audio/AppLog.swift"
)

BUILD_DIR="$PROJ/.build"
mkdir -p "$BUILD_DIR"

echo "Compiling CoreML model..."
xcrun coremlcompiler compile "$PROJ/PeriodontalCharting/AI/Wav2Vec_STT/Wav2Vec2_Indonesian_FP16.mlpackage" "$BUILD_DIR"

echo "Copying dictionaries..."
cp "$PROJ/PeriodontalCharting/AI/Wav2Vec_STT/vocab.json" "$BUILD_DIR/"
cp "$PROJ/PeriodontalCharting/AI/Wav2Vec_STT/lexicon.txt" "$BUILD_DIR/"
cp "$PROJ/PeriodontalCharting/AI/Wav2Vec_STT/canonical_mapping.json" "$BUILD_DIR/"

echo "Compiling regression test binary..."
swiftc \
  -sdk "$SDK" \
  -target arm64-apple-macosx14.0 \
  -framework SwiftUI \
  -framework Combine \
  -framework CoreML \
  -framework AVFoundation \
  -D REGRESSION_TEST \
  -o "$BUILD_DIR/run_tests" \
  "${SOURCES[@]}" \
  2>&1

echo "Done. Binary at: $PROJ/run_tests"
