#!/usr/bin/env bash
# ssh-menu.sh — Interactive SSH server manager
# Stores servers in $SSH_MENU_CONFIG (default: ~/.config/ssh-menu/servers)
# Config file format (one entry per line): name:user:host:port
#
# Author:  Devin Frederick
# Contact: devin.frederick2012@gmail.com

set -euo pipefail

VERSION="1.0.0"

CONFIG_DIR="${SSH_MENU_CONFIG_DIR:-$HOME/.config/ssh-menu}"
CONFIG_FILE="$CONFIG_DIR/servers"

INSTALL_DIR="${SSH_MENU_INSTALL_DIR:-/usr/local/bin}"
INSTALL_TARGET="$INSTALL_DIR/ssh-menu"

# ---------------------------------------------------------------------------
# Colors (only when stdout is a terminal that supports color)
# ---------------------------------------------------------------------------

if [[ -t 1 ]] && tput colors &>/dev/null && [[ $(tput colors) -ge 8 ]]; then
    C_RESET=$(tput sgr0)
    C_BOLD=$(tput bold)
    C_CYAN=$(tput setaf 6)
    C_YELLOW=$(tput setaf 3)
    C_GREEN=$(tput setaf 2)
    C_RED=$(tput setaf 1)
else
    C_RESET=""
    C_BOLD=""
    C_CYAN=""
    C_YELLOW=""
    C_GREEN=""
    C_RED=""
fi

# Restore cursor visibility on exit (guards against tput civis left active)
trap 'tput cnorm 2>/dev/null || true' EXIT

# ---------------------------------------------------------------------------
# Terminal title
# ---------------------------------------------------------------------------

_set_title() {
    # Set the terminal window/tab title via OSC escape sequence.
    # No-op when stdout is not a terminal.
    [[ -t 1 ]] || return 0
    printf '\033]0;%s\007' "$*"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_read_key() {
    # Read one keypress; emit a normalised name for special keys.
    local key seq1 seq2
    IFS= read -r -s -n1 key
    if [[ "$key" == $'\x1b' ]]; then
        IFS= read -r -s -n1 -t 0.1 seq1 || true
        IFS= read -r -s -n1 -t 0.1 seq2 || true
        if [[ "$seq1" == '[' ]]; then
            case "$seq2" in
                A) printf 'up'   ;;
                B) printf 'down' ;;
                *) printf 'esc'  ;;
            esac
        else
            printf 'esc'
        fi
    elif [[ -z "$key" || "$key" == $'\n' ]]; then
        printf 'enter'
    else
        printf '%s' "$key"
    fi
}

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
        echo "  ${C_YELLOW}(no servers saved)${C_RESET}"
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
        printf "  ${C_YELLOW}${C_BOLD}%2d)${C_RESET} ${C_BOLD}%-20s${C_RESET} ${C_CYAN}%*s@%-25s${C_RESET} %s\n" "$i" "$name" "$max_user_len" "$user" "$host" "$port"
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
        echo "  ${C_RED}Name cannot be empty.${C_RESET}"
    done

    while true; do
        read -rp "  User [${default_user}]: " _user
        _user="${_user:-$default_user}"
        [[ -n "$_user" ]] && break
        echo "  ${C_RED}User cannot be empty.${C_RESET}"
    done

    while true; do
        read -rp "  Host [${default_host}]: " _host
        _host="${_host:-$default_host}"
        [[ -n "$_host" ]] && break
        echo "  ${C_RED}Host cannot be empty.${C_RESET}"
    done

    while true; do
        read -rp "  Port [${default_port}]: " _port
        _port="${_port:-$default_port}"
        if _validate_port "$_port"; then
            break
        fi
        echo "  ${C_RED}Port must be a number between 1 and 65535.${C_RESET}"
    done
}

_check_install_status() {
    # Prints one of: "not_installed", "installed_current", "installed_outdated"
    local installed_path
    installed_path=$(command -v ssh-menu 2>/dev/null || true)
    if [[ -z "$installed_path" ]]; then
        echo "not_installed"
        return
    fi
    local installed_version
    installed_version=$(grep -m1 '^VERSION=' "$installed_path" 2>/dev/null | cut -d'"' -f2 || true)
    if [[ "$installed_version" == "$VERSION" ]]; then
        echo "installed_current"
    else
        echo "installed_outdated"
    fi
}

