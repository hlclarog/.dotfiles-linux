# Install on a new machine

A clean WSL 2 install to a working environment. Roughly 30 minutes, most of it
unattended downloads.

The order below is not cosmetic. Packages are installed **before** the dotfiles
restore, because the restoration scripts call `jq` and `fnm` and both come from
the Brewfile. Restoring first leaves you with no statusline and no pinned Node.

---

## 1. Create the WSL instance (Windows PowerShell)

```powershell
wsl --install -d Ubuntu-24.04 --name gentleman
```

Pick a username and password when it prompts. Everything after this runs
**inside** the instance.

## 2. System prerequisites

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y build-essential curl file git zsh unzip python-is-python3
```

## 3. Homebrew for Linux

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
```

## 4. SSH keys

The repository is public, so no private key lives in it. Either copy the two
keypairs from the old machine into `~/.ssh` and `chmod 600` the private ones, or
generate new ones:

```bash
ssh-keygen -t ed25519 -C "github"    -f ~/.ssh/github-hlclarog
ssh-keygen -t ed25519 -C "bitbucket" -f ~/.ssh/bit-hclaro
```

Add each `.pub` to GitHub and Bitbucket. `~/.ssh/config` arrives in step 6 and
already points at these exact filenames.

## 5. Clone the dotfiles

```bash
git clone https://github.com/hlclarog/.dotfiles-linux.git "$HOME/.dotfiles"
cd "$HOME/.dotfiles"
git submodule update --init --recursive modules/dotly
```

## 6. Install packages, then restore

```bash
export DOTFILES_PATH="$HOME/.dotfiles"
export DOTLY_PATH="$DOTFILES_PATH/modules/dotly"

"$DOTLY_PATH/bin/dot" package import   # Brewfile + apt list. This one FIRST.
"$DOTLY_PATH/bin/dot" self install     # symlinks + restoration scripts
```

`package import` runs `brew bundle install`, so it also brings the taps and the
three casks: Claude Code, Codex and the OpenAI CLI.

`self install` creates the 14 symlinks and runs the restoration scripts: the
Windows drive link, `/etc/wsl.conf`, the projects skeleton, the Claude Code
statusline, the gentle-ai selections, the Node pin, the Windows-side
`.wslconfig` (script 09) and Moshi remote access (script 10).

## 7. Apply `/etc/wsl.conf`

Restoration script 03 prints the exact command to run if it could not get sudo
without a password. Run it, then from **Windows PowerShell**:

```powershell
wsl --shutdown
```

Reopen the terminal. This is what activates systemd, the default user, and the
`metadata,umask=22,fmask=11` mount options that keep files on the Windows drives
executable.

## 8. Reinstall the agent assets

```bash
gentle-ai
```

`~/.gentle-ai/state.json` was restored in step 6, so the preset, the SDD mode,
strict TDD and every per-phase model and effort assignment are already chosen.
This regenerates what they produce: `~/.claude`, `~/.config/opencode` and
`~/.codex`. Those directories are deliberately absent from the repository — they
are generated output, not configuration.

---

## 9. Remote access from a phone or tablet (Moshi)

Moshi drives this machine's agents from a mobile device: approvals, push
notifications and a terminal over SSH/Mosh. Restoration script 10 automates what
it can and *prints* whatever needs elevation or a human.

Two pairing layers exist and confusing them costs hours. They are independent:

| Layer | What it does | Command |
|---|---|---|
| Host ↔ account | Claims the machine for **one** device | `moshi-hook pair --token …` |
| SSH key | Appends an ED25519 key to `authorized_keys` | `moshi-hook host setup` (QR) |

Revoking SSH keys does **not** release the first layer's claim.

### 9.1 Networking: mirrored, not NAT

Nothing works without this. Under NAT `eth0` sits on a private `172.x` address
that no other device on the LAN can reach. Script 09 installs `.wslconfig`; then,
from **Windows PowerShell**:

```powershell
wsl --shutdown
```

Wait a full ~10 seconds before reopening. Reconnecting sooner reuses the old VM
and the distribution stays on NAT. Confirm `ip -4 addr` shows the real LAN
address, not `172.x`.

### 9.2 Hyper-V firewall

Mirrored networking still blocks inbound (`DefaultInboundAction: Block`). From an
**elevated PowerShell**:

```powershell
$wsl = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
New-NetFirewallHyperVRule -Name "WSL-SSH" -DisplayName "WSL SSH" `
  -Direction Inbound -VMCreatorId $wsl -Protocol TCP -LocalPorts 22 -Action Allow
