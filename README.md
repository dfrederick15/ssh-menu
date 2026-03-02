# ssh-menu

An interactive Bash script to **save, connect, edit, and delete** your favourite SSH servers.

## Features

- **List** all saved servers at a glance
- **Connect** to a server with a single keystroke
- **Add** new servers (name, user, host, port)
- **Edit** existing server details
- **Delete** servers you no longer need
- Persistent storage in `~/.config/ssh-menu/servers`

## Requirements

- Bash 4+
- `ssh` available in your `PATH`

## Installation

```bash
# Clone or download the repository, then make the script executable
chmod +x ssh-menu.sh

# Optionally, add it to your PATH
cp ssh-menu.sh /usr/local/bin/ssh-menu
```

## Usage

### Interactive menu

```bash
./ssh-menu.sh
```

```
==============================
        SSH Menu
==============================
   1) web-server           alice@web.example.com:22
   2) db-server            root@db.internal:2222

  a) Add server
  c) Connect to server
  e) Edit server
  d) Delete server
  q) Quit

  Choice:
```

### Non-interactive subcommands

| Command | Description |
|---------|-------------|
| `./ssh-menu.sh list` | Print saved servers |
| `./ssh-menu.sh add` | Add a new server (prompts for details) |
| `./ssh-menu.sh connect` | Connect to a saved server |
| `./ssh-menu.sh edit` | Edit a saved server |
| `./ssh-menu.sh delete` | Delete a saved server |

### Custom config location

Set `SSH_MENU_CONFIG_DIR` to override the default `~/.config/ssh-menu` directory:

```bash
SSH_MENU_CONFIG_DIR=/path/to/config ./ssh-menu.sh
```

## Config file format

Servers are stored one per line as colon-separated values:

```
name:user:host:port
```

Example:

```
web-server:alice:web.example.com:22
db-server:root:db.internal:2222
```

## Running tests

```bash
bash tests/test_ssh_menu.sh
```
