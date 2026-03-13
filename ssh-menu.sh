#!/usr/bin/env bash
# ssh-menu.sh — Interactive SSH server manager
# Stores servers in $SSH_MENU_CONFIG (default: ~/.config/ssh-menu/servers)
# Config file format (one entry per line): name:user:host:port
#
# Author:  Devin Frederick
# Contact: devin.frederick2012@gmail.com

set -euo pipefail

VERSION="1.5.0"

CONFIG_DIR="${SSH_MENU_CONFIG_DIR:-$HOME/.config/ssh-menu}"
CONFIG_FILE="$CONFIG_DIR/servers"
TUNNELS_FILE="$CONFIG_DIR/tunnels"
PIDS_DIR="$CONFIG_DIR/pids"

INSTALL_DIR="${SSH_MENU_INSTALL_DIR:-/usr/local/bin}"
INSTALL_TARGET="$INSTALL_DIR/ssh-menu"

GITHUB_RAW_URL="https://raw.githubusercontent.com/dfrederick15/ssh-menu/main/ssh-menu.sh"

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
    mkdir -p "$CONFIG_DIR" "$PIDS_DIR"
    touch "$CONFIG_FILE" "$TUNNELS_FILE"
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

_fetch_github_version() {
    # Returns the VERSION string from the GitHub repo, or empty on failure.
    # || true prevents pipefail from propagating when curl/wget fails.
    if command -v curl &>/dev/null; then
        curl -fsSL --max-time 4 "$GITHUB_RAW_URL" 2>/dev/null \
            | grep -m1 '^VERSION=' | cut -d'"' -f2 || true
    elif command -v wget &>/dev/null; then
        wget -qO- --timeout=4 "$GITHUB_RAW_URL" 2>/dev/null \
            | grep -m1 '^VERSION=' | cut -d'"' -f2 || true
    fi
}

_get_github_version_cached() {
    # Caches the GitHub version for 24 hours so startup isn't slow every run.
    local cache_file="$CONFIG_DIR/github-version-cache"
    if [[ -f "$cache_file" ]] && \
       find "$cache_file" -mmin -$((60*24)) -print 2>/dev/null | grep -q .; then
        cat "$cache_file"
        return
    fi
    local version
    version=$(_fetch_github_version)
    if [[ -n "$version" ]]; then
        echo "$version" > "$cache_file"
        echo "$version"
    elif [[ -f "$cache_file" ]]; then
        cat "$cache_file"  # serve stale on network failure
    fi
}

_version_lt() {
    # Returns 0 (true) if $1 is strictly less than $2 by semver ordering.
    [[ "$1" == "$2" ]] && return 1
    [[ "$(printf '%s\n%s' "$1" "$2" | sort -V | head -1)" == "$1" ]]
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
    ssh -p "$port" -t \
        -o ServerAliveInterval=1 \
        -o ServerAliveCountMax=10 \
        "${user}@${host}" "$_rc"
    # Restore a sensible title after the session ends.
    _set_title "ssh-menu"
}

# ---------------------------------------------------------------------------
# Tunnel helpers
# ---------------------------------------------------------------------------

# Tunnel config format (one entry per line):
# name:type:local_port:remote_host:remote_port:user:host:port
# type: L=local forward, R=remote forward, D=dynamic/SOCKS
# remote_host and remote_port are empty for D tunnels.

_tunnel_count() {
    wc -l < "$TUNNELS_FILE" 2>/dev/null || echo 0
}

_get_tunnel_by_index() {
    sed -n "${1}p" "$TUNNELS_FILE"
}

_tunnel_pid_file() {
    echo "$PIDS_DIR/tunnel-${1}.pid"
}

_is_tunnel_running() {
    local pid_file
    pid_file=$(_tunnel_pid_file "$1")
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        else
            rm -f "$pid_file"
        fi
    fi
    return 1
}