_select_server() {
    local prompt="${1:-Select a server}"
    local total
    total=$(_server_count)
    if [[ "$total" -eq 0 ]]; then
        echo "  ${C_YELLOW}No servers saved yet.${C_RESET}"
        return 1
    fi
    # Use arrow-key navigation when stdin is an interactive terminal
    if [[ -t 0 ]]; then
        _select_server_interactive "$prompt"
        return $?
    fi
    # Fallback: number-based selection for piped/scripted input
    _list_servers
    while true; do
        read -rp "  $prompt (1-${total}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$total" ]]; then
            _selected_line=$(_get_server_by_index "$choice")
            _selected_index="$choice"
            return 0
        fi
        echo "  ${C_RED}Invalid selection. Enter a number between 1 and ${total}.${C_RESET}"
    done
}

_select_server_interactive() {
    local prompt="${1:-Select a server}"
    local -a lines=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        lines+=("$line")
    done < "$CONFIG_FILE"
    local total=${#lines[@]}
    local current=0

    # Find max username length for column alignment (mirrors _list_servers)
    local max_user_len=0
    local line
    for line in "${lines[@]}"; do
        local user; user=$(_get_field "$line" 2)
        [[ ${#user} -gt $max_user_len ]] && max_user_len=${#user}
    done

    _draw_interactive_list() {
        local i
        for ((i=0; i<total; i++)); do
            printf "\033[2K"  # clear line before redrawing
            local entry="${lines[$i]}"
            local name user host port
            name=$(_get_field "$entry" 1); user=$(_get_field "$entry" 2)
            host=$(_get_field "$entry" 3); port=$(_get_field "$entry" 4)
            if [[ $i -eq $current ]]; then
                printf "  ${C_GREEN}${C_BOLD}▶ %-20s${C_RESET}  ${C_CYAN}%*s@%-25s${C_RESET}  %s\n" \
                    "$name" "$max_user_len" "$user" "$host" "$port"
            else
                printf "    ${C_BOLD}%-20s${C_RESET}  ${C_CYAN}%*s@%-25s${C_RESET}  %s\n" \
                    "$name" "$max_user_len" "$user" "$host" "$port"
            fi
        done
        printf "\033[2K  ${C_YELLOW}↑/↓ navigate · Enter select · q cancel${C_RESET}\n"
    }

    tput civis 2>/dev/null || true  # hide cursor while navigating
    _draw_interactive_list

    while true; do
        local key; key=$(_read_key)
        # Return cursor to the top of the drawn list for redrawing
        printf "\033[%dA" $((total + 1))
        case "$key" in
            up)   current=$(( (current - 1 + total) % total )) ;;
            down) current=$(( (current + 1) % total )) ;;
            enter)
                tput cnorm 2>/dev/null || true
                printf "\033[%dB\n" $((total + 1))  # advance past drawn area
                _selected_line="${lines[$current]}"
                _selected_index=$(( current + 1 ))
                return 0
                ;;
            q|Q)
                tput cnorm 2>/dev/null || true
                printf "\033[%dB\n" $((total + 1))
                return 1
                ;;
        esac
        _draw_interactive_list
    done
}

# ---------------------------------------------------------------------------
# SSH connect helper
# ---------------------------------------------------------------------------

