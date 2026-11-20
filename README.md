# PhalanxAI

Claude Code in the browser: start, watch, and manage Claude Code sessions on
one machine from any browser on your network. PhalanxAI runs as a single
Docker container on a Linux or macOS machine.

- [Install](#install)
- [Sign in from the terminal](#sign-in-from-the-terminal)
- [Run the terminal app](#run-the-terminal-app)
- [Everyday commands](#everyday-commands)
- [Upgrade and uninstall](#upgrade-and-uninstall)
- [Running behind nginx](NGINX.md): how PhalanxAI listens, the proxy
  settings it needs, and what to exempt

## Install

On the machine that will run PhalanxAI:

```bash
curl -fsSL https://raw.githubusercontent.com/supportarkcovenant-sudo/phalanxai-install/main/install.sh | bash
```

The installer asks a few questions and then does the rest:

1. **Docker.** If Docker is missing on Linux, it offers to install it with
   Docker's own script. On macOS, install Docker Desktop first.
2. **Host access** (Linux only). *Full* lets Claude Code sessions run any
   command on the machine and see every file. *Restricted* limits them to
   the folders you choose, plus Docker.
3. **Project folders.** The folders Claude Code may work in. Type a path
   (Tab completes it) and press Enter; leave it empty when you are done.
4. **Network.** The port for the web page (8765 by default) and whether
   other machines on your network may reach it. If they may, it offers
   HTTPS with a certificate it makes itself.

It then pulls the PhalanxAI image, starts it, installs the `phalanx`
command, and prints two things to keep:

- the **address** to open in a browser, and
- a **setup token**, asked once when you set the web password.

If Docker was just installed and the installer stops saying this shell
cannot use it yet, log out, log back in, and run the same command again.

### Without questions

Options go after `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/supportarkcovenant-sudo/phalanxai-install/main/install.sh \
  | bash -s -- --yes --install-docker --folder /srv/projects --port 8765
```

| Option | Meaning |
|---|---|
| `--yes` | Ask nothing; use the options given and the defaults |
| `--install-docker` | Install Docker if it is missing (Linux) |
| `--folder DIR` | A folder Claude Code may work in; repeat for more |
| `--port N` | Port for the web page (default 8765) |
| `--bind ADDRESS` | `0.0.0.0` for the whole network, `127.0.0.1` for this machine only |
| `--host-access full\|restricted` | How much of the machine sessions can reach |
| `--tls off\|self-signed` | Plain HTTP, or HTTPS with a self-made certificate |
| `--no-start` | Install without starting |

`--help` lists every option.

## Sign in from the terminal

There are two separate sign-ins.

**Claude Code** (your Anthropic account). This is Claude Code's own
sign-in, run in your terminal:

```bash
phalanx login
```

Claude Code's sign-in runs in the terminal and shows a link. Open the link
in any browser, approve, and paste the code back if it asks for one. You
are returned to your shell when it finishes (`Ctrl+]` steps out early).
The installer offers to run this for you at the end of the install.

```bash
phalanx login --status   # is Claude Code signed in?
phalanx logout           # sign Claude Code out
```

**The web page** (a password you choose). Open the address the installer
printed, enter the setup token, and set a password. To see them again:

```bash
phalanx url           # addresses to open in a browser
phalanx setup-token   # the one-time token for setting the password
phalanx reset-password   # set a new password; signs every browser out
```

## Run the terminal app

Everything the web page does is also available over SSH, in a full-screen
terminal app:

```bash
phalanx
```

| Key | What it does |
|---|---|
| `F1` | Phalanx: the command pane, with the project tree and agents beside it |
| `F2` | Projects |
| `F3` | Integrations |
| `F4` | Status and sessions |
| `Ctrl+R` | Refresh |
| `Ctrl+Q` | Quit |

The command pane takes the commands below without the `phalanx` prefix
(`projects`, `project use my-app`, `claude`, ...). Type `help` for the
list.

`claude` hands the whole terminal to Claude Code. `Ctrl+]` steps back out
to the app, and the session keeps running. Pressing Enter on an agent in
the project tree opens Claude Code as that agent.

A typical first run:

```bash
phalanx login                          # once
phalanx project add /srv/projects/my-app
phalanx                                # open the terminal app
```

then type `claude` in the command pane.

## Everyday commands

Each of these also works straight from the shell, without opening the
terminal app:

```bash
phalanx claude                 # Claude Code in the current project; Ctrl+] steps out, session keeps running
phalanx project add DIR        # register a project in one of your folders
phalanx sessions               # every session, including ones started in the browser
phalanx attach ID              # rejoin a running session
phalanx status                 # version, Claude Code sign-in, addresses
phalanx logs -f                # PhalanxAI's own logs
phalanx mounts add DIR         # let PhalanxAI see another folder (restarts it)
phalanx up | down | restart    # start, stop, restart
phalanx --help                 # everything else
```

## Upgrade and uninstall

```bash
phalanx upgrade   # pull the newest image and restart on it
```

Running the install command again also upgrades, and refreshes the
`phalanx` command itself; it keeps your earlier answers as the defaults.

To remove PhalanxAI:

```bash
phalanx down
docker volume rm phalanxai04_phalanx-data   # deletes sign-ins, password, and session history
sudo rm -rf /opt/phalanxai /usr/local/bin/phalanx /etc/bash_completion.d/phalanx
```

---

`install.sh` in this repository is published by the PhalanxAI release
process; changes made to it here are overwritten by the next release.