New-NetFirewallHyperVRule -Name "WSL-Mosh" -DisplayName "WSL Mosh" `
  -Direction Inbound -VMCreatorId $wsl -Protocol UDP -LocalPorts 60000-61000 -Action Allow
```

Two narrow rules, **not** `DefaultInboundAction Allow` — that opens every port on
the VM. `netsh portproxy` is not an alternative either: it forwards TCP only, and
Mosh needs UDP 60000-61000.

### 9.3 Pairing (manual, on purpose)

```bash
moshi-hook pair --token <token from the app> --store file
systemctl --user restart moshi-hook.service
```

`--store file` because there is no Keychain on Linux. The token comes from the
app under `Settings → Integrations` (or `Settings → Hooks`, depending on the
version).

Check `moshi-hook host list | grep -v revoked` first: if `pair` already
provisioned the SSH key, `host setup` and its QR scan are unnecessary.

---

## Verify

Open a new terminal and check each line:

```bash
echo $SHELL                       # /home/linuxbrew/.linuxbrew/bin/zsh
node --version                    # v24.14.1, from fnm
command -v jq starship herdr      # all three resolve
ssh -T git@github.com             # Hi <user>!
ssh -T git@bitbucket.org          # authenticated via ssh key
nvim --headless -c 'lua print(vim.fn.stdpath("config"))' -c qa
brew bundle check --file=os/linux/brew/Brewfile
```

`herdr` starts automatically in an interactive shell. If it does not, the
`start_if_needed` guard at the end of `.zshrc` says why.

Then remote access:

```bash
ip -4 -o addr show | grep -v ' lo '   # real LAN address, NEVER 172.x
ss -tln | grep ':22 '                 # sshd listening
moshi-hook probe                      # running: true, gateway: true
moshi-hook host list | grep -v revoked
```

Check port 22 with `ss`, not `systemctl is-active ssh`: Ubuntu 24.04 activates
sshd through `ssh.socket`, so the service unit reads inactive while the port is
listening — a false negative.

`ssh <user>@<lan-ip>` answering `Permission denied (publickey)` is **success**,
not failure: it proves TCP arrived, sshd answered and it demands a key. Moshi's
private keys live on the phone, not here. To confirm password auth is off
without needing sudo:

```bash
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password <user>@localhost
```

That must return `Permission denied (publickey)`.

---

## Not in the repository, on purpose

| Item | Why | What to do |
|---|---|---|
| SSH private keys | Public repository | Copy or regenerate — step 4 |
| `~/.claude`, `~/.config/opencode`, `~/.codex` | Generated by `gentle-ai` | Step 8 |
| Engram database | Data, not configuration | Copy `~/.engram` from the old machine |
| Atuin history, zoxide index | Data | Copy `~/.local/share/{atuin,zoxide}` or start fresh |
| `config/nvim/spell/` | 24 MB of regenerable dictionaries | Neovim downloads them on demand |
| Project repositories | Cloned per machine | The empty folder skeleton arrives in step 6 |
| Moshi pairing (`~/.local/state/moshi/secrets.json`, `authorized_keys`) | Host credentials and per-device keys, bound to one app install | Re-pair — step 9.3 |
| Hyper-V firewall rules | Live on Windows and need elevation | Run the two commands in step 9.2 |

---

## Gotchas worth knowing

**Editing `config/herdr/config.toml` does nothing on its own.** herdr is a
background server that reads its config at startup, so a new pane attaches to a
server still holding the old values. Apply changes without losing sessions:

```bash
herdr server reload-config
```

herdr also writes its own interface preferences back into that file, so expect it
to show as modified after tweaking things in the UI.

**No herdr delivery mode works on its own under WSL.** This corrects an earlier
version of this file, which claimed `terminal` worked. It does not. All three
modes fail, for different reasons:

- `system` shells out to `notify-send`, which is not installed in WSL and has no
  notification daemon to talk to.
- `terminal` emits OSC 9, but **Windows Terminal does not render OSC 9 toasts**.
  Verified by writing the escape sequence straight to the outer pty, bypassing
  herdr entirely: nothing appears, in either the BEL or ST terminator form.
- `herdr` draws the toast inside the TUI, so it never reaches you with another
  window in front.

The config keeps `delivery = "herdr"` because that at least works while herdr is
on screen. The real visual alert and the sound both come from the shim below.

To test OSC 9 yourself: a pane's pty is NOT the terminal's. Find the client's
with `ls -l /proc/<herdr-client-pid>/fd/1` and write there.

