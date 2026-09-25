#!/usr/bin/env bash
# Install Rust (rustup, stable, default profile) to match the reference
# machine: ~/.rustup and ~/.cargo carry cargo, clippy, rust-docs, rust-std,
# rustc and rustfmt for stable-x86_64-unknown-linux-gnu.
#
# WHY --no-modify-path: rustup would otherwise append a PATH line to
# ~/.zshenv, ~/.bashrc and ~/.profile -- but shell/zsh/.zshenv and
# shell/bash/.bashrc are symlinks into this repository (they already source
# ~/.cargo/env, and shell/exports.sh already puts ~/.cargo/bin on PATH), so an
# unmanaged rustup install would mutate tracked files instead of relying on
# the sourcing this repository already does.
#
# ORDER-INDEPENDENT: unlike 07-node.sh/08-pi.sh, nothing here needs fnm or any
# other restoration script first -- it only needs curl. About 1.5 GB
# downloaded.
#
# Sourced by `dot self install`, so it uses return rather than exit.

# Dotly feeds the list of remaining restoration scripts to its loop on stdin;
# anything here that reads stdin (brew, installers) would swallow that list
# and silently skip every later script. sudo prompts use /dev/tty, not stdin.
exec </dev/null

if [ -x "$HOME/.cargo/bin/rustup" ]; then
	echo " > Rust already installed (rustup)"
	return 0
fi

rust_tmp=$(mktemp)
if curl --proto '=https' --tlsv1.2 -sSf "${RUSTUP_INIT_URL:-https://sh.rustup.rs}" -o "$rust_tmp"; then
	sh "$rust_tmp" -y --no-modify-path --profile default </dev/null
fi
rm -f "$rust_tmp"
unset rust_tmp

if [ -x "$HOME/.cargo/bin/rustup" ]; then
	echo " > Rust installed (rustup, stable, default profile)"
else
	echo " > Rust install failed; rerun: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile default"
fi

return 0
