#!/usr/bin/env bash
# Run after 08-pi.sh, before 09-gentle-ai-sync.sh. Safe to repeat on older VMs.
# Preserve Dotly's stdin list of remaining restoration scripts.
exec </dev/null
if ! command -v fnm >/dev/null 2>&1; then
    printf ' > Gentle Shell skipped: restore Node and Pi first (07-node.sh, 08-pi.sh)\n'
    return 0
fi
fnm exec --using=default bash "$DOTFILES_PATH/scripts/restore-gentle-shell" </dev/null
