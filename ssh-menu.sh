#!/usr/bin/env bash
# ssh-menu.sh — Interactive SSH server manager
# Stores servers in $SSH_MENU_CONFIG (default: ~/.config/ssh-menu/servers)
# Config file format (one entry per line): name:user:host:port

set -euo pipefail

CONFIG_DIR="${SSH_MENU_CONFIG_DIR:-$HOME/.config/ssh-menu}"
CONFIG_FILE="$CONFIG_DIR/servers"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_ensure_config() {
    mkdir -p "$CONFIG_DIR"
    touch "$CONFIG_FILE"
}

_server_count() {
    wc -l < "$CONFIG_FILE" 2>/dev/null || echo 0
}

_get_field() {
    # _get_field <line> <field_index 1-based>
    echo "$1" | cut -d: -f"$2"
}

_list_servers() {
    local count
    count=$(_server_count)
    if [[ "$count" -eq 0 ]]; then
        echo "  (no servers saved)"
        return
    fi

    # First pass: find max username length for alignment
    local max_user_len=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local user
        user=$(_get_field "$line" 2)
        if [[ ${#user} -gt $max_user_len ]]; then
            max_user_len=${#user}
        fi
    done < "$CONFIG_FILE"

    # Second pass: display with aligned @ symbols and separate port column
    local i=1
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local name user host port
        name=$(_get_field "$line" 1)
        user=$(_get_field "$line" 2)
        host=$(_get_field "$line" 3)
        port=$(_get_field "$line" 4)
        printf "  %2d) %-20s %*s@%-25s %s\n" "$i" "$name" "$max_user_len" "$user" "$host" "$port"
        ((i++))
    done < "$CONFIG_FILE"
}

_get_server_by_index() {
    local index="$1"
    sed -n "${index}p" "$CONFIG_FILE"
}

_validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]]
}

_prompt_server_fields() {
    # Prompts for name/user/host/port; sets globals: _name _user _host _port
    local default_name="${1:-}" default_user="${2:-}" default_host="${3:-}" default_port="${4:-22}"

    while true; do
        read -rp "  Name [${default_name}]: " _name
        _name="${_name:-$default_name}"
        [[ -n "$_name" ]] && break
        echo "  Name cannot be empty."
    done

    while true; do
        read -rp "  User [${default_user}]: " _user
        _user="${_user:-$default_user}"
        [[ -n "$_user" ]] && break
        echo "  User cannot be empty."
    done

    while true; do
        read -rp "  Host [${default_host}]: " _host
        _host="${_host:-$default_host}"
        [[ -n "$_host" ]] && break
        echo "  Host cannot be empty."
    done

    while true; do
        read -rp "  Port [${default_port}]: " _port
        _port="${_port:-$default_port}"
        if _validate_port "$_port"; then
            break
        fi
        echo "  Port must be a number between 1 and 65535."
    done
}

_select_server() {
    local prompt="${1:-Select a server}"
    local total
    total=$(_server_count)
    if [[ "$total" -eq 0 ]]; then
        echo "  No servers saved yet."
        return 1
    fi
    _list_servers
    while true; do
        read -rp "  $prompt (1-${total}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$total" ]]; then
            _selected_line=$(_get_server_by_index "$choice")
            _selected_index="$choice"
            return 0
        fi
        echo "  Invalid selection. Enter a number between 1 and ${total}."
    done
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

cmd_add() {
    echo ""
    echo "--- Add Server ---"
    local _name _user _host _port
    _prompt_server_fields
    echo "${_name}:${_user}:${_host}:${_port}" >> "$CONFIG_FILE"
    echo "  Saved '${_name}'."
}

cmd_connect() {
    echo ""
    echo "--- Connect to Server ---"
    local _selected_line _selected_index
    _select_server "Connect to server" || return 0
    local name user host port
    name=$(_get_field "$_selected_line" 1)
    user=$(_get_field "$_selected_line" 2)
    host=$(_get_field "$_selected_line" 3)
    port=$(_get_field "$_selected_line" 4)
    echo "  Connecting to ${name} (${user}@${host}:${port})..."
    ssh -p "$port" "${user}@${host}"
}

cmd_edit() {
    echo ""
    echo "--- Edit Server ---"
    local _selected_line _selected_index
    _select_server "Edit server" || return 0
    local name user host port
    name=$(_get_field "$_selected_line" 1)
    user=$(_get_field "$_selected_line" 2)
    host=$(_get_field "$_selected_line" 3)
    port=$(_get_field "$_selected_line" 4)
    echo "  Editing '${name}' (press Enter to keep current value):"
    local _name _user _host _port
    _prompt_server_fields "$name" "$user" "$host" "$port"
    # Replace line in config file
    local tmp_file
    tmp_file=$(mktemp)
    awk -v idx="$_selected_index" -v new="${_name}:${_user}:${_host}:${_port}" \
        'NR==idx {print new; next} {print}' "$CONFIG_FILE" > "$tmp_file"
    mv "$tmp_file" "$CONFIG_FILE"
    echo "  Updated '${_name}'."
}

cmd_delete() {
    echo ""
    echo "--- Delete Server ---"
    local _selected_line _selected_index
    _select_server "Delete server" || return 0
    local name
    name=$(_get_field "$_selected_line" 1)
    read -rp "  Delete '${name}'? [y/N]: " confirm
    if [[ "${confirm,,}" == "y" ]]; then
        local tmp_file
        tmp_file=$(mktemp)
        awk -v idx="$_selected_index" 'NR!=idx' "$CONFIG_FILE" > "$tmp_file"
        mv "$tmp_file" "$CONFIG_FILE"
        echo "  Deleted '${name}'."
    else
        echo "  Cancelled."
    fi
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------

main_menu() {
    while true; do
        echo ""
        echo "=============================="
        echo "        SSH Menu"
        echo "=============================="
        _list_servers
        echo ""
        echo "  a) Add server"
        echo "  c) Connect to server"
        echo "  e) Edit server"
        echo "  d) Delete server"
        echo "  q) Quit"
        echo ""
        read -rp "  Choice: " choice
        case "${choice,,}" in
            a) cmd_add ;;
            c) cmd_connect ;;
            e) cmd_edit ;;
            d) cmd_delete ;;
            q) echo "Goodbye."; exit 0 ;;
            *) echo "  Unknown option. Please choose a, c, e, d, or q." ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

_ensure_config

# Allow non-interactive invocation for scripting/testing
case "${1:-}" in
    add)     shift; cmd_add "$@" ;;
    connect) shift; cmd_connect "$@" ;;
    edit)    shift; cmd_edit "$@" ;;
    delete)  shift; cmd_delete "$@" ;;
    list)    _list_servers ;;
    *)       main_menu ;;
esac
