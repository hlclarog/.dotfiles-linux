submodule="modules/zimfw"
cd "$DOTFILES_PATH"
git submodule deinit -f -- "$submodule"
git rm -f "$submodule"
git commit -m "Removed submodule '$submodule'"
rm -rf ".git/modules/${submodule}"
echo "Submodule '${submodule}' uninstalled"