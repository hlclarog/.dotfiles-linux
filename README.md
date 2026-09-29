<h1 align="center">
  .dotfiles created using <a href="https://github.com/CodelyTV/dotly">🌚 dotly</a>
</h1>

One unattended restore rebuilds the whole environment on WSL or on a Linux
server VM: shell, prompt, atuin, herdr, the agents (Claude Code, Codex,
opencode, Pi) and their integrations. Logins and keys stay manual, guided by
`scripts/post-restore-secrets`. Deep detail lives in
[`doc/INSTALL.md`](doc/INSTALL.md); this page is the checklist.

## Pick your path

| You are setting up | Follow |
|---|---|
| A new Linux server VM (Ubuntu 24.04, e.g. under UTM) | [New Linux server VM](#new-linux-server-vm) |
| A new WSL instance | [New WSL instance](#new-wsl-instance) |
| The Mac that hosts the VM, so it runs 24/7 | [Mac host for the VM](#mac-host-for-the-vm) |
| A machine that is already restored | [Keep a machine current](#keep-a-machine-current) |

---

## New Linux server VM

**1. Bootstrap the fresh system.** Download the standalone script and run it
as your normal user (it asks for sudo once):

```bash
curl -fsSLo bootstrap-linux https://raw.githubusercontent.com/hlclarog/.dotfiles-linux/master/scripts/bootstrap-linux && bash bootstrap-linux
```

It installs the apt prerequisites, grows the root LVM volume to the whole
disk, sets up zram swap, makes the kernel reboot after a panic, starts the
QEMU guest agent, sets the time zone, enables sshd and installs Homebrew. It
never clones the repository. At the end it asks
**"Launch Dotly's restorer now? [y/N]"**: answer **y** and continue with step 2.

| Option | Effect |
|---|---|
| `--check` | Only report each step; exits 1 while something is pending |
| `--skip-brew` | Skip the Homebrew install |
| `--timezone <Zone>` | Time zone to set (default `America/Bogota`) |

**2. Answer the restorer prompts.**

| Prompt | Answer |
|---|---|
| Where do you want your dotfiles to be located? | **Enter** (`~/.dotfiles`) |
| From where you want to install your dotfiles | **GitHub** |
| Which is your github user? | `hlclarog` |
| Which is your github repository? | `.dotfiles-linux` |
| Do you want to setup remote SSH origin url? | **Y** |
| sudo password | your password |
| Do you want to import previous installed packages? | **Y** (installs the apt list) |

If `bootstrap-linux` was skipped or the restorer was declined, run the
restorer by hand. Add `--continue` only when `~/.dotfiles` already exists:

```bash
bash <(curl -s https://raw.githubusercontent.com/CodelyTV/dotly/HEAD/restorer) --continue
```

**3. Log out and back in**, so the login shell (Homebrew's zsh) applies.

**4. Logins and keys:** see [After the restore](#after-the-restore-logins-and-keys).

## New WSL instance

In **Windows PowerShell**:

```powershell
wsl --install -d Ubuntu-24.04 --name gentleman
```

Inside the new instance, run the same `bootstrap-linux` command as for a VM.
On WSL it skips the server-only steps (disk, zram, panic, guest agent, time
zone) and still installs the prerequisites and Homebrew. Then answer the
restorer prompts in the table above, close the terminal, open it again, and
continue with the logins.

> Two WSL instances share one network. On a second, test instance, sshd
> (port 22) and `engram-serve` (port 7438) cannot start while the first
> instance holds those ports. That is expected, not a restore failure.

## After the restore: logins and keys

```bash
~/.dotfiles/scripts/post-restore-secrets              # guided: checks each step, offers to run it
~/.dotfiles/scripts/post-restore-secrets --check      # status table only; exits 1 while something is pending
~/.dotfiles/scripts/post-restore-secrets --menu       # interactive: pick a step, or switch its account
~/.dotfiles/scripts/post-restore-secrets --no-accounts # skip the account probes (faster, no ACCOUNT column)
POST_RESTORE_ONLY=claude ~/.dotfiles/scripts/post-restore-secrets   # one step
```

Every mode shows an ACCOUNT column: which GitHub user, email or account each
step is currently logged in as, so having a personal and a work machine (or
account) never leaves you guessing which one is active. `--menu` adds a
numbered prompt to run a pending step or, for one already configured, offer
to switch its account.

| Step | What you do |
|---|---|
| `gh` | Open the printed URL on any browser and type the one-time code |
| `ssh:<host>` | One row per key in `ssh/config` (e.g. `ssh:github.com`); creates it and uploads the GitHub one with `gh` |
| `pi` | In Pi: `/login` → OpenAI ChatGPT → paste the final redirect URL → `/quit` |
| `claude` | Browser login; then it registers the CodeGraph MCP server |
| `codex` | Device code, like `gh` |
| `opencode` | Log in to the provider you use |
| `engram-cloud` | Optional: server URL and token (the token is never echoed) |
| `tailscale` | Linux servers only: install, `sudo tailscale up`, operator; then disable key expiry in the admin console |
| `zerotier` | Optional fallback to Tailscale; defaults to no |
| `sshd` | Keys-only SSH. Keep a second session open until a new login still works |
| `shell` | Sets the login shell to Homebrew's zsh if it is not yet |
| `moshi` | Optional: pairing commands for the Moshi phone app |

GitHub and Bitbucket only allow one account signed in per machine at a time,
so keep one SSH key per host and label each with its account (`personal`,
`work`) when `--menu` asks for a label -- that label is how the ACCOUNT
column tells your keys apart later. Run a single key with
`POST_RESTORE_ONLY=ssh:bitbucket.org`. `--menu` never logs Tailscale out by
itself: switching tailnets drops every Tailscale connection, including an
SSH session running over one, so that switch has to happen from the
machine's console or a LAN session instead.

For Moshi terminal access from outside the office, register the host with its
Tailscale name, never a LAN IP:

```bash
moshi-hook host setup --host <machine>.<tailnet>.ts.net --user "$(id -un)" --port 22 --name <machine>
```

## Mac host for the VM

On the Mac itself (Monterey or later), once:

```bash
git clone https://github.com/hlclarog/.dotfiles-linux.git ~/.dotfiles
~/.dotfiles/scripts/setup-mac-vm-host --vm sandbox-imac-hclaro-vm           # applies what it can
~/.dotfiles/scripts/setup-mac-vm-host --vm sandbox-imac-hclaro-vm --check   # status only
```

It disables sleep, restarts after a power cut or a freeze, and loads a
LaunchAgent watchdog that starts or resumes the VM every 5 minutes. Then, by
hand: **System Preferences → Users & Groups → Login Options → Automatic
login** (FileVault must be off). Test with `sudo reboot`: about 3 minutes later
`ssh sandbox-imac` should work. `touch ~/.utm-autostart-disabled` pauses the
watchdog; the log is `~/Library/Logs/utm-autostart.log`.

## Keep a machine current

```bash
cd ~/.dotfiles && git pull
dot self install                                     # re-run every restoration script; safe to repeat
~/.dotfiles/scripts/post-restore-secrets --check     # anything left to do by hand
~/.dotfiles/scripts/bootstrap-linux --check          # Linux servers: system-level settings
up                                                   # update every package manager (brew, npm, cargo...)
```

`dot self install` also regenerates the agent assets from
`os/linux/gentle-ai/state.json`, reinstalls stale herdr and Moshi hooks, and
repairs anything the repository changed since the last run.

## Pi model profiles

Switch in Pi with `/gentle:profiles`. A fresh restore installs all eight and
activates `claude-medium`.

| Profile | Use it for |
|---|---|
| `claude-medium`, `codex-medium` | Everyday work |
| `claude-low`, `codex-low` | Saving subscription quota |
| `claude-high`, `codex-high` | The last days before a quota reset: every role at max effort. Switch back afterwards |
| `claude-full`, `current` | Kept as they were; not for daily use |

To add missing profiles to an existing registry (it never changes the active
one and keeps a private backup): `~/.dotfiles/scripts/restore-pi-profiles`.
Add `--replace` only to overwrite a profile that differs from the repository.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `.exe` files fail in WSL with `Exec format error` | Starting another WSL instance can drop the Windows interop registration. Run `wsl --shutdown` from PowerShell and open WSL again |
| Moshi hooks missing | `moshi-hook doctor` (0.4+) lists each agent; `dot self install` reinstalls them |
| zim modules broken after a restore | In zsh: `rm -r "$DOTFILES_PATH/shell/zsh/.zim"`, then `dot self install` |
| The restorer said "restored" but a later script never ran | Check `~/dotly.log`: every script logs an `Executing afterinstall` line |

More: [`doc/INSTALL.md`](doc/INSTALL.md), especially
[Gotchas worth knowing](doc/INSTALL.md#gotchas-worth-knowing) and
[Verify](doc/INSTALL.md#verify).
