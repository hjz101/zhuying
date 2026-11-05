#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
verification_mode="${1:-unit}"
case "$verification_mode" in
  unit) test_targets=(-only-testing:YueshanTests) ;;
  ui) test_targets=(-only-testing:YueshanUITests) ;;
  all) test_targets=() ;;
  *) echo "Usage: bash ios/scripts/verify.sh [unit|ui|all]" >&2; exit 2 ;;
esac
npm run check
npm test
xcodebuild -project ios/Yueshan.xcodeproj -scheme Yueshan \
  -destination "${YUESHAN_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}" \
  -derivedDataPath "${YUESHAN_DERIVED_DATA:-/tmp/yueshan-development-derived}" \
  "${test_targets[@]}" CODE_SIGNING_ALLOWED=NO test