Sound only fires for agents in **background** workspaces. Watching the pane that
finishes gives you nothing, by design.

**`tools/herdr/herdr-mp3-shim` exists because herdr cannot play its own sounds
here.** herdr has no audio engine: it writes a temporary mp3 and delegates to an
external player, probing for `ffplay`, `mpv`, `mpg123`, `paplay`, `aplay`, `vlc`,
`play`, `pw-play`, `powershell`, `pwsh` and `cmd.exe`. Two things broke that, and
the shim — installed as `paplay`, the first Linux name herdr picks — fixes both:

1. *The path.* herdr hands the player a **Linux** path (`/tmp/herdr-sound-*.mp3`)
   that no Windows player can open. The shim converts it with `wslpath` to
   `\\wsl.localhost\<distro>\...`. Never hardcode the distro name — this one is
   called `gentleman`, not `Ubuntu`.
2. *The PATH.* These dotfiles deliberately strip every `/mnt/c` entry from PATH,
   so herdr found no player at all and failed with `no mp3-capable audio player
   available` — leaving no trace in `herdr-server.log`, which only ever reports
   `outcome="ok"`.

Do **not** put `powershell` or `powershell.exe` on PATH to fix this. herdr probes
for them before the Linux names and prefers them, and its own PowerShell path
handling is the broken one, so the sound goes silent again. Call PowerShell by
absolute path, as the shim does.

The shim also raises the Windows toast with `NotifyIcon` on the same PowerShell
call. Audio goes through `MediaPlayer` (presentationCore); `System.Media.SoundPlayer`
would not work, it is WAV-only. herdr passes only the audio file, never the
notification title or body, so the visual text is generic by necessity.

Debug it with:

```bash
: > ~/.local/state/herdr-sound.log
herdr notification show "test" --sound done
cat ~/.local/state/herdr-sound.log
```

**Restart the moshi-hook daemon after `pair` or `unpair`.** Both rewrite
`secrets.json` but do not signal the running daemon, which keeps the old identity
in memory and gets `Invalid host secret` on every API call. With the event
channel down no notification goes out at all, whatever the settings say. Note
that `moshi-hook probe` reads the host id from the *file*, not the process, so it
shows the new one while the daemon still uses the old — confirm in the log with
`ws bridge connected hostId=<expected>`.

**`unpair` + `pair` mints a new host id rather than transferring the old one.**
The previous device's SSH key is then orphaned but still live: its comment points
at the old host id, and `authorized_keys` knows nothing about Moshi host ids, so
that device keeps shell access until the key is revoked by hand.

**Two devices at once requires Moshi Pro.** The free tier is account-less, so
every install carries its own implicit identity and a host belongs to exactly
one. That is why a second device reports the host is already paired with another
account even when no account was ever created.

**Develop on ext4, not on `/mnt`.** The Windows drives go through 9p, measured
here at 136x slower for creating a thousand small files, and inotify never fires
so file watchers and hot reload stay silent. `~/Projects` is ext4; `~/Win` is the
link into the Windows tree for read access during a migration.

**Line endings on the Windows drives.** `git/config-windows-drives` scopes
`autocrlf = true` and `fileMode = false` to `gitdir:/mnt/`, which is what stops
repositories there from showing every file as modified. Do not widen it into the
global config.

**`ctrl+a` is the herdr prefix**, which shadows zsh's beginning-of-line inside
panes. Use `Home`, or change `prefix` in the herdr config.

---

## Keeping the repository current

**Do not run `dot package dump`.** Its brew step calls
`brew bundle --force cleanup`, which uninstalls anything not yet declared, and
its apt step overwrites the curated seven-package list with every manually
installed package on the system. Refresh the Brewfile explicitly instead:

```bash
cd "$DOTFILES_PATH"
brew bundle dump --file=os/linux/brew/Brewfile --force --brews --casks --taps
```

Those three flags matter. Without `--casks` the dump silently drops Claude Code
and Codex, and without them declared a restore comes up with no AI CLIs at all.
Re-add anything the dump loses because it is declared but not currently
installed, and keep `os/linux/apt/packages.txt` hand-curated.

`~/.gentle-ai/state.json` is copied rather than symlinked, because gentle-ai
rewrites it atomically and would replace a symlink with a regular file. Re-export
it after changing settings in the TUI:

```bash
cp ~/.gentle-ai/state.json "$DOTFILES_PATH/os/linux/gentle-ai/state.json"
```
