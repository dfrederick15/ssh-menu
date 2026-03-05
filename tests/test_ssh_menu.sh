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
_assert_contains "list shows user@host with port in separate column" "ubuntu@web1.example.com" "$output"

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

# -- Main menu number shortcut -----------------------------------------------
echo "--- Main menu number shortcut ---"

# Create a fake ssh to capture invocation without real connection
FAKE_BIN_DIR=$(mktemp -d)
cat > "$FAKE_BIN_DIR/ssh" << 'EOF'
#!/usr/bin/env bash
echo "SSH_MOCK: $*"
EOF
chmod +x "$FAKE_BIN_DIR/ssh"
OLD_PATH="$PATH"
export PATH="$FAKE_BIN_DIR:$PATH"

_reset_config
_add_server_direct "shortcut:bob:myhost.com:2222"
output=$(printf '1\nq\n' | bash "$SCRIPT")
_assert_contains "number in main menu shows connecting message" "Connecting to" "$output"
_assert_contains "number in main menu triggers ssh" "SSH_MOCK: -p 2222 -t bob@myhost.com" "$output"

# Invalid number (out of range)
_reset_config
_add_server_direct "oneserver:bob:myhost.com:22"
output=$(printf '5\nq\n' | bash "$SCRIPT")
_assert_contains "out-of-range number shows error" "Invalid selection" "$output"

# Number when no servers exist
_reset_config
output=$(printf '1\nq\n' | bash "$SCRIPT")
_assert_contains "number with no servers shows error" "No servers saved yet" "$output"

export PATH="$OLD_PATH"
rm -rf "$FAKE_BIN_DIR"

# -- Port validation ---------------------------------------------------------
echo "--- Port validation ---"

_reset_config
# First attempt: invalid port; second attempt: valid port
output=$(printf 'testserver\ntestuser\ntest.host.com\nabc\n9999\n' | bash "$SCRIPT" add)
_assert_contains "port validation rejects non-numeric" "Port must be a number" "$output"
_assert_contains "port validation accepts valid port" "Saved 'testserver'" "$output"
_assert_eq "port validation writes correct port" "testserver:testuser:test.host.com:9999" "$(cat "$CONFIG_FILE")"

# -- Install -----------------------------------------------------------------
echo "--- Install ---"

FAKE_INSTALL_DIR=$(mktemp -d)
export SSH_MENU_INSTALL_DIR="$FAKE_INSTALL_DIR"

# Fresh install
output=$(bash "$SCRIPT" install)
_assert_contains "install shows installing message" "Installing ssh-menu to" "$output"
_assert_contains "install shows done message" "Done!" "$output"
_assert_eq "install creates executable file" "0" "$([ -x "$FAKE_INSTALL_DIR/ssh-menu" ]; echo $?)"

# Update (install again over existing file)
output=$(bash "$SCRIPT" install)
_assert_contains "update shows updating message" "Updating ssh-menu at" "$output"
_assert_contains "update shows done message" "Done!" "$output"

# Already installed (running from install target)
output=$(SSH_MENU_INSTALL_DIR="$FAKE_INSTALL_DIR" bash "$FAKE_INSTALL_DIR/ssh-menu" install)
_assert_contains "already installed shows message" "already installed" "$output"

# No write permission
NO_WRITE_DIR=$(mktemp -d)
chmod -w "$NO_WRITE_DIR"
output=$(SSH_MENU_INSTALL_DIR="$NO_WRITE_DIR" bash "$SCRIPT" install 2>&1 || true)
_assert_contains "no write permission shows error" "No write permission" "$output"
chmod +w "$NO_WRITE_DIR"
rm -rf "$NO_WRITE_DIR"

# Non-existent install directory
output=$(SSH_MENU_INSTALL_DIR="/nonexistent/path/that/does/not/exist" bash "$SCRIPT" install 2>&1 || true)
_assert_contains "nonexistent install dir shows error" "does not exist" "$output"

unset SSH_MENU_INSTALL_DIR
rm -rf "$FAKE_INSTALL_DIR"

# -- Version and install status in main menu ---------------------------------
echo "--- Version & install status in main menu ---"

# Version number appears in main menu header
_reset_config
output=$(printf 'q\n' | bash "$SCRIPT")
_assert_contains "main menu shows version number" "v1.0.0" "$output"

# Install status shown when not installed
FAKE_INSTALL_DIR2=$(mktemp -d)
export SSH_MENU_INSTALL_DIR="$FAKE_INSTALL_DIR2"
_reset_config
output=$(printf 'q\n' | SSH_MENU_INSTALL_DIR="$FAKE_INSTALL_DIR2" bash "$SCRIPT")
_assert_contains "main menu shows not-installed status" "not installed to system path" "$output"
_assert_contains "main menu shows install option when not installed" "i)" "$output"

# Install option hidden when script is up to date (running from install target)
bash "$SCRIPT" install >/dev/null 2>&1
output=$(printf 'q\n' | SSH_MENU_INSTALL_DIR="$FAKE_INSTALL_DIR2" bash "$FAKE_INSTALL_DIR2/ssh-menu")
_assert_contains "main menu shows up-to-date status" "up to date" "$output"
_assert_not_contains "main menu hides install option when current" "i)" "$output"

# Install option shown when installed version differs (simulate outdated by installing then changing VERSION)
OUTDATED_SCRIPT=$(mktemp)
sed 's/^VERSION="[^"]*"/VERSION="0.9.0"/' "$SCRIPT" > "$OUTDATED_SCRIPT"
chmod +x "$OUTDATED_SCRIPT"
output=$(printf 'q\n' | SSH_MENU_INSTALL_DIR="$FAKE_INSTALL_DIR2" bash "$OUTDATED_SCRIPT")
_assert_contains "main menu shows outdated status" "available" "$output"
_assert_contains "main menu shows install option when outdated" "i)" "$output"
rm -f "$OUTDATED_SCRIPT"

# Typing 'i' when already current shows unknown option error
output=$(printf 'i\nq\n' | SSH_MENU_INSTALL_DIR="$FAKE_INSTALL_DIR2" bash "$FAKE_INSTALL_DIR2/ssh-menu")
_assert_contains "typing i when current shows unknown option" "Unknown option" "$output"

unset SSH_MENU_INSTALL_DIR
rm -rf "$FAKE_INSTALL_DIR2"

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
