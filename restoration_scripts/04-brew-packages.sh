#!/usr/bin/env bash
# Install this machine's Brewfile before scripts 07/11/13/14 need jq/fnm.
#
# `dot self install` sources restoration_scripts/*.sh in `sort` order, each
# in its own subshell (`. "$script" | log::file ...`), BEFORE the restorer's
# own `dot package import` (see modules/dotly/restorer). That import also
# throws away all its output and always reports success regardless of the
# real exit status (`dot package import >/dev/null 2>&1 | _log ...`). So
# scripts 14 (jq), 07 (fnm), 11 (codegraph, via fnm) and 13 (engram) used to
# run before their packages existed, and a failed import looked identical to
# a working one. This script (04, sorting before all of them) installs the
# Brewfile itself instead of waiting for that later, silent import.
#
# Homebrew 7.0.6 has a Linux bug on top of that: `brew bundle install`
# aborts the ENTIRE run on the first untrusted third-party cask, even when
# the Brewfile already marks the entry `trusted: true`. Backtrace:
# bundle/installer.rb:66 Skipper.skip? -> extend/os/linux/bundle/skipper.rb:16
# requires_macos? -> Cask::CaskLoader.load -> trust.rb raise_untrusted! --
# all of that runs before installer.rb:81 ever applies the Brewfile's
# `trusted:` options. Running `brew trust` for every trusted entry before
# `brew bundle install` works around it.
#
# MEASURED ON A FRESH UBUNTU VM RESTORE: `brew bundle install` reads stdin
# under the hood, through one of its cask/formula installers, and `dot self
# install` feeds it the list of restoration scripts still queued on stdin
# (modules/dotly/scripts/self/install:46-52). That swallowed the rest of the
# list: scripts 05 through 17 never ran, `brew bundle install` itself
# stopped partway through with the openai cask and engram missing, and `dot
# self install` still printed "dotfiles restored" anyway. Rerunning this
# script by hand with stdin redirected to /dev/null completed correctly in
# 19 seconds. Earlier restores did not show this because the packages were
# already installed, so brew bundle never had anything left to read.
#
# Sourced by `dot self install`, so it uses return rather than exit.

# Dotly feeds the list of remaining restoration scripts to its loop on stdin;
# anything here that reads stdin (brew, installers) would swallow that list
# and silently skip every later script. sudo prompts use /dev/tty, not stdin.
exec </dev/null

brew_bin=""
if command -v brew >/dev/null 2>&1; then
	brew_bin="$(command -v brew)"
else
	for brew_candidate in ${BREW_CANDIDATES:-/home/linuxbrew/.linuxbrew/bin/brew /opt/homebrew/bin/brew /usr/local/bin/brew}; do
		if [ -x "$brew_candidate" ]; then
			brew_bin="$brew_candidate"
			break
		fi
	done
	unset brew_candidate
fi

if [ -z "$brew_bin" ]; then
	echo " > Homebrew is not installed, skipping packages (see doc/INSTALL.md step 3)"
	unset brew_bin
	return 0
fi

# So `brew bundle install` and its bundle subprocesses see the brew prefix.
eval "$("$brew_bin" shellenv)"

case "$(uname -s)" in
Linux) brewfile="$DOTFILES_PATH/os/linux/brew/Brewfile" ;;
Darwin) brewfile="$DOTFILES_PATH/os/mac/brew/Brewfile" ;;
*) brewfile="" ;;
esac

if [ -z "$brewfile" ] || [ ! -f "$brewfile" ] || ! grep -qE '^(brew|cask|tap) ' "$brewfile"; then
	echo " > No Brewfile packages declared for this platform, skipping"
	unset brew_bin brewfile
	return 0
fi

brewfile_body=$(grep -v '^[[:space:]]*#' "$brewfile")

# A fresh machine has no taps yet, so every declared tap is added first,
# regardless of whether it also needs trusting below.
while IFS= read -r tap_line; do
	[ -z "$tap_line" ] && continue
	tap_name=$(printf '%s\n' "$tap_line" | sed -E 's/^tap "([^"]+)".*/\1/')
	tap_url=$(printf '%s\n' "$tap_line" | sed -En 's/^tap "[^"]+", *"([^"]+)".*/\1/p')
	if [ -n "$tap_url" ]; then
		"$brew_bin" tap "$tap_name" "$tap_url"
	else
		"$brew_bin" tap "$tap_name"
	fi
done < <(printf '%s\n' "$brewfile_body" | grep -E '^tap "')
unset tap_line tap_name tap_url

mapfile -t trusted_taps < <(printf '%s\n' "$brewfile_body" | grep -E '^tap "[^"]+".*trusted: *true' | sed -E 's/^tap "([^"]+)".*/\1/')
mapfile -t trusted_formulas < <(printf '%s\n' "$brewfile_body" | grep -E '^brew "[^"]+".*trusted: *true' | sed -E 's/^brew "([^"]+)".*/\1/')
mapfile -t trusted_casks < <(printf '%s\n' "$brewfile_body" | grep -E '^cask "[^"]+".*trusted: *true' | sed -E 's/^cask "([^"]+)".*/\1/')

[ "${#trusted_taps[@]}" -gt 0 ] && "$brew_bin" trust --tap "${trusted_taps[@]}"
[ "${#trusted_formulas[@]}" -gt 0 ] && "$brew_bin" trust --formula "${trusted_formulas[@]}"
[ "${#trusted_casks[@]}" -gt 0 ] && "$brew_bin" trust --cask "${trusted_casks[@]}"

# --no-upgrade: `dot self install` is also rerun on machines that are already
# set up, and a restore only needs what is missing. Without it every rerun
# would silently upgrade every outdated package in the Brewfile.
if "$brew_bin" bundle install --no-upgrade --file="$brewfile"; then
	echo " > Brewfile packages installed"
else
	brew_bundle_status=$?
	echo " > brew bundle install failed (exit $brew_bundle_status); see ~/dotly.log and rerun: brew bundle install --no-upgrade --file=$brewfile"
	unset brew_bundle_status
fi

unset brew_bin brewfile brewfile_body trusted_taps trusted_formulas trusted_casks
return 0
