#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/Vocab.xcodeproj"
DERIVED_DATA="$ROOT_DIR/performance-build"

echo "Measuring Vocab intake, OCR, and session performance acceptance tests..."
VOCAB_PERFORMANCE_TESTS=1 /usr/bin/time -lp xcodebuild \
  -project "$PROJECT" \
  -scheme Vocab \
  -destination "platform=macOS" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_TESTABILITY=YES \
  test \
  -only-testing:VocabTests/LearningCoordinatorTests/testPasteParserHandlesLargePastedTextWithHyphenatedTerms \
  -only-testing:VocabTests/LearningCoordinatorTests/testPasteParserHundredLineP95MeetsTarget \
  -only-testing:VocabTests/LearningCoordinatorTests/testGenerateSessionLargeFixtureP95MeetsTarget \
  -only-testing:VocabTests/OCRVocabularyFormatterTests/testRecoversNoisyNumbersAndLooserRowAlignment \
  -only-testing:VocabTests/OCRVocabularyFormatterTests/testHundredRowFixtureRecoversAtLeastNinetyEightRows
