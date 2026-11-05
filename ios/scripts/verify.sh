#!/bin/bash
set -eo pipefail
cd "$(dirname "$0")/../.."
verification_mode="${1:-unit}"
verification_scheme="Yueshan"
case "$verification_mode" in
  unit) test_targets=(-only-testing:YueshanTests) ;;
  ui) test_targets=(-only-testing:YueshanUITests) ;;
  all) test_targets=() ;;
  performance) verification_scheme="Yueshan Performance"; test_targets=() ;;
  *) echo "Usage: bash ios/scripts/verify.sh [unit|ui|all|performance]" >&2; exit 2 ;;
esac
npm run check
npm test
xcodebuild -project ios/Yueshan.xcodeproj -scheme "$verification_scheme" \
  -destination "${YUESHAN_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}" \
  -derivedDataPath "${YUESHAN_DERIVED_DATA:-/tmp/yueshan-development-derived}" \
  "${test_targets[@]}" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
