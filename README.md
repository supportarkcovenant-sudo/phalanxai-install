# PhalanxAI installer

Claude Code in the browser: start, watch, and manage Claude Code sessions on
one machine from any browser on your network.

Install on a Linux or macOS machine:

```bash
curl -fsSL https://raw.githubusercontent.com/supportarkcovenant-sudo/phalanxai-install/main/install.sh | bash
```

The installer checks Docker (and offers to install it on Linux when it is
missing), asks which folders Claude Code may work in and which port to use,
pulls the PhalanxAI container image, starts it, installs the `phalanx`
command, and prints the address to open.

Unattended:

```bash
curl -fsSL https://raw.githubusercontent.com/supportarkcovenant-sudo/phalanxai-install/main/install.sh \
  | bash -s -- --yes --install-docker --folder /srv/projects --port 8765
```

All options: add `--help` after `bash -s --`.

Afterwards: `phalanx upgrade` moves to the newest image, `phalanx --help`
lists the other commands.

`install.sh` here is published by the PhalanxAI release process; changes made
directly in this repository are overwritten by the next release.