_tunnel_desc() {
    # _tunnel_desc type local_port remote_host remote_port
    case "$1" in
        L) printf '%s→%s:%s' "$2" "$3" "$4" ;;
        R) printf '%s←%s:%s' "$4" "$3" "$2" ;;
        D) printf 'SOCKS:%s' "$2" ;;
    esac
}

_list_tunnels() {
    local count
    count=$(_tunnel_count)
    if [[ "$count" -eq 0 ]]; then
        echo "  ${C_YELLOW}(no tunnels saved)${C_RESET}"
        return
    fi

    local i=1
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local name type lport rhost rport user host port
        name=$(_get_field "$line" 1);  type=$(_get_field "$line" 2)
        lport=$(_get_field "$line" 3); rhost=$(_get_field "$line" 4)
        rport=$(_get_field "$line" 5); user=$(_get_field "$line" 6)
        host=$(_get_field "$line" 7);  port=$(_get_field "$line" 8)
        local dot desc
        _is_tunnel_running "$name" && dot="${C_GREEN}●${C_RESET}" || dot="${C_RED}○${C_RESET}"
        desc=$(_tunnel_desc "$type" "$lport" "$rhost" "$rport")
        printf "  ${C_YELLOW}${C_BOLD}%2d)${C_RESET} %b ${C_BOLD}%-20s${C_RESET} ${C_CYAN}%-28s${C_RESET} via %s@%s:%s\n" \
            "$i" "$dot" "$name" "$desc" "$user" "$host" "$port"
        ((i++))
    done < "$TUNNELS_FILE"
}

_validate_tunnel_type() {
    [[ "$1" =~ ^[LRD]$ ]]
}

_prompt_tunnel_fields() {
    # Sets globals: _t_name _t_type _t_lport _t_rhost _t_rport _t_user _t_host _t_port
    local dn="${1:-}" dt="${2:-L}" dlp="${3:-}" drh="${4:-}" drp="${5:-}" \
          du="${6:-}" dh="${7:-}" dpo="${8:-22}"

    while true; do
        read -rp "  Name [${dn}]: " _t_name
        _t_name="${_t_name:-$dn}"
        [[ -n "$_t_name" ]] && break
        echo "  ${C_RED}Name cannot be empty.${C_RESET}"
    done

    echo "  Type: L=local forward  R=remote forward  D=dynamic (SOCKS)"
    while true; do
        read -rp "  Type [${dt}]: " _t_type
        _t_type="${_t_type:-$dt}"
        _t_type="${_t_type^^}"
        _validate_tunnel_type "$_t_type" && break
        echo "  ${C_RED}Type must be L, R, or D.${C_RESET}"
    done

    while true; do
        read -rp "  Local port [${dlp}]: " _t_lport
        _t_lport="${_t_lport:-$dlp}"
        _validate_port "$_t_lport" && break
        echo "  ${C_RED}Port must be a number between 1 and 65535.${C_RESET}"
    done

    if [[ "$_t_type" != "D" ]]; then
        while true; do
            read -rp "  Remote host [${drh}]: " _t_rhost
            _t_rhost="${_t_rhost:-$drh}"
            [[ -n "$_t_rhost" ]] && break
            echo "  ${C_RED}Remote host cannot be empty.${C_RESET}"
        done
        while true; do
            read -rp "  Remote port [${drp}]: " _t_rport
            _t_rport="${_t_rport:-$drp}"
            _validate_port "$_t_rport" && break
            echo "  ${C_RED}Port must be a number between 1 and 65535.${C_RESET}"
        done
    else
        _t_rhost=""
        _t_rport=""
    fi

    echo "  --- SSH server to tunnel through ---"
    while true; do
        read -rp "  User [${du}]: " _t_user
        _t_user="${_t_user:-$du}"
        [[ -n "$_t_user" ]] && break
        echo "  ${C_RED}User cannot be empty.${C_RESET}"
    done
    while true; do
        read -rp "  Host [${dh}]: " _t_host
        _t_host="${_t_host:-$dh}"
        [[ -n "$_t_host" ]] && break
        echo "  ${C_RED}Host cannot be empty.${C_RESET}"
    done
    while true; do
        read -rp "  SSH port [${dpo}]: " _t_port
        _t_port="${_t_port:-$dpo}"
        _validate_port "$_t_port" && break
        echo "  ${C_RED}Port must be a number between 1 and 65535.${C_RESET}"
    done
}

