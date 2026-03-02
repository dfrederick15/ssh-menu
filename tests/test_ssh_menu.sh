#!/usr/bin/env bash
# Tests for ssh-menu.sh
# Run with: bash tests/test_ssh_menu.sh

# -e is intentionally omitted: test assertions must continue after a subcommand fails
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/ssh-menu.sh"
PASS=0
FAIL=0

# Use a temp config directory for all tests
export SSH_MENU_CONFIG_DIR
SSH_MENU_CONFIG_DIR=$(mktemp -d)
CONFIG_FILE="$SSH_MENU_CONFIG_DIR/servers"

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

_assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: $desc"
        ((PASS++))
    else
        echo "FAIL: $desc"
        echo "      expected: '$expected'"
        echo "      actual:   '$actual'"
        ((FAIL++))
    fi
}

_assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "PASS: $desc"
        ((PASS++))
    else
        echo "FAIL: $desc"
        echo "      expected to contain: '$needle'"
        echo "      actual output: '$haystack'"
        ((FAIL++))
    fi
}

_assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if ! echo "$haystack" | grep -qF "$needle"; then
        echo "PASS: $desc"
        ((PASS++))
    else
        echo "FAIL: $desc"
        echo "      expected NOT to contain: '$needle'"
        echo "      actual output: '$haystack'"
        ((FAIL++))
    fi
}

_reset_config() {
    > "$CONFIG_FILE"
}

_add_server_direct() {
    # Write a server entry directly to the config file
    echo "$1" >> "$CONFIG_FILE"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

echo "=== SSH Menu Tests ==="
echo ""

# -- Config directory creation -----------------------------------------------
echo "--- Config & List ---"

_reset_config
output=$(bash "$SCRIPT" list)
_assert_contains "empty list shows placeholder" "(no servers saved)" "$output"

# -- Add via stdin -----------------------------------------------------------
echo "--- Add ---"

_reset_config
output=$(printf 'myserver\ndeployer\nexample.com\n2222\n' | bash "$SCRIPT" add)
_assert_contains "add success message" "Saved 'myserver'" "$output"
_assert_eq "add writes config line" "myserver:deployer:example.com:2222" "$(cat "$CONFIG_FILE")"

# -- List after add ----------------------------------------------------------
_reset_config
_add_server_direct "web1:ubuntu:web1.example.com:22"
_add_server_direct "db1:root:db.internal:2222"
output=$(bash "$SCRIPT" list)
_assert_contains "list shows first server name" "web1" "$output"
_assert_contains "list shows second server name" "db1" "$output"
_assert_contains "list shows user@host" "ubuntu@web1.example.com:22" "$output"

# -- Edit --------------------------------------------------------------------
echo "--- Edit ---"

_reset_config
_add_server_direct "oldname:alice:old.host.com:22"
# Select server 1; enter new values
output=$(printf '1\nnewname\nbob\nnew.host.com\n2222\n' | bash "$SCRIPT" edit)
_assert_contains "edit success message" "Updated 'newname'" "$output"
_assert_eq "edit rewrites config line" "newname:bob:new.host.com:2222" "$(cat "$CONFIG_FILE")"

# -- Edit keeps existing values when Enter is pressed ------------------------
_reset_config
_add_server_direct "keep:carol:keep.host.com:22"
# Press Enter for all fields (empty input = keep defaults)
output=$(printf '1\n\n\n\n\n' | bash "$SCRIPT" edit)
_assert_contains "edit keep values success message" "Updated 'keep'" "$output"
_assert_eq "edit keep values unchanged" "keep:carol:keep.host.com:22" "$(cat "$CONFIG_FILE")"

# -- Delete ------------------------------------------------------------------
echo "--- Delete ---"

_reset_config
_add_server_direct "tokeep:user1:host1.com:22"
_add_server_direct "todelete:user2:host2.com:22"
output=$(printf '2\ny\n' | bash "$SCRIPT" delete)
_assert_contains "delete success message" "Deleted 'todelete'" "$output"
remaining=$(cat "$CONFIG_FILE")
_assert_contains "delete keeps other server" "tokeep" "$remaining"
_assert_not_contains "delete removes target server" "todelete" "$remaining"

# -- Delete cancelled --------------------------------------------------------
_reset_config
_add_server_direct "server1:user:host.com:22"
output=$(printf '1\nN\n' | bash "$SCRIPT" delete)
_assert_contains "delete cancel shows cancelled" "Cancelled" "$output"
_assert_eq "delete cancel keeps server" "server1:user:host.com:22" "$(cat "$CONFIG_FILE")"

# -- Port validation ---------------------------------------------------------
echo "--- Port validation ---"

_reset_config
# First attempt: invalid port; second attempt: valid port
output=$(printf 'testserver\ntestuser\ntest.host.com\nabc\n9999\n' | bash "$SCRIPT" add)
_assert_contains "port validation rejects non-numeric" "Port must be a number" "$output"
_assert_contains "port validation accepts valid port" "Saved 'testserver'" "$output"
_assert_eq "port validation writes correct port" "testserver:testuser:test.host.com:9999" "$(cat "$CONFIG_FILE")"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=============================="
echo "Results: $PASS passed, $FAIL failed"
echo "=============================="

# Clean up temp directory
rm -rf "$SSH_MENU_CONFIG_DIR"

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
