#!/usr/bin/env bash
# Start an ssh-agent for this shell and load whichever keys exist.
#
# Usually unnecessary: ~/.ssh/config sets AddKeysToAgent yes, so keys load on
# first use. This is here for shells where no agent is running at all.

if [ -z "${SSH_AUTH_SOCK:-}" ]; then
	eval "$(ssh-agent -s)"
fi

for key in "$HOME/.ssh/github-hlclarog" "$HOME/.ssh/bit-hclaro"; do
	[ -f "$key" ] && ssh-add "$key"
done
