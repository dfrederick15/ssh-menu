# ssh-menu

An interactive Bash script to **save, connect, edit, and delete** your favourite SSH servers.

## Features

- **List** all saved servers at a glance
- **Connect** to a server with a single keystroke
- **Add** new servers (name, user, host, port)
- **Edit** existing server details
- **Delete** servers you no longer need
- **Version display** — shows the current version in the menu header
- **Install-status indicator** — shows whether `ssh-menu` is installed in the system path and whether it is up to date; hides the install option when already at the current version
- Persistent storage in `~/.config/ssh-menu/servers`

## Requirements

- Bash 4+
- `ssh` available in your `PATH`

## Installation

```bash
# Clone or download the repository, then make the script executable
chmod +x ssh-menu.sh

# Install to the system path (makes 'ssh-menu' available from any directory)
sudo ./ssh-menu.sh install

# To update an existing installation, run the new version with the install command
sudo ./new-ssh-menu.sh install
```

> **Custom install directory:** Set `SSH_MENU_INSTALL_DIR` to override the default `/usr/local/bin`:
> ```bash
> SSH_MENU_INSTALL_DIR=~/.local/bin ./ssh-menu.sh install
> ```

## Usage

### Interactive menu

```bash
./ssh-menu.sh
```

```
==============================
     SSH Menu  v1.0.0
==============================
  ● Installed in system path (up to date)
   1) web-server           alice@web.example.com        22
   2) db-server            root@db.internal             2222

  a) Add server
  c) Connect to server
  e) Edit server
  d) Delete server
  q) Quit

  Choice:
```

When `ssh-menu` is **not yet installed** or an **older version** is installed, an additional option is shown:

```
  i) Install/update to system path
```

### Non-interactive subcommands

| Command | Description |
|---------|-------------|
| `./ssh-menu.sh list` | Print saved servers |
| `./ssh-menu.sh add` | Add a new server (prompts for details) |
| `./ssh-menu.sh connect` | Connect to a saved server |
| `./ssh-menu.sh edit` | Edit a saved server |
| `./ssh-menu.sh delete` | Delete a saved server |
| `./ssh-menu.sh install` | Install or update ssh-menu to the system path |
| `./ssh-menu.sh version` | Print the current version |

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

## Author

Devin Frederick — devin.frederick2012@gmail.com
