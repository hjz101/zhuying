#!/bin/bash
set -eo pipefail
cd "$(dirname "$0")/../.."
verification_mode="${1:-unit}"
verification_scheme="Zhuying"
case "$verification_mode" in
  unit) test_targets=(-only-testing:ZhuyingTests) ;;
  ui) test_targets=(-only-testing:ZhuyingUITests) ;;
  all) test_targets=() ;;
  performance) verification_scheme="Zhuying Performance"; test_targets=() ;;
  *) echo "Usage: bash ios/scripts/verify.sh [unit|ui|all|performance]" >&2; exit 2 ;;
esac
npm run check
npm test
xcodebuild -project ios/Zhuying.xcodeproj -scheme "$verification_scheme" \
  -destination "${ZHUYING_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}" \
  -derivedDataPath "${ZHUYING_DERIVED_DATA:-/tmp/zhuying-development-derived}" \
  "${test_targets[@]}" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