_select_tunnel() {
    local prompt="${1:-Select a tunnel}"
    local total
    total=$(_tunnel_count)
    if [[ "$total" -eq 0 ]]; then
        echo "  ${C_YELLOW}No tunnels saved yet.${C_RESET}"
        return 1
    fi
    if [[ -t 0 ]]; then
        _select_tunnel_interactive "$prompt"
        return $?
    fi
    _list_tunnels
    while true; do
        read -rp "  $prompt (1-${total}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$total" ]]; then
            _selected_tunnel_line=$(_get_tunnel_by_index "$choice")
            _selected_tunnel_index="$choice"
            return 0
        fi
        echo "  ${C_RED}Invalid selection. Enter a number between 1 and ${total}.${C_RESET}"
    done
}

_select_tunnel_interactive() {
    local prompt="${1:-Select a tunnel}"
    local -a lines=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        lines+=("$line")
    done < "$TUNNELS_FILE"
    local total=${#lines[@]}
    local current=0

    _draw_tunnel_list() {
        local i
        for ((i=0; i<total; i++)); do
            printf "\033[2K"
            local entry="${lines[$i]}"
            local name type lport rhost rport user host port dot desc
            name=$(_get_field "$entry" 1);  type=$(_get_field "$entry" 2)
            lport=$(_get_field "$entry" 3); rhost=$(_get_field "$entry" 4)
            rport=$(_get_field "$entry" 5); user=$(_get_field "$entry" 6)
            host=$(_get_field "$entry" 7);  port=$(_get_field "$entry" 8)
            _is_tunnel_running "$name" && dot="${C_GREEN}●${C_RESET}" || dot="${C_RED}○${C_RESET}"
            desc=$(_tunnel_desc "$type" "$lport" "$rhost" "$rport")
            if [[ $i -eq $current ]]; then
                printf "  ${C_GREEN}${C_BOLD}▶ %-20s${C_RESET}  %b  ${C_CYAN}%-28s${C_RESET}  via %s@%s:%s\n" \
                    "$name" "$dot" "$desc" "$user" "$host" "$port"
            else
                printf "    ${C_BOLD}%-20s${C_RESET}  %b  ${C_CYAN}%-28s${C_RESET}  via %s@%s:%s\n" \
                    "$name" "$dot" "$desc" "$user" "$host" "$port"
            fi
        done
        printf "\033[2K  ${C_YELLOW}↑/↓ navigate · Enter select · q cancel${C_RESET}\n"
    }

    tput civis 2>/dev/null || true
    _draw_tunnel_list

    while true; do
        local key; key=$(_read_key)
        printf "\033[%dA" $((total + 1))
        case "$key" in
            up)    current=$(( (current - 1 + total) % total )) ;;
            down)  current=$(( (current + 1) % total )) ;;
            enter)
                tput cnorm 2>/dev/null || true
                printf "\033[%dB\n" $((total + 1))
                _selected_tunnel_line="${lines[$current]}"
                _selected_tunnel_index=$(( current + 1 ))
                return 0
                ;;
            q|Q)
                tput cnorm 2>/dev/null || true
                printf "\033[%dB\n" $((total + 1))
                return 1
                ;;
        esac
        _draw_tunnel_list
    done
}

# ---------------------------------------------------------------------------
# Tunnel actions
# ---------------------------------------------------------------------------

