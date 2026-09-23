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

### Restore the Pi OpenAI model profile (optional, manual)

From the dotfiles checkout, run this **only if you want** the saved 26-role
`open-ai-full.autogen` mapping in Pi:

```bash
cd "$HOME/.dotfiles"
./scripts/restore-pi-openai-profile
```

This command is not part of `dot self install` or `gentle-ai`. On a new Pi
registry it creates the profile and makes it active; on an existing registry it
adds only the missing profile, **never changes the active selection**, and
returns without writing when the profile already matches. By default, it
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

`--host "$(hostname).local"` ends it. Proven here: paired at `192.168.1.24`,
then DHCP moved the host to `192.168.1.21` (and the OpenVPN adapter from
`10.237.89.2` to `.7`) and the phone kept connecting —
`Accepted publickey for hclaro from 192.168.1.3`. Surviving a lease change is a
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
./restoration_scripts/tests/agent-hooks-regression.sh     # want: 9 passed
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
so `psql` never lands on PATH on its own.

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
