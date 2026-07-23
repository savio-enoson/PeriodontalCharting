#!/bin/bash
swiftc \
  PeriodontalCharting/Models/Models.swift \
  PeriodontalCharting/Models/ChartProcessor.swift \
  PeriodontalCharting/Configuration/ChartingConfiguration.swift \
  PeriodontalCharting/Configuration/ChartingCursor.swift \
  PeriodontalCharting/NLP/Models/VoiceToken.swift \
  PeriodontalCharting/NLP/Tokenizer/VoiceTokenizer.swift \
  PeriodontalCharting/NLP/Tokenizer/VoiceTokenizer+Helpers.swift \
  PeriodontalCharting/NLP/Tokenizer/VoiceTokenizer+Parsing.swift \
  PeriodontalCharting/NLP/Parser/VoiceCommandParser.swift \
  PeriodontalCharting/NLP/Parser/VoiceCommandParser+Parse.swift \
  PeriodontalCharting/NLP/Parser/VoiceCommandParser+Flush.swift \
  PeriodontalCharting/NLP/Parser/VoiceCommandParser+Lookahead.swift \
  PeriodontalCharting/Debug/ChartTestingUtilities.swift \
  PeriodontalCharting/TestTranscripts.swift \
  run_regression_tests.swift \
  -o test_runner

./test_runner