cmd_tunnel_add() {
    echo ""
    echo "${C_BOLD}--- Add Tunnel ---${C_RESET}"
    local _t_name _t_type _t_lport _t_rhost _t_rport _t_user _t_host _t_port
    _prompt_tunnel_fields
    echo "${_t_name}:${_t_type}:${_t_lport}:${_t_rhost}:${_t_rport}:${_t_user}:${_t_host}:${_t_port}" >> "$TUNNELS_FILE"
    echo "  ${C_GREEN}Saved tunnel '${_t_name}'.${C_RESET}"
}

cmd_tunnel_start() {
    echo ""
    echo "${C_BOLD}--- Start Tunnel ---${C_RESET}"
    local _selected_tunnel_line _selected_tunnel_index
    _select_tunnel "Start tunnel" || return 0

    local name type lport rhost rport user host port
    name=$(_get_field "$_selected_tunnel_line" 1);  type=$(_get_field "$_selected_tunnel_line" 2)
    lport=$(_get_field "$_selected_tunnel_line" 3); rhost=$(_get_field "$_selected_tunnel_line" 4)
    rport=$(_get_field "$_selected_tunnel_line" 5); user=$(_get_field "$_selected_tunnel_line" 6)
    host=$(_get_field "$_selected_tunnel_line" 7);  port=$(_get_field "$_selected_tunnel_line" 8)

    if _is_tunnel_running "$name"; then
        echo "  ${C_YELLOW}Tunnel '${name}' is already running.${C_RESET}"
        return 0
    fi

    local pid_file
    pid_file=$(_tunnel_pid_file "$name")

    local -a ssh_args=(-N -p "$port")
    case "$type" in
        L) ssh_args+=(-L "${lport}:${rhost}:${rport}") ;;
        R) ssh_args+=(-R "${rport}:${rhost}:${lport}") ;;
        D) ssh_args+=(-D "$lport") ;;
    esac
    ssh_args+=("${user}@${host}")

    local desc
    desc=$(_tunnel_desc "$type" "$lport" "$rhost" "$rport")
    echo "  Starting tunnel '${C_BOLD}${name}${C_RESET}' (${C_CYAN}${desc}${C_RESET}) in background..."
    ssh "${ssh_args[@]}" &
    local pid=$!
    disown "$pid"
    echo "$pid" > "$pid_file"
    echo "  ${C_GREEN}Tunnel started (PID: ${pid}).${C_RESET}"
}

cmd_tunnel_stop() {
    echo ""
    echo "${C_BOLD}--- Stop Tunnel ---${C_RESET}"
    local _selected_tunnel_line _selected_tunnel_index
    _select_tunnel "Stop tunnel" || return 0

    local name
    name=$(_get_field "$_selected_tunnel_line" 1)
    local pid_file
    pid_file=$(_tunnel_pid_file "$name")

    if [[ ! -f "$pid_file" ]]; then
        echo "  ${C_YELLOW}Tunnel '${name}' does not appear to be running.${C_RESET}"
        return 0
    fi

    local pid
    pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"
        rm -f "$pid_file"
        echo "  ${C_GREEN}Tunnel '${name}' stopped.${C_RESET}"
    else
        rm -f "$pid_file"
        echo "  ${C_YELLOW}Tunnel '${name}' was not running (stale PID removed).${C_RESET}"
    fi
}

