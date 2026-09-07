#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ -z "${SPARKLE_SIGN_UPDATE:-}" && ! -x "$root/.build/artifacts/sparkle/Sparkle/bin/sign_update" ]]; then
    (cd "$root" && TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swift package resolve)
fi
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
cat > "$fixture/fixture.swift" <<'SWIFT'
import Foundation
import CryptoKit
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
let data = Data("real archive bytes".utf8)
try data.write(to: dir.appendingPathComponent("Debut.dmg"))
try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: dir.appendingPathComponent("private-key"))
let info = ["SUPublicEDKey": key.publicKey.rawRepresentation.base64EncodedString(),
            "CFBundleVersion": "10001", "CFBundleShortVersionString": "1.2.1", "LSMinimumSystemVersion": "27.0"]
try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: dir.appendingPathComponent("Info.plist"))
SWIFT
TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swift "$fixture/fixture.swift" "$fixture"
# This is Sparkle's real signer, not the contract test's stub.
SPARKLE_SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-$root/.build/artifacts/sparkle/Sparkle/bin/sign_update}" \
    "$root/scripts/generate-appcast.sh" 1.2.1 "$fixture/Debut.dmg" "$fixture/private-key" "$fixture/appcast.xml" "$fixture/Info.plist"
verify() { TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault /usr/bin/swift "$root/scripts/verify-appcast-signature.swift" "$fixture/appcast.xml" "$fixture/Debut.dmg" "$fixture/Info.plist"; }
verify
for tamper in archive length signature build minimum key; do
    cp "$fixture/appcast.xml" "$fixture/good.xml"
    cp "$fixture/Debut.dmg" "$fixture/good.dmg"
    cp "$fixture/Info.plist" "$fixture/good.plist"
    case "$tamper" in
        key) /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" "$fixture/Info.plist" ;;
        archive) printf 'corruption' >> "$fixture/Debut.dmg" ;;
        length) sed -i '' 's/length="[0-9]*"/length="1"/' "$fixture/appcast.xml" ;;
        signature) sed -i '' 's/sparkle:edSignature="[^"]*"/sparkle:edSignature="invalid"/' "$fixture/appcast.xml" ;;
        build) sed -i '' 's/>10001</>10002</' "$fixture/appcast.xml" ;;
        minimum) sed -i '' 's/>27.0</>26.0</' "$fixture/appcast.xml" ;;
    esac
    if verify >/dev/null 2>&1; then echo "FAIL: accepted altered $tamper" >&2; exit 1; fi
    mv "$fixture/good.xml" "$fixture/appcast.xml"
    mv "$fixture/good.dmg" "$fixture/Debut.dmg"
    mv "$fixture/good.plist" "$fixture/Info.plist"
done
echo 'PASS: real Sparkle signatures and packaged appcast metadata'
