# Install on a new machine

A clean WSL 2 install to a working environment. Roughly 30 minutes, most of it
unattended downloads.

Step 6 below runs a single `dot self install`. Restoration script 04 installs
the Brewfile itself, before any script that depends on it, so packages no
longer need a separate, ordered `dot package import` beforehand.

---

## Linux server VM: bootstrap first

On a fresh Ubuntu Server VM (nothing installed yet, not even the dotfiles),
run this one line first:

```bash
curl -fsSLo bootstrap-linux https://raw.githubusercontent.com/hlclarog/.dotfiles-linux/master/scripts/bootstrap-linux && bash bootstrap-linux
```

It is a single, standalone, self-contained script -- it never reads any other
file from this repository, so it works before the repository is even cloned.
It is interactive (sudo password prompts are expected) and safe to rerun.
Run it with `--check` to only report what is pending, without changing
anything.

| Step | What | Why |
|---|---|---|
| apt | `apt-get update`/`full-upgrade`, installs the packages from section 2 below plus `openssh-server`, `zram-tools`, `cloud-guest-utils` and `qemu-guest-agent` | same prerequisites as a manual install, plus what the later steps need |
| disk (server only) | grows the root LV (or partition) to use the whole disk | the Ubuntu Server installer's guided LVM layout leaves most of the volume group unallocated by default |
| zram (server only) | configures zstd-compressed zram swap, on top of the installer's disk swap file kept as a fallback | a 6 GB RAM VM is tight; RAM-backed compressed swap is far cheaper than the disk swapfile |
| panic (server only) | sets `kernel.panic = 10` in `/etc/sysctl.d/99-panic-reboot.conf` | a panicked VM would otherwise hang forever while UTM still reports it as started, so the Mac watchdog never restarts it |
| guest-agent (server only) | enables `qemu-guest-agent` | lets the Mac host (UTM) shut the VM down cleanly and read its IP with `utmctl` |
| timezone (server only) | sets the system timezone (default `America/Bogota`, override with `--timezone <Zone>`) | the installer defaults to UTC and never asks again |
| sshd | enables the ssh server | needed for remote access; hardening is left to the dotfiles restore, once `authorized_keys` exists |
| brew (skip with `--skip-brew`) | installs Homebrew for Linux | same as section 3 below |
| restore | offers to launch Dotly's restorer directly, or prints the exact command to run it later | still needs the answers from step 4 (SSH keys) below |

WSL only runs the steps it does not skip: disk, zram, guest-agent and
timezone are server-only and print a one-line skip reason there instead;
apt, sshd, brew and restore all still run.

Afterwards, continue from step 4 below (SSH keys), then either answer yes to
bootstrap-linux's own restorer prompt, or run the restorer command it
printed.

## 1. Create the WSL instance (Windows PowerShell)

```powershell
wsl --install -d Ubuntu-24.04 --name gentleman
```

Pick a username and password when it prompts. Everything after this runs
**inside** the instance.

## 2. System prerequisites

On a Linux server VM, `bootstrap-linux` above already did this (its `apt` step).

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y build-essential curl file git zsh unzip python-is-python3
```

## 3. Homebrew for Linux

On a Linux server VM, `bootstrap-linux` above already did this (its `brew`
step, unless it was run with `--skip-brew`).

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

## 6. Restore

```bash
export DOTFILES_PATH="$HOME/.dotfiles"
export DOTLY_PATH="$DOTFILES_PATH/modules/dotly"

"$DOTLY_PATH/bin/dot" self install     # symlinks + restoration scripts, Brewfile included
"$DOTLY_PATH/bin/dot" package import   # apt list (sudo); its Brewfile half is a no-op now
```

Dotly's own `self install` has a bug: it runs `sudo chsh -s "$(command -v
zsh)"` with no username (`modules/dotly/scripts/self/install:34`), so under
`sudo` it changes **root's** shell instead of yours, and your login shell
stays bash — zsh-only config such as the starship prompt, atuin and herdr
autostart never loads. Restoration script 00 (sorting first) fixes the
invoking user's login shell instead and resets root's back to `/bin/bash` if
it was left pointing at a Homebrew zsh; it may prompt for your sudo password.