_connect_ssh() {
    local name="$1" user="$2" host="$3" port="$4"
    # Set an initial title with connection info right away.
    _set_title "ssh: ${name} | ${user}@${host}:${port}"
    # Remote snippet: update the title with live server stats, then exec the
    # user's login shell.  Uses only POSIX tools; silently omits fields that
    # are unavailable (e.g. no /proc on macOS).
    local _rc
    _rc='h=$(hostname -f 2>/dev/null||hostname);'
    _rc+='l=$(cat /proc/loadavg 2>/dev/null|cut -d" " -f1-3);'
    _rc+='m=$(free -m 2>/dev/null|awk "/^Mem:/{printf \"%d/%dMB\",\$3,\$2}");'
    _rc+='printf "\033]0;%s%s%s\007" "$h" "${l:+ | load: $l}" "${m:+ | mem: $m}";'
    _rc+='exec "${SHELL:-bash}" -l'
    ssh -p "$port" -t "${user}@${host}" "$_rc"
    # Restore a sensible title after the session ends.
    _set_title "ssh-menu"
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

cmd_add() {
    echo ""
    echo "${C_BOLD}--- Add Server ---${C_RESET}"
    local _name _user _host _port
    _prompt_server_fields
    echo "${_name}:${_user}:${_host}:${_port}" >> "$CONFIG_FILE"
    echo "  ${C_GREEN}Saved '${_name}'.${C_RESET}"
}

cmd_connect() {
    echo ""
    echo "${C_BOLD}--- Connect to Server ---${C_RESET}"
    local _selected_line _selected_index
    _select_server "Connect to server" || return 0
    local name user host port
    name=$(_get_field "$_selected_line" 1)
    user=$(_get_field "$_selected_line" 2)
    host=$(_get_field "$_selected_line" 3)
    port=$(_get_field "$_selected_line" 4)
    echo "  Connecting to ${C_BOLD}${name}${C_RESET} (${C_CYAN}${user}@${host}:${port}${C_RESET})..."
    _connect_ssh "$name" "$user" "$host" "$port"
}

cmd_edit() {
    echo ""
    echo "${C_BOLD}--- Edit Server ---${C_RESET}"
    local _selected_line _selected_index
    _select_server "Edit server" || return 0
    local name user host port
    name=$(_get_field "$_selected_line" 1)
    user=$(_get_field "$_selected_line" 2)
    host=$(_get_field "$_selected_line" 3)
    port=$(_get_field "$_selected_line" 4)
    echo "  Editing '${C_BOLD}${name}${C_RESET}' (press Enter to keep current value):"
    local _name _user _host _port
    _prompt_server_fields "$name" "$user" "$host" "$port"
    # Replace line in config file
    local tmp_file
    tmp_file=$(mktemp)
    awk -v idx="$_selected_index" -v new="${_name}:${_user}:${_host}:${_port}" \
        'NR==idx {print new; next} {print}' "$CONFIG_FILE" > "$tmp_file"
    mv "$tmp_file" "$CONFIG_FILE"
    echo "  ${C_GREEN}Updated '${_name}'.${C_RESET}"
}

cmd_delete() {
    echo ""
    echo "${C_BOLD}--- Delete Server ---${C_RESET}"
    local _selected_line _selected_index
    _select_server "Delete server" || return 0
    local name
    name=$(_get_field "$_selected_line" 1)
    read -rp "  Delete '${C_BOLD}${name}${C_RESET}'? [y/N]: " confirm
    if [[ "${confirm,,}" == "y" ]]; then
        local tmp_file
        tmp_file=$(mktemp)
        awk -v idx="$_selected_index" 'NR!=idx' "$CONFIG_FILE" > "$tmp_file"
        mv "$tmp_file" "$CONFIG_FILE"
        echo "  ${C_GREEN}Deleted '${name}'.${C_RESET}"
    else
        echo "  ${C_YELLOW}Cancelled.${C_RESET}"
    fi
}

# ---------------------------------------------------------------------------
# Install / update
# ---------------------------------------------------------------------------

cmd_install() {
    local script_path
    script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    local target="$INSTALL_TARGET"

    echo ""
    echo "${C_BOLD}--- Install ssh-menu ---${C_RESET}"

    if [[ "$script_path" == "$target" ]]; then
        echo "  ${C_YELLOW}ssh-menu is already installed at '${target}'.${C_RESET}"
        echo "  ${C_YELLOW}To update, run the new version of ssh-menu.sh with the install command.${C_RESET}"
        return 0
    fi

    local install_dir
    install_dir=$(dirname "$target")
    if [[ ! -d "$install_dir" ]]; then
        echo "  ${C_RED}Install directory '${install_dir}' does not exist.${C_RESET}"
        return 1
    fi

    if [[ ! -w "$install_dir" ]]; then
        echo "  ${C_RED}No write permission to '${install_dir}'. Try running with sudo.${C_RESET}"
        return 1
    fi

    if [[ -f "$target" ]]; then
        echo "  Updating ssh-menu at '${C_BOLD}${target}${C_RESET}'..."
    else
        echo "  Installing ssh-menu to '${C_BOLD}${target}${C_RESET}'..."
    fi

    cp -f "$script_path" "$target"
    chmod +x "$target"
    echo "  ${C_GREEN}Done! You can now run 'ssh-menu' from anywhere.${C_RESET}"
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------

main_menu() {
    local menu_cursor=0

    while true; do
        if [[ -t 1 ]]; then tput clear 2>/dev/null || true; fi
        echo ""
        echo "${C_CYAN}${C_BOLD}==============================${C_RESET}"
        echo "${C_CYAN}${C_BOLD}     SSH Menu  v${VERSION}${C_RESET}"
        echo "${C_CYAN}${C_BOLD}==============================${C_RESET}"

        local install_status
        install_status=$(_check_install_status)
        case "$install_status" in
            installed_current)
                echo "  ${C_GREEN}● Installed in system path (up to date)${C_RESET}"
                ;;
            installed_outdated)
                echo "  ${C_YELLOW}● Installed in system path (update available: v${VERSION})${C_RESET}"
                ;;
            not_installed)
                echo "  ${C_RED}● Not installed in system path${C_RESET}"
                ;;
        esac

        _list_servers
        echo ""

        # Build the active set of menu items
        local -a _menu_keys=() _menu_labels=()
        _menu_keys+=('a'); _menu_labels+=("Add server")
        _menu_keys+=('c'); _menu_labels+=("Connect to server")
        _menu_keys+=('e'); _menu_labels+=("Edit server")
        _menu_keys+=('d'); _menu_labels+=("Delete server")
        if [[ "$install_status" != "installed_current" ]]; then
            _menu_keys+=('i'); _menu_labels+=("Install/update to system path")
        fi
        _menu_keys+=('q'); _menu_labels+=("Quit")

        local _menu_count=${#_menu_keys[@]}
        # Keep cursor in bounds if the menu shrank (e.g. install option removed)
        [[ $menu_cursor -ge $_menu_count ]] && menu_cursor=$((_menu_count - 1))

        local i
        for ((i=0; i<_menu_count; i++)); do
            local _key="${_menu_keys[$i]}" _label="${_menu_labels[$i]}"
            if [[ -t 0 && $i -eq $menu_cursor ]]; then
                echo "  ${C_GREEN}${C_BOLD}▶ ${_key}) ${_label}${C_RESET}"
            else
                echo "  ${C_YELLOW}${C_BOLD}${_key})${C_RESET} ${_label}"
            fi
        done

        if [[ -t 0 ]]; then
            echo ""
            echo "  ${C_YELLOW}↑/↓ navigate · Enter select · or press a letter${C_RESET}"
        fi
        echo ""

        local choice
        if [[ -t 0 ]]; then
            choice=$(_read_key)
        else
            read -rp "  Choice: " choice
        fi

        case "$choice" in
            up)
                menu_cursor=$(( (menu_cursor - 1 + _menu_count) % _menu_count ))
                continue
                ;;
            down)
                menu_cursor=$(( (menu_cursor + 1) % _menu_count ))
                continue
                ;;
            enter)
                choice="${_menu_keys[$menu_cursor]}"
                ;;
        esac

        case "${choice,,}" in
            a) cmd_add ;;
            c) cmd_connect ;;
            e) cmd_edit ;;
            d) cmd_delete ;;
            i)
                if [[ "$install_status" != "installed_current" ]]; then
                    cmd_install
                else
                    echo "  ${C_RED}Unknown option. Please choose a, c, e, d, or q.${C_RESET}"
                fi
                ;;
            q) echo "Goodbye."; exit 0 ;;
            [0-9]*)
                local total
                total=$(_server_count)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$total" ]]; then
                    local _selected_line
                    _selected_line=$(_get_server_by_index "$choice")
                    local name user host port
                    name=$(_get_field "$_selected_line" 1)
                    user=$(_get_field "$_selected_line" 2)
                    host=$(_get_field "$_selected_line" 3)
                    port=$(_get_field "$_selected_line" 4)
                    echo "  Connecting to ${C_BOLD}${name}${C_RESET} (${C_CYAN}${user}@${host}:${port}${C_RESET})..."
                    _connect_ssh "$name" "$user" "$host" "$port"
                elif [[ "$total" -eq 0 ]]; then
                    echo "  ${C_RED}No servers saved yet.${C_RESET}"
                else
                    echo "  ${C_RED}Invalid selection. Enter a number between 1 and ${total}.${C_RESET}"
                fi
                ;;
            *) echo "  ${C_RED}Unknown option. Please choose a, c, e, d$([ "$install_status" != "installed_current" ] && echo ", i"), or q.${C_RESET}" ;;
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
    install) shift; cmd_install "$@" ;;
    list)    _list_servers ;;
    version) echo "ssh-menu v${VERSION}" ;;
    *)       main_menu ;;
esac