cmd_tunnel_edit() {
    echo ""
    echo "${C_BOLD}--- Edit Tunnel ---${C_RESET}"
    local _selected_tunnel_line _selected_tunnel_index
    _select_tunnel "Edit tunnel" || return 0

    local name type lport rhost rport user host port
    name=$(_get_field "$_selected_tunnel_line" 1);  type=$(_get_field "$_selected_tunnel_line" 2)
    lport=$(_get_field "$_selected_tunnel_line" 3); rhost=$(_get_field "$_selected_tunnel_line" 4)
    rport=$(_get_field "$_selected_tunnel_line" 5); user=$(_get_field "$_selected_tunnel_line" 6)
    host=$(_get_field "$_selected_tunnel_line" 7);  port=$(_get_field "$_selected_tunnel_line" 8)

    if _is_tunnel_running "$name"; then
        echo "  ${C_YELLOW}Stop tunnel '${name}' before editing.${C_RESET}"
        return 0
    fi

    echo "  Editing '${C_BOLD}${name}${C_RESET}' (press Enter to keep current value):"
    local _t_name _t_type _t_lport _t_rhost _t_rport _t_user _t_host _t_port
    _prompt_tunnel_fields "$name" "$type" "$lport" "$rhost" "$rport" "$user" "$host" "$port"
    local tmp_file
    tmp_file=$(mktemp)
    awk -v idx="$_selected_tunnel_index" \
        -v new="${_t_name}:${_t_type}:${_t_lport}:${_t_rhost}:${_t_rport}:${_t_user}:${_t_host}:${_t_port}" \
        'NR==idx {print new; next} {print}' "$TUNNELS_FILE" > "$tmp_file"
    mv "$tmp_file" "$TUNNELS_FILE"
    echo "  ${C_GREEN}Updated tunnel '${_t_name}'.${C_RESET}"
}

cmd_tunnel_delete() {
    echo ""
    echo "${C_BOLD}--- Delete Tunnel ---${C_RESET}"
    local _selected_tunnel_line _selected_tunnel_index
    _select_tunnel "Delete tunnel" || return 0

    local name
    name=$(_get_field "$_selected_tunnel_line" 1)

    if _is_tunnel_running "$name"; then
        echo "  ${C_YELLOW}Stop tunnel '${name}' before deleting.${C_RESET}"
        return 0
    fi

    read -rp "  Delete tunnel '${C_BOLD}${name}${C_RESET}'? [y/N]: " confirm
    if [[ "${confirm,,}" == "y" ]]; then
        local tmp_file
        tmp_file=$(mktemp)
        awk -v idx="$_selected_tunnel_index" 'NR!=idx' "$TUNNELS_FILE" > "$tmp_file"
        mv "$tmp_file" "$TUNNELS_FILE"
        echo "  ${C_GREEN}Deleted tunnel '${name}'.${C_RESET}"
    else
        echo "  ${C_YELLOW}Cancelled.${C_RESET}"
    fi
}

cmd_tunnels() {
    local tunnel_cursor=0 full_redraw=1

    local -a _tk=('a' 's' 'x' 'e' 'd' 'b')
    local -a _tl=("Add tunnel" "Start tunnel" "Stop tunnel" \
                  "Edit tunnel" "Delete tunnel" "Back to main menu")
    local _tc=${#_tk[@]}

    _draw_tunnel_items() {
        local i
        for ((i=0; i<_tc; i++)); do
            printf "\033[2K"
            if [[ -t 0 && $i -eq $tunnel_cursor ]]; then
                printf "  ${C_GREEN}${C_BOLD}▶ %s) %s${C_RESET}\n" "${_tk[$i]}" "${_tl[$i]}"
            else
                printf "  ${C_YELLOW}${C_BOLD}%s)${C_RESET} %s\n" "${_tk[$i]}" "${_tl[$i]}"
            fi
        done
        if [[ -t 0 ]]; then
            printf "\033[2K\n"
            printf "\033[2K  ${C_YELLOW}↑/↓ navigate · Enter select · or press a letter${C_RESET}\n"
        fi
        printf "\033[2K\n"
    }

    while true; do
        if [[ "$full_redraw" -eq 1 ]]; then
            if [[ -t 1 ]]; then tput clear 2>/dev/null || true; fi
            echo ""
            echo "${C_CYAN}${C_BOLD}==============================${C_RESET}"
            echo "${C_CYAN}${C_BOLD}         SSH Tunnels${C_RESET}"
            echo "${C_CYAN}${C_BOLD}==============================${C_RESET}"
            _list_tunnels
            echo ""
            full_redraw=0
        else
            printf "\033[%dA" $(( _tc + 3 ))
        fi
        _draw_tunnel_items

        local choice
        if [[ -t 0 ]]; then
            choice=$(_read_key)
        else
            read -rp "  Choice: " choice
        fi

        case "$choice" in
            up)    tunnel_cursor=$(( (tunnel_cursor - 1 + _tc) % _tc )); continue ;;
            down)  tunnel_cursor=$(( (tunnel_cursor + 1) % _tc )); continue ;;
            enter) choice="${_tk[$tunnel_cursor]}" ;;
        esac

        full_redraw=1
        case "${choice,,}" in
            a) cmd_tunnel_add ;;
            s) cmd_tunnel_start ;;
            x) cmd_tunnel_stop ;;
            e) cmd_tunnel_edit ;;
            d) cmd_tunnel_delete ;;
            b) return 0 ;;
            *) echo "  ${C_RED}Unknown option.${C_RESET}" ;;
        esac
    done
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

