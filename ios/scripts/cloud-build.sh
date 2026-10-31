#!/usr/bin/env bash
# Run this on a rented/borrowed Mac to prove the iOS app compiles and to produce an unsigned IPA.
# It needs no Apple ID: signing is skipped here and done later on a machine that has the phone attached.
#
#   bash ios/scripts/cloud-build.sh
#
# Output: build/cloud/IPhoneAgent-unsigned.ipa (plus the raw .app under build/cloud/)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

echo "== Xcode =="
xcodebuild -version || { echo "xcodebuild missing: install Xcode first"; exit 1; }
echo

SDK=$(xcodebuild -showsdks 2>/dev/null | awk '/iphoneos/{print $2}' | tail -1)
echo "iOS SDK: ${SDK:-none}"
if [[ -z $SDK ]]; then echo "no iOS SDK (open Xcode once so it installs components)"; exit 1; fi

echo
echo "== build for device (unsigned) =="
xcodebuild -project IPhoneAgent.xcodeproj -scheme IPhoneAgent \
  -sdk iphoneos -configuration Release \
  -derivedDataPath build/cloud/dd \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build 2>&1 | tail -40
APP=build/cloud/dd/Build/Products/Release-iphoneos/IPhoneAgent.app
if [[ ! -d $APP ]]; then echo "build failed: $APP missing"; exit 1; fi

echo
echo "== package unsigned IPA =="
rm -rf build/cloud/Payload build/cloud/IPhoneAgent-unsigned.ipa
mkdir -p build/cloud/Payload
cp -R "$APP" build/cloud/Payload/
(cd build/cloud && zip -qry IPhoneAgent-unsigned.ipa Payload)
ls -lh build/cloud/IPhoneAgent-unsigned.ipa
echo
echo "Next: copy that IPA off this machine. It still has to be signed with an Apple ID and installed"
echo "from a computer that the iPhone is plugged into (Sideloadly on Windows, or Xcode on a Mac)."
