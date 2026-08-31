#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
selector="$repo_root/scripts/select-signing-identity.sh"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

fake_security="$fixture_dir/security"
cat > "$fake_security" <<'EOF'
#!/bin/bash
printf '%s\n' "${FAKE_IDENTITIES:-}"
EOF
chmod +x "$fake_security"

expect_identity() {
    local expected="$1"
    local identities="$2"
    local override="${3:-}"
    local actual
    actual="$(FAKE_IDENTITIES="$identities" SECURITY_BIN="$fake_security" \
        "$selector" "$override")"
    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL: expected signing identity '$expected', got '$actual'" >&2
        exit 1
    fi
}

developer_hash="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
dev_hash="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
developer_line="  1) $developer_hash \"Developer ID Application: Tak Hing Lam (G3BV7DB653)\""
dev_line="  2) $dev_hash \"Debut Dev\""
other_developer_line="  3) CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC \"Developer ID Application: Someone Else (OTHERTEAM1)\""

expect_identity "$developer_hash" "$developer_line
$dev_line"
expect_identity "$dev_hash" "$dev_line"
expect_identity "$dev_hash" "$other_developer_line
$dev_line"
expect_identity "-" "     0 valid identities found"
expect_identity "explicit identity" "$developer_line
$dev_line" "explicit identity"

echo "PASS: signing identity selection"