Restoration script 04 installs `os/linux/brew/Brewfile` itself, as the first
restoration script, before scripts that depend on `jq` or `fnm` run. It also
pre-trusts every `trusted: true` tap, formula and cask before calling
`brew bundle install` — Homebrew 7.0.6 has a Linux bug where `brew bundle
install` aborts entirely on the first untrusted third-party cask even when the
Brewfile already marks it `trusted: true` (Homebrew's `Skipper.skip?` loads the
cask, and raises on the untrusted tap, before `installer.rb` ever applies the
Brewfile's own `trusted:` options). A bare `cask "openai"` would also never be
recognized as belonging to the `openai/tools` tap, so every third-party entry
in the Brewfile is written fully qualified (`tap/name`) as well.

Steps 2 and 3 above (apt prerequisites and Homebrew itself) both need `sudo`
and are **not** automated by script 04 — it locates an existing `brew` binary
but never installs one, and skips packages entirely if it finds none.

Script 04 runs `brew bundle install --no-upgrade`, so rerunning `self install`
on a machine that is already set up installs only what is missing and never
upgrades anything behind your back.

Claude Code itself comes from Anthropic's own installer
(`04-claude-code.sh`, sorting right after script 04), not the Homebrew
cask: the cask lagged behind the minimum version Pi's claude-bridge needs,
and `claude update` refuses to run on a brew install, while the native
`~/.local/bin/claude` install auto-updates on every launch and `claude
update` works normally. If it finds the Homebrew cask still installed once
the native binary works, it removes it.

The apt list in `os/linux/apt/packages.txt` is **not** covered by script 04:
only `dot package import` installs it, with `sudo`. Run it after `self
install` — or, with Dotly's `restorer`, answer **Y** to "import previous
installed packages". Its Brewfile half is then a no-op, because script 04
already installed everything. Be aware that this import is silent
(`dot package import >/dev/null 2>&1 | ...`) and always reports success
regardless of the real result; script 04's output in `~/dotly.log` is the
place to check whether the Brewfile installed. Re-running `dot self install`
afterward is not needed just for ordering.

`self install` creates the 14 symlinks and runs the restoration scripts: the
Windows-side `.wslconfig` (script 01), brew packages (script 04), the Windows
drive link, `/etc/wsl.conf`, the projects skeleton, the gentle-ai selections
(script 06), the Node pin (script 07), Pi itself (script 08) and Moshi remote
access (script 10). Script 09 then runs `gentle-ai sync` from the state script
06 restored, and also syncs Pi's own agent assets once script 08 installed it
-- see step 8. Script 11 also installs CodeGraph itself, running `npm i -g
@colbymchenry/codegraph` through fnm's default Node the first time it finds the
wrapper symlinked but no shim installed yet, and registers its MCP server with
opencode by creating a fresh `opencode.json` when only gentle-ai's
`opencode.jsonc` exists yet, since opencode merges both files but jq cannot
parse the `.jsonc` one. Script 12 also installs Codex's engram memory plugin
(marketplace + `plugin add`) when `codex` and `~/.codex/config.toml` are
present, independently of herdr. Script 14, sorting after 09, sets
the Claude Code statusline. Script 15, sorting last and order-independent,
installs Rust (rustup, stable, default profile) via the official installer --
needing only curl, not fnm or anything else the restore installs first.
Restoration scripts must be committed executable
(`100755`): `dot self install` silently skips any script that is not.

## 7. Apply `/etc/wsl.conf`

Restoration script 03 prints the exact command to run if it could not get sudo
without a password. Run it, then from **Windows PowerShell**:

```powershell
wsl --shutdown
```

Reopen the terminal. This is what activates systemd, the default user, and the
`metadata,umask=22,fmask=11` mount options that keep files on the Windows drives
executable.

## 8. Agent assets (already synced by the restore)

Script 08 installs Pi itself first: it downloads the official installer from
`https://pi.dev/install.sh` and runs it through `fnm exec --using=default`,
detached from the terminal (`setsid -w`, or a `python3` fallback where
`setsid` is missing, such as macOS) with stdin redirected from `/dev/null`.
Detaching matters: with a real `/dev/tty` reachable the installer shows an
interactive menu and offers to append a PATH line to `~/.zshrc`, which here is
a symlink into this repository. `$HOME/bin` is put first on PATH for the run,
matching `shell/exports.sh`, so the installer's PATH probe picks the same
launcher location already used on the reference machine. Once Pi is on PATH,
script 08 seeds `~/.pi/agent/{settings,subagents,claude-bridge,mcp}.json` from
`config/pi/agent/` (never overwriting an existing file), then repairs
`claude-bridge.json`'s `pathToClaudeCodeExecutable`: the seed assumes Claude's
native installer (`~/.local/bin/claude`), matching the reference machine, but
when that path is not an executable file -- for example when Claude comes
from Homebrew instead -- it is rewritten to whatever `claude` resolves to on
PATH, or dropped entirely (falling back to the SDK's own lookup) when no
`claude` is found. This repair also runs against a `claude-bridge.json` left
over from an earlier restore, not just a freshly seeded one. Script 08 then
builds `~/.pi/gentle-ai/profiles.json` with all six saved profiles
(`current`, `claude-full`, `claude-medium`, `claude-low`, `codex-medium`,
`codex-low`) with `claude-medium` active, installs every package pinned in the seeded
`settings.json` with `pi install <source>` -- `pi update --extensions`
silently skips pinned specs such as `npm:gentle-engram@0.1.8`, so each package
is installed explicitly instead -- and finally runs `pi -p
"/gentle:install-sdd"` **twice** to install the SDD agents, chains and support
files: gentle-pi only applies the saved models to installed agents at
session_start, and the first run's install-sdd creates those agents after
that point in the same session, so they lack model/thinking frontmatter until
a second session's session_start reapplies the saved models to them.
Logging into Pi is one of several manual steps left afterward --
`~/.pi/agent/auth.json` is never restored -- see "After the restore: logins
and keys" below for a guided walkthrough of all of them. Switch the active
profile from inside Pi with `/gentle:profiles`.

Script 09 already did this during step 6, once `gentle-ai`, `opencode` and
`fnm` were on PATH (script 04) and `~/.gentle-ai/state.json` -- the preset, the
SDD mode, strict TDD and every per-phase model and effort assignment -- was
restored (script 06). It warms up opencode's first start (its own
`node_modules` bootstrap can take a couple of minutes) with `opencode debug
config`, then runs `fnm exec --using=default gentle-ai sync`, which regenerates
what that state produces: `~/.claude`, `~/.config/opencode` and `~/.codex`.
Those directories are deliberately absent from the repository — they are
generated output, not configuration. If script 08 installed Pi, it also runs
`gentle-ai sync --agents pi`, which writes the context7 MCP entry and
`~/.pi/gentle-ai/persona.json` while preserving any existing engram entry.

`dot self install` is safe to rerun on an already set-up machine: script 09
re-syncs the agent assets from the current state file every time. To resync by
hand:

```bash
fnm exec --using=default gentle-ai sync
```

### Restore the Pi OpenAI model profile (manual recovery for an existing registry)

A fresh machine already has this: script 08 builds
`~/.pi/gentle-ai/profiles.json` with all four saved profiles (`current`,
`claude-full`, `claude-full.autogen`, `open-ai-full.autogen`) and activates
`claude-full.autogen` the first time it installs Pi, so nothing else needs to
run for a new machine.

This script instead exists for an **existing** registry that predates that
restore, or one where `open-ai-full.autogen` is missing or was overwritten
with Claude mappings. Run it from the dotfiles checkout:

```bash
cd "$HOME/.dotfiles"
./scripts/restore-pi-openai-profile
```

This command is not part of `dot self install` or `gentle-ai`. On an existing
registry it adds only the missing profile, **never changes the active
selection**, and returns without writing when the profile already matches. By
default, it
refuses to overwrite a different same-name profile; malformed or symlinked
registries are always refused. If the 26 OpenAI roles were overwritten with
Claude mappings, **close Pi first** and review the existing
`~/.pi/gentle-ai/profiles.json` before choosing explicit recovery:

```bash
cd "$HOME/.dotfiles"
./scripts/restore-pi-openai-profile --replace
```

This replaces only `open-ai-full.autogen` from the trusted repository source,
without changing other profiles or the active selection. Before changing an
existing registry, the script saves its **exact original bytes** in a private
(mode `600`) `profiles.json.backup-*` file alongside it. Review the restored
profile and retain the backup until you have checked the result; the backup may
contain private registry data. If the profile already matches, `--replace`
does nothing and creates no backup. Restart Pi after restoring to reload its
registry.

The repository saves model names and thinking levels only. Pi authentication
(`~/.pi/agent/auth.json`) stays private and is **not** restored by this command;
model availability still depends on valid provider authentication and Pi's
model catalog.

For Claude profile recovery, `config/pi/claude-profiles.json` saves only the
model and thinking mappings for `current`, `claude-full` and
`claude-full.autogen`. Close Pi before running `./scripts/upgrade-pi-claude-opus`
on an existing registry: it updates exact old Opus references without changing
the active profile and saves a private backup when it makes changes. The
migration cannot create a fresh Pi registry; the snapshot is for manual
recovery, not automatic restore. Restart Pi to load the updated registry.

---

## 9. Remote access from a phone or tablet (Moshi)

Moshi drives this machine's agents from a mobile device: approvals, push
notifications and a terminal over SSH/Mosh. Restoration script 10 automates what
it can and *prints* whatever needs elevation or a human.

Most of this applies to any Linux restore, WSL or not: sshd hardening,
downloading and installing `moshi-hook` itself, and its daemon/pairing all run
on a plain Ubuntu VM exactly as they do here. Hardening (`PasswordAuthentication
no`) is skipped, with a message, until `~/.ssh/authorized_keys` actually has a
key in it -- installing it earlier would lock out password login, the only
login the machine has, with no way back in except console access. Only the
Hyper-V inbound firewall rules below (9.2) are WSL-specific: a bare-metal or
cloud VM has no Hyper-V layer to punch a hole in, so that step is skipped
there.

Two pairing layers exist and confusing them costs hours. They are independent:

| Layer | What it does | Command |
|---|---|---|
| Host ↔ account | Claims the machine for **one** device | `moshi-hook pair --token …` |
| SSH key | Appends an ED25519 key to `authorized_keys` | `moshi-hook host setup` (QR) |

Revoking SSH keys does **not** release the first layer's claim.

### 9.1 Networking: mirrored, not NAT

Nothing works without this. Under NAT `eth0` sits on a private `172.x` address
that no other device on the LAN can reach. Script 01 installs `.wslconfig`; then,
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

Then provision the device's SSH key. `pair` sometimes does this on its own and
sometimes does not, so verify rather than assume:

```bash
moshi-hook host list | grep -v revoked
wc -l < ~/.ssh/authorized_keys
```

If no key is listed, run `host setup` **in a terminal you can see**: it renders a
QR to stdout and blocks until the device scans it.

```bash
moshi-hook host setup --host "$(hostname).local" --user "$(id -un)" --port 22
```

The QR expires in about ten minutes. Nobody can run this step on your behalf, an
agent included, because the QR has to reach your eyes.

**Advertise the mDNS name, never an address.** Windows answers mDNS for its own
hostname and iOS resolves it through native Bonjour, so `<hostname>.local`
follows the machine across networks and across DHCP leases while a literal IP
does not. WSL cannot resolve `.local` itself (`nsswitch.conf` is `files dns`,
with no avahi) but that is irrelevant — the phone's resolver is the one that
matters.

---

### 9.4 Reaching the host: which network the device is on

The two transports are independent and only one of them cares about the network:

| Transport | Carries | Needs inbound? |
|---|---|---|
| Cloud gateway | Approvals, push, image paste | No. Outbound WebSocket, works anywhere |
| SSH / Mosh | The actual terminal | Yes. The device must reach port 22 |

"Notifications work but the terminal does not" is therefore the expected symptom
of a reachability problem, not two separate faults. Diagnose them separately.

**Do not put the device on the laptop's Mobile Hotspot.** Windows ICS rewrites
the device's source address to the laptop's own LAN IP, so the device ends up
addressing the very machine it is talking through. That rebound is NAT hairpin,
and it dies at key exchange:

```
sshd: error: kex_exchange_identification: read: Connection reset by peer
sshd: Connection reset by <the laptop's own LAN IP>
```

TCP connects and sshd sends its banner, which makes the path look healthy right
up until it is not. WSL never mirrors the hotspot adapter either, so `ip -4 addr`
shows no `192.168.137.x` and sshd could not bind there regardless. `netsh
portproxy` papers over the hairpin but forwards TCP only, which loses Mosh
permanently.

**Invert it: the phone hosts, the laptop joins.**

```
phone 172.20.10.1  (router)  <-->  laptop 172.20.10.2/28  (client)
```

The phone is now the router and the laptop an ordinary client, so phone to laptop
is a direct same-subnet connection with no NAT in the path. SSH and Mosh both
work, WSL mirrors the joined Wi-Fi adapter as a normal interface, and the
existing `LocalSubnet` rules already cover it. The direction of the NAT is what
decides this: traffic toward the router's own LAN IP hairpins, traffic from the
router toward a client does not.

Internet stays on the wired link as long as it keeps the lower metric:

```bash
ip route | grep '^default'    # Ethernet metric 25, phone metric 45
```

Verify the path end to end:

```bash
ip -4 -o addr show | grep -v ' lo '    # the hotspot-assigned client IP appears
ping -c2 172.20.10.1                   # the phone answers
timeout 5 bash -c 'exec 3<>/dev/tcp/<client-ip>/22 && head -c 40 <&3'
journalctl -u ssh --since '-10 min' | grep Accepted
```

`Accepted publickey ... from 172.20.10.1` is the only real proof. Everything
short of it can pass while the terminal still fails.

### 9.5 Updating moshi-hook

The app suggests `pkill -TERM -f "moshi(-hook)? serve" ; moshi serve &`. **Do not
run that here.** This host runs the daemon under systemd, so the kill trips
`Restart=on-failure` while the manual `serve` adds a second daemon fighting for
the same socket and gateway port, and that one dies at logout. Use:

```bash
moshi-hook update
systemctl --user restart moshi-hook.service
moshi-hook install
systemctl --user restart moshi-hook.service
```

`update` replaces the binary and says so, but never restarts the daemon. The
second `install` matters because a release can add hooks the old one lacked:
0.3.19 added a `Notification` hook that 0.3.0 had no concept of. Confirm with:

```bash
moshi-hook status | grep -E '^ +(claude|codex|opencode|pi) '   # all four: current
pgrep -af 'moshi-hook serve'                                   # exactly one process
```

Newly installed hooks do not reach an already-running agent session, which read
its settings at startup. Only sessions opened afterwards pick them up.

### 9.6 Tailscale: reachable without opening a port

Moshi covers agent hooks and approvals; [Tailscale](https://tailscale.com) covers
plain SSH from anywhere, without forwarding port 22 to the internet. Restoration
script 16 installs it (Linux only -- macOS gets it from the app, and WSL uses the
Windows client instead, since `tailscaled` inside WSL fights the Windows network
stack) through the official installer, which adds Tailscale's own apt repository
so later updates come through `apt upgrade` like everything else.

Authentication stays manual on purpose -- it needs a browser login, and a
restoration script must never block on one. After the restore, on the machine:

```bash
sudo tailscale up
sudo tailscale set --operator="$(id -un)"   # run tailscale without sudo afterwards
```

`tailscale up` prints a URL; open it, and sign in to the tailnet. Then, in the
[admin console](https://login.tailscale.com/admin/machines), disable key expiry
for this machine so it does not silently drop off the tailnet later. Any other
device on the same tailnet -- phone, laptop -- needs the Tailscale app installed
and logged into that same account; once it is, `tailscale ip -4` on this machine
gives the address to SSH to.

### 9.7 ZeroTier (optional fallback)

Tailscale is the primary remote access path above. [ZeroTier](https://www.zerotier.com)
is a second, fully independent option -- worth adding only if you want a
fallback that does not depend on Tailscale's own control plane: no domain to
buy, no server to run, phone/desktop apps, and network-level access so
Moshi/mosh work over it too. It is never installed or configured
automatically; `scripts/post-restore-secrets` only offers it, defaulting to
**no**, and answering no leaves it completely untouched.

If you do want it, when you create the network at
[my.zerotier.com](https://my.zerotier.com), set its Managed Route/IP pool to a
private range that is **not** inside `100.64.0.0/10` -- for example
`10.147.17.0/24`. That range is what Tailscale reserves for itself on Linux
and drops on any interface other than `tailscale0`, so a ZeroTier network
reusing it would silently lose traffic.

Run just this step by hand:

```bash
POST_RESTORE_ONLY=zerotier scripts/post-restore-secrets
```

It offers the official installer if `zerotier-cli` is missing, prompts for the
network ID, joins it, and reminds you to authorize the member in ZeroTier
Central's Members tab. On the client (laptop/phone), install the ZeroTier app,
join the same network ID, authorize it, then `ssh <user>@<this machine's
ZeroTier IP>` -- an untracked `~/.ssh/config.d/` entry works well for that.

---

## 10. Code knowledge graph for every agent (CodeGraph)

[CodeGraph](https://github.com/colbymchenry/codegraph) keeps a local SQLite graph
of a codebase's symbols, edges and files, served to agents over MCP. No API keys
and no external service. It is **per project**: `codegraph init` creates
`.codegraph/`, and until that exists the graph tools have nothing to answer
from. Restoration script 11 wires it into every agent that can take it.

### 10.1 Why a hook and not a skill

A skill is *model-invoked*: the model decides whether to load it, so it can never
deliver "always, before starting work". A hook is *harness-executed* and
deterministic. The goal is that an agent tells you to run `codegraph init` on an
unindexed project before it starts tracing call paths, so `SessionStart` is the
right event.

CodeGraph's own bundled hook cannot do this job. `codegraph prompt-hook` is
**silent** on an unindexed project: pipe a payload into it where no
`.codegraph/` exists and you get empty stdout and exit 0, logged in its telemetry
as `prompt-hook-gate-noop-no-index`. It never reports the missing index, which is
the one case worth reporting.

### 10.2 There is no hook parity between agents

| Agent | Session hook | How context is injected |
|---|---|---|
| Claude Code | native, `~/.claude/settings.json` | `hookSpecificOutput.additionalContext` JSON on stdout |
| Codex | native, `~/.codex/hooks.json` (same schema) | plain stdout becomes context |
| opencode | **none** | plugin in `~/.config/opencode/plugins/*.ts`, via the `chat.message` hook |
| Pi | **none at all** | not applicable - excluded on purpose |

opencode plugins get no id generator, so a synthetic part has to copy ids from an
existing part. `plugins/skill-registry.ts` is the working template.

**Pi is excluded deliberately, not overlooked.** It has no hook system: nothing
in `~/.pi/agent/settings.json`, nothing in `pi --help`, only extensions and
`--append-system-prompt`. It also needs nothing, because gentle-pi already ships
`extensions/codegraph-tools.ts` whose tool description says to run `init` before
querying an unindexed workspace. A reminder would duplicate it.

### 10.3 What carries the behaviour

Three files, all symlinked through `symlinks/conf.yaml`:

```
tools/codegraph/codegraph                     stable-PATH wrapper (see the gotcha)
tools/codegraph/codegraph-session-reminder    shared by Claude Code and Codex
tools/codegraph/codegraph-index-reminder.ts   the opencode plugin
```

The reminder stays quiet unless all three hold: the directory is a real project
(`.git`, `package.json`, `go.mod`, `Cargo.toml`, `pyproject.toml` and friends),
`.codegraph/` is missing, and the `codegraph` binary exists. It is silent in
`$HOME`, at `/`, in markerless directories and on already-indexed projects, and
it always exits 0.

It only reads stdin when `--cwd` is absent **and** stdin is not a TTY. Blocking on
an unwritten pipe would stall every single session start.

---

## 11. Engram daemon

The Brewfile installs `engram` but nothing else launches it, so without this
step memory never persists across sessions. Restoration script 13 installs
`os/linux/systemd/engram-serve.service` as a systemd user service and enables
it with linger, so it survives logout the same way the moshi-hook daemon does.

It runs on `ENGRAM_PORT=7438`, not the default, because the Windows-side engram
already owns port 7437 and mirrored WSL networking shares that port namespace.
Two daemons contending for 7437 is a clash that fails silently: whichever binds
second simply never receives a connection.

`~/.engram/cloud.json` carries the cloud server URL and the sync token. It is
NOT in the repository — see "Not in the repository, on purpose" below.

---

## Office iMac: keep the VM up 24/7

An office iMac hosts an Ubuntu VM in UTM (`sandbox-imac-hclaro-vm`, SSH alias
`sandbox-imac`) that needs to stay
reachable after a reboot, a power cut, or the Mac going to sleep. This is a
separate, one-shot setup that runs by hand on the iMac itself, in an
interactive terminal (sudo password prompts are expected there).

Clone the dotfiles on the iMac first, then run the setup script:

```bash
git clone https://github.com/hlclarog/.dotfiles-linux.git ~/.dotfiles
cd ~/.dotfiles
./scripts/setup-mac-vm-host           # applies everything it safely can
./scripts/setup-mac-vm-host --check   # status only, exits 1 if anything is pending
```

It is idempotent — safe to rerun after any change (a new macOS version, a
renamed VM via `--vm NAME`, a moved checkout). Each step prints ✓ or
`pending:`:

1. **Power** — `pmset -a sleep 0 disksleep 0 standby 0 autopoweroff 0
   powernap 0 autorestart 1 womp 1`. Sleep, disk sleep, standby, auto power
   off and power nap all suspend the VM with the host; `autorestart` and
   `womp` bring the Mac back on its own after a power cut instead of sitting
   off until someone walks over. `displaysleep` is left alone, so the screen
   can still turn off. `systemsetup -setrestartfreeze on` restarts the Mac if
   it ever freezes solid instead of hanging forever.
2. **Automatic login** — cannot be scripted safely (macOS stores an
   obfuscated copy of the password), so the script only checks and, if
   missing, prints the manual steps: System Preferences > Users & Groups >
   Login Options > Automatic login. FileVault must be off for this to work.
   This matters because the LaunchAgent below, and UTM itself, only run
   inside a logged-in GUI session — without auto-login, a reboot leaves the
   VM stopped at the login window.
3. **LaunchAgent** — renders `os/mac/vm-host/dotfiles.utm-autostart.plist.template`
   into `~/Library/LaunchAgents/dotfiles.utm-autostart.plist` and loads it
   with `launchctl bootstrap`. This runs `os/mac/vm-host/utm-autostart`
   (POSIX sh) every 5 minutes and right after login: if the VM is paused it
   resumes it, and if it is stopped, crashed, or UTM has not finished
   launching yet, it retries starting it a few times. It logs to
   `~/Library/Logs/utm-autostart.log` (kept bounded to the last ~2000 lines).
4. **UTM** — confirms `/Applications/UTM.app` and `utmctl` exist and that
   `utmctl list` actually contains the VM name. The first `utmctl` call
   launchd makes may trigger a macOS Automation permission prompt — watch for
   it and allow it, or the watchdog silently fails every time after that.

If `~/Library/LaunchAgents` turns out to be owned by another user (commonly
`root`, left behind by an adware installer or similar), the LaunchAgent step
reports it as `pending` instead of touching it: forcing a `chown` there could
paper over unwanted software still running elsewhere. Inspect
`/Library/LaunchDaemons` and anything else installed around the same time
before running the `sudo chown` command the script prints.

To test: `sudo reboot`, then from another machine wait ~3 minutes and
`ssh sandbox-imac`. To pause the watchdog on purpose (for example, to stop
the VM by hand without it being restarted 5 minutes later):

```bash
touch ~/.utm-autostart-disabled
```

---

## After the restore: logins and keys

`dot self install` restores everything it safely can unattended, but a
handful of steps genuinely need a human: browser logins, device pairing and
anything gated behind a sudo password. `scripts/post-restore-secrets` is the
only manual step left -- a single guided walkthrough that checks each of
them, explains what to do, and offers to run it in the foreground so you can
complete the login yourself.

```bash
cd "$HOME/.dotfiles"
./scripts/post-restore-secrets           # interactive, step by step
./scripts/post-restore-secrets --check   # status only, no prompts; exits 0 once nothing is pending
```

Run a single step with `POST_RESTORE_ONLY=<step-id>`, for example
`POST_RESTORE_ONLY=tailscale ./scripts/post-restore-secrets`.

| Step id | What it covers |
|---|---|
| `gh` | GitHub CLI device login (`gh auth login`) |
| `ssh-keys` | Generates any SSH key referenced by `ssh/config` that is still missing, and offers to register it with `gh` or prints it to add by hand |
| `pi` | Pi's OpenAI (ChatGPT) login |
| `claude` | Claude Code login, then registers the CodeGraph MCP server if it is still missing |
| `codex` | Codex device login |
| `opencode` | opencode login |
| `engram-cloud` | Engram cloud sync credentials (optional, skip with Enter) |
| `tailscale` | Installs Tailscale and prompts for `tailscale up` (Linux only, skipped on WSL and macOS) |
| `zerotier` | Optional: offers ZeroTier as an independent fallback (Linux only, skipped on WSL and macOS), defaults to no |
| `sshd` | Installs the `00-moshi.conf` sshd hardening, skipped with a warning until `~/.ssh/authorized_keys` actually has a key in it |
| `shell` | Sets the login shell to zsh (`sudo chsh`) |
| `moshi` | Optional: prints the Moshi pairing commands if `moshi-hook` is installed but not yet paired |

Every command it runs is either a status check or executed in the foreground
with your input -- nothing here logs in or applies sudo-gated changes on its
own.

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
systemctl --user is-active engram-serve.service   # active
```

`herdr` starts automatically in an interactive shell. If it does not, the
`start_if_needed` guard at the end of `.zshrc` says why.

Then remote access:

```bash
ip -4 -o addr show | grep -v ' lo '   # real LAN address, NEVER 172.x
ss -tln | grep ':22 '                 # sshd listening
moshi-hook probe                      # running: true, gateway: true
moshi-hook host list | grep -v revoked
moshi-hook status | grep -E '^ +(claude|codex|opencode|pi) '   # all four: current
moshi-hook status | grep 'herdr:'                              # a path, NOT "not found"
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
| Engram database, including `~/.engram/cloud.json` (server URL and sync token) | Data and credentials, not configuration | Copy `~/.engram` from the old machine |
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

**The daemon reads credentials at startup, so restart it after refreshing any
token.** This is the same trap as the one above, but it is not limited to Moshi
pairing: it applies to every agent's credentials. `moshi-hook usage` collects
each agent's quota from its account API, and the daemon holds each fetcher's
state in memory.

A real case: Codex tokens expired and the OpenAI subscription vanished from the
session details on the phone. The log said so 46 times.

```
usage fetcher: repeated poll failures; cached usage is stale agent=codex failureType=http
usage poller: synced count=1
```

`count=1` means only one agent is uploading. With two agents configured it has to
read `count=2`.

The part that nearly produced the wrong conclusion: after `codex login` the
tokens were demonstrably fresh and `moshi-hook usage` **still** listed only
claude-code, because the daemon had cached the failure. Only the restart brought
codex back.

```bash
codex login
systemctl --user restart moshi-hook.service
moshi-hook usage | grep -oE '"agent": "[^"]*"'
```

**`codex login status` lies.** It prints `Logged in using ChatGPT` with fully
expired tokens, because it checks that the token fields *exist*, not that they
are valid. Never use it to rule out an auth problem — read the JWT `exp` claim:

```bash
python3 -c "import json,base64,datetime;t=json.load(open('$HOME/.codex/auth.json'))['tokens']['access_token'];p=t.split('.')[1];p+='='*(-len(p)%4);print(datetime.datetime.fromtimestamp(json.loads(base64.urlsafe_b64decode(p))['exp']))"
```

The `chatgpt_plan_type` claim in the same token reports the real plan. If it says
`plus` and the phone still shows nothing, the subscription is not the problem.

**`unpair` + `pair` mints a new host id rather than transferring the old one.**
The previous device's SSH key is then orphaned but still live: its comment points
at the old host id, and `authorized_keys` knows nothing about Moshi host ids, so
that device keeps shell access until the key is revoked by hand.

**Two devices at once requires Moshi Pro.** The free tier is account-less, so
every install carries its own implicit identity and a host belongs to exactly
one. That is why a second device reports the host is already paired with another
account even when no account was ever created.

**An advertised IP ages badly — advertise the mDNS name instead.** `host setup`
bakes whatever `--host` receives into the pairing. Given an address, the pairing
dies on the next lease: office DHCP moved this machine from `.242` to `.229`
overnight, and cycling the phone's hotspot reassigns the subnet just as easily.
The failure looks like a Moshi fault rather than a lease change, which is what
makes it cost hours.

`--host "$(hostname).local"` ends it. Proven here: paired at `<lan-ip-a>`,
then DHCP moved the host to `<lan-ip-b>` (and the OpenVPN adapter to a new
address as well) and the phone kept connecting —
`Accepted publickey for <user> from <phone-ip>`. Surviving a lease change is a
stronger proof than switching networks, because the lease change is the exact
event that used to break it.

Two limits worth knowing. mDNS advertises **every** interface address, so a VPN
adapter shows up alongside the LAN one; it did not cause a misdial here, but it
is the first thing to test by disconnecting the VPN. And mDNS is same-network
only: corporate and guest Wi-Fi commonly block multicast and isolate clients, so
for a host that must be reachable from a different network the answer is an
overlay such as Tailscale, whose address never changes at all.

**Verify the topology before trusting it.** A device believed to be on the
laptop's hotspot was not: `Get-NetAdapter` showed the Wi-Fi radio
`Disconnected` and no `192.168.137.x` existed anywhere. Check the adapter state
on the Windows side before reasoning about routes.

**Worktree workspaces get meaningless names unless you name them.** `herdr
worktree create` accepts `--branch <NAME>` and `--label <TEXT>`. Without them it
invents `worktree-<word>-<word>-<hash>` and uses it for *both* the branch and the
workspace label, so the agents panel lists several entries that say nothing about
the work and each one has to be opened to identify it. Pass both flags.

For worktrees that already exist, `tools/herdr/herdr-worktree-labels` reads each
one's checked-out branch and relabels its workspace from it:

```bash
herdr-worktree-labels --dry-run    # show what would change
herdr-worktree-labels              # apply
herdr-worktree-labels --force      # also relabel ones renamed by hand
```

It records what it wrote to `~/.local/state/herdr-worktree-labels.json` and skips
any label it did not write, so a name chosen by hand survives. A branch herdr
generated itself (`worktree/brave-river-15c0`) is left alone, since deriving a
label from a meaningless branch gains nothing.

Labels are budgeted to 22 characters because **the agents panel truncates at
about 19**. That is why the repository prefix is dropped rather than the branch:
`ta-portal > feature/timecard-holiday` renders as `ta-portal > featur...`, which
is worse than the generated name it replaced.

**`codegraph install` leaves the MCP server unregistered.** It writes the
`UserPromptSubmit` hook and the `mcp__codegraph__*` permission into
`~/.claude/settings.json`, but registers the MCP server in *none* of the three
agents - so the allowlist points at tools that do not exist. Observed here after
it had already run four times. Always confirm afterwards:

```bash
claude mcp list          # expect: codegraph OK Connected
```

**The fnm PATH trap: never symlink an npm global shim.** `npm i -g` under fnm
lands in a version-scoped prefix reachable only through a per-PID multishell
directory under `/run/user/$UID/fnm_multishells/`. The tempting dismissal - "I
won't change Node versions, so this can't affect me" - is the wrong question:
shells on *other* versions already exist right now. Measured on this machine,
v16.14.0 and v24.14.1 were both installed, `codegraph` existed only under
v24.14.1, and 6 live multishells pointed at v16.14.0. Launching an agent from any
of those 6 breaks all three MCP registrations at once.

A symlink does not fix it, because the shim's shebang is `#!/usr/bin/env node`:

```
$ env -i PATH=/usr/bin:/bin ~/.local/bin/codegraph --version
1.6.0
$ env -i PATH=/usr/bin:/bin <the npm shim> --version
/usr/bin/env: 'node': No such file or directory
```

So `~/.local/bin/codegraph` is a **bash wrapper**, not a symlink. It resolves the
shim through the stable `fnm/aliases/default/bin` path and prepends that same
directory to `PATH` so the shebang always finds a Node. One wrapper on a stable
PATH entry fixes every agent at once and lets the MCP entries keep using the bare
name. `/run/user` is tmpfs, so multishell directories are recreated per shell on
every boot - the wrapper is what survives, never the multishell.

**Two Node API traps worth remembering.** `child_process.execFile` has **no**
`input` option - that is `execFileSync`. Pass `input` to `execFile` and the child
blocks on an unwritten stdin pipe until the timeout and returns empty stdout,
which here would have added a 2-second stall to every opencode startup. And
`TextPart` is **not** re-exported by `@opencode-ai/plugin`; its `index.d.ts` only
re-exports `./tool.js` plus type-only imports from `@opencode-ai/sdk`, so
importing it breaks plugin load.

**Installing one agent tool silently breaks another's hooks.** These tools all
write into the same per-agent files — `~/.claude/settings.json`,
`~/.codex/hooks.json`, the opencode plugins directory — and each rewrites the
hook arrays in its own shape. Nothing is deleted; the other tool simply stops
recognising its own entry and marks it `stale`. Nothing announces it.

Observed four times on this machine:

| What was installed | What it broke |
|---|---|
| `codegraph install` | wrote hooks and a permission entry, registered the MCP server nowhere |
| brew upgrading herdr to 0.9.0 | staled moshi's `claude` hooks — a week of lost notifications |
| `herdr integration install codex` | staled moshi's `codex` hook immediately |
| `herdr integration install pi` | staled moshi's `pi` hook, and the repair skipped it |

The second one is the expensive kind. A stale `Stop` entry means **no
notification when an agent finishes**, and the only trace is a WARN line in
`~/.local/state/moshi/hook.log`:

```
agent hooks missing or stale; rerun install target=claude missing="Stop entries outdated"
```

Two rules follow. **Order: herdr first, moshi last** — reinstalling moshi is the
only way to undo the staling, so it has to run after anything else that touches
those files. Restoration script 12 encodes exactly this, and restarts the daemon
afterwards because it reads the hook config only at startup.

The pi row is the one worth studying, because the repair existed and still
missed it. Script 12 kept two parallel lists of the same agents: pi was in the
herdr target list that *breaks* hooks and absent from the guard that *repairs*
them. It only bit when pi was the **only** stale agent — with any other agent
also stale the guard fired anyway and the bare `moshi-hook install` repaired pi
in passing, which is what kept it hidden. When a script holds two lists of the
same targets, the bug is one list drifting from the other; add an agent to both.

pi stales for a different reason than the rest, too. Its hooks are extension
*files* in `~/.pi/agent/extensions/`, not entries in a config: herdr creates
that directory for `herdr-agent-state.ts` and moshi's `moshi-hooks.ts` simply is
not there until `moshi-hook install --target pi` runs.

**And re-check after every install or upgrade**, including one you did not run
yourself, such as a `brew upgrade` that happened to bump herdr:

```bash
moshi-hook status | grep -E '^ +(claude|codex|opencode|pi) '   # want: current
herdr integration status                                       # want: current (vN)
```

Restoration scripts 10 and 12 are pinned by a regression suite, because every
failure in this section is silent:

```bash
./restoration_scripts/tests/agent-hooks-regression.sh     # want: 30 passed
```

**The moshi daemon runs with a PATH that cannot see Homebrew.**
`moshi-hook service install` writes `Environment=PATH=/usr/local/bin:/usr/bin:/bin`
into the systemd unit and regenerates it on every run. herdr lives under
linuxbrew, so the daemon reports it missing while an interactive shell finds it
perfectly:

```bash
moshi-hook status | grep herdr     # daemon:  herdr:   not found
moshi-hook context | grep kind     # client:  "kind": "herdr"
```

The client detecting herdr does not compensate: the **daemon** is what drives
the session from the phone. Restoration script 10 re-prepends the real
locations after every `service install`, discovering them with `command -v` so
it survives herdr moving. Committing a unit with the right PATH would not work —
`service install` overwrites it.

**A hand-replayed hook never notifies, so it cannot test notifications.** moshi
deduplicates agent-stop events per prompt sequence, so piping a `Stop` payload
into `moshi-hook claude-hook` for a turn that already finished is dropped in
silence. Only a real new turn is a valid test. To confirm the phone is reachable
at all, post to the account webhook as a control — it answers
`{"success":true,"pushSent":1}` and isolates any remaining fault to the hook
side rather than the device. Its token is a credential and this repository is
public, so it is not written down here; take it from the Moshi app.

The daemon runs without `-v` and logs almost nothing but the usage poller, so
that suppression is invisible until you ask for it:

```bash
systemctl --user stop moshi-hook
moshi-hook serve -v > /tmp/moshi.log 2>&1 &     # reproduce, then read the DEBUG lines
systemctl --user restart moshi-hook             # always put systemd back in charge
```

```
agent stop suppressed reason=already_completed promptSequence=2 completedPromptSequence=2
```

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

`gh`, `mosh` and `libpq` are declared for the same reason: each is a dependency
something else in the repo assumes is already there, and none of them shows up
as missing until the feature that needs it fails. `gh` because `git/config`
points the GitHub credential helper at its absolute path, so every push and
pull against GitHub fails without it. `mosh` because step 9.2 opens UDP
60000-61000 for it — an open port with no binary behind it does nothing.
`libpq` because it is keg-only and backs the Engram databases in `~/.pgpass`,
so `psql` never lands on PATH on its own. `shellcheck` is declared because it
is the linter these restoration scripts are checked against
(`shellcheck -S warning`); it is not a runtime dependency of anything else
here.

**Run the restoration tests after touching scripts 10 or 12.** They stub every
mutating command, so nothing on the machine changes:

```bash
./restoration_scripts/tests/agent-hooks-regression.sh
```

A suite that passes against the broken code proves nothing, so the load-bearing
case is deliberately narrow: pi stale while the other three are current. Verify
a new case the same way — make it fail on purpose before trusting it.

`~/.gentle-ai/state.json` is copied rather than symlinked, because gentle-ai
rewrites it atomically and would replace a symlink with a regular file. Re-export
it after changing settings in the TUI:

```bash
cp ~/.gentle-ai/state.json "$DOTFILES_PATH/os/linux/gentle-ai/state.json"
```