cmd_update() {
    local script_path
    script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

    echo ""
    echo "${C_BOLD}--- Download Update from GitHub ---${C_RESET}"

    if [[ ! -w "$script_path" ]]; then
        echo "  ${C_RED}No write permission to '${script_path}'. Try running with sudo.${C_RESET}"
        return 1
    fi

    echo "  Downloading latest version..."
    local tmp_file ok=0
    tmp_file=$(mktemp)
    if command -v curl &>/dev/null; then
        curl -fsSL --max-time 30 "$GITHUB_RAW_URL" -o "$tmp_file" 2>/dev/null && ok=1
    elif command -v wget &>/dev/null; then
        wget -qO "$tmp_file" --timeout=30 "$GITHUB_RAW_URL" 2>/dev/null && ok=1
    else
        echo "  ${C_RED}Neither curl nor wget found.${C_RESET}"
        rm -f "$tmp_file"; return 1
    fi

    if [[ "$ok" -eq 0 ]]; then
        rm -f "$tmp_file"
        echo "  ${C_RED}Download failed.${C_RESET}"
        return 1
    fi

    if ! grep -q '^#!/' "$tmp_file" 2>/dev/null; then
        rm -f "$tmp_file"
        echo "  ${C_RED}Downloaded file does not look valid.${C_RESET}"
        return 1
    fi

    cp "$tmp_file" "$script_path"
    chmod +x "$script_path"
    rm -f "$tmp_file"
    rm -f "$CONFIG_DIR/github-version-cache"

    local new_version
    new_version=$(grep -m1 '^VERSION=' "$script_path" | cut -d'"' -f2)
    echo "  ${C_GREEN}Updated to v${new_version}. Restarting...${C_RESET}"
    exec "$script_path"
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------

main_menu() {
    local menu_cursor=0 full_redraw=1
    local install_status github_version
    install_status=$(_check_install_status)
    github_version=$(_get_github_version_cached)

    _build_main_menu() {
        _menu_keys=(); _menu_labels=()
        _menu_keys+=('a'); _menu_labels+=("Add server")
        _menu_keys+=('c'); _menu_labels+=("Connect to server")
        _menu_keys+=('e'); _menu_labels+=("Edit server")
        _menu_keys+=('d'); _menu_labels+=("Delete server")
        _menu_keys+=('t'); _menu_labels+=("Tunnels")
        if [[ -n "$github_version" ]] && _version_lt "$VERSION" "$github_version"; then
            _menu_keys+=('u'); _menu_labels+=("Download update (v${github_version})")
        fi
        if [[ "$install_status" != "installed_current" ]]; then
            _menu_keys+=('i'); _menu_labels+=("Install/update to system path")
        fi
        _menu_keys+=('q'); _menu_labels+=("Quit")
    }

    _draw_main_menu_items() {
        local i
        for ((i=0; i<_menu_count; i++)); do
            printf "\033[2K"
            if [[ -t 0 && $i -eq $menu_cursor ]]; then
                printf "  ${C_GREEN}${C_BOLD}▶ %s) %s${C_RESET}\n" "${_menu_keys[$i]}" "${_menu_labels[$i]}"
            else
                printf "  ${C_YELLOW}${C_BOLD}%s)${C_RESET} %s\n" "${_menu_keys[$i]}" "${_menu_labels[$i]}"
            fi
        done
        if [[ -t 0 ]]; then
            printf "\033[2K\n"
            printf "\033[2K  ${C_YELLOW}↑/↓ navigate · Enter select · or press a letter${C_RESET}\n"
        fi
        printf "\033[2K\n"
        # Install status at the bottom — only shown when installed
        case "$install_status" in
            installed_current)
                printf "\033[2K  ${C_GREEN}● Installed in system path (up to date)${C_RESET}\n" ;;
            installed_outdated)
                printf "\033[2K  ${C_YELLOW}● Installed in system path (outdated)${C_RESET}\n" ;;
            *)
                printf "\033[2K\n" ;;
        esac
    }

    local -a _menu_keys=() _menu_labels=()
    local _menu_count=0

    while true; do
        _build_main_menu
        _menu_count=${#_menu_keys[@]}
        [[ $menu_cursor -ge $_menu_count ]] && menu_cursor=$((_menu_count - 1))

        if [[ "$full_redraw" -eq 1 ]]; then
            if [[ -t 1 ]]; then tput clear 2>/dev/null || true; fi
            echo ""
            echo "${C_CYAN}${C_BOLD}==============================${C_RESET}"
            echo "${C_CYAN}${C_BOLD}     SSH Menu  v${VERSION}${C_RESET}"
            echo "${C_CYAN}${C_BOLD}==============================${C_RESET}"
            if [[ -n "$github_version" ]] && _version_lt "$VERSION" "$github_version"; then
                echo "  ${C_YELLOW}${C_BOLD}↑ GitHub update available: v${github_version}${C_RESET}"
            fi
            _list_servers
            echo ""
            full_redraw=0
        else
            # Navigation only: move cursor up over menu items + footer and redraw
            printf "\033[%dA" $(( _menu_count + 4 ))
        fi
        _draw_main_menu_items

        local choice
        if [[ -t 0 ]]; then
            choice=$(_read_key)
        else
            read -rp "  Choice: " choice
        fi

        case "$choice" in
            up)    menu_cursor=$(( (menu_cursor - 1 + _menu_count) % _menu_count )); continue ;;
            down)  menu_cursor=$(( (menu_cursor + 1) % _menu_count )); continue ;;
            enter) choice="${_menu_keys[$menu_cursor]}" ;;
        esac

        full_redraw=1
        case "${choice,,}" in
            a) cmd_add ;;
            c) cmd_connect ;;
            e) cmd_edit ;;
            d) cmd_delete ;;
            t) cmd_tunnels ;;
            u) cmd_update ;;
            i)
                if [[ "$install_status" != "installed_current" ]]; then
                    cmd_install
                    install_status=$(_check_install_status)
                else
                    echo "  ${C_RED}Unknown option.${C_RESET}"
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
            *) echo "  ${C_RED}Unknown option.${C_RESET}" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

_ensure_config

# Allow non-interactive invocation for scripting/testing
case "${1:-}" in
    add)            shift; cmd_add "$@" ;;
    connect)        shift; cmd_connect "$@" ;;
    edit)           shift; cmd_edit "$@" ;;
    delete)         shift; cmd_delete "$@" ;;
    install)        shift; cmd_install "$@" ;;
    list)           _list_servers ;;
    tunnels)        shift; cmd_tunnels "$@" ;;
    update)         shift; cmd_update "$@" ;;
    tunnel-add)     shift; cmd_tunnel_add "$@" ;;
    tunnel-start)   shift; cmd_tunnel_start "$@" ;;
    tunnel-stop)    shift; cmd_tunnel_stop "$@" ;;
    tunnel-delete)  shift; cmd_tunnel_delete "$@" ;;
    version)        echo "ssh-menu v${VERSION}" ;;
    *)              main_menu ;;
esac
