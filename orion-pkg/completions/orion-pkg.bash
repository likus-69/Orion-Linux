# Bash completion for orion-pkg
# Install to /usr/share/bash-completion/completions/orion-pkg

_orion_pkg_completion() {
  local cur prev words cword
  _init_completion || return

  local cmds=(build install remove list info search update upgrade verify which help)
  if (( cword == 1 )); then
    COMPREPLY=( $(compgen -W "${cmds[*]}" -- "$cur") )
    return
  fi

  case "${words[1]}" in
    install|search|remove|info|verify)
      # Suggest package names from $ORION_REPO
      local repo="${ORION_REPO:-/etc/orion/repo.d}"
      local pkgs
      pkgs=$(ls -1 "$repo" 2>/dev/null | head -200)
      COMPREPLY=( $(compgen -W "$pkgs" -- "$cur") )
      ;;
    list)
      COMPREPLY=( $(compgen -W "--all -a" -- "$cur") )
      ;;
    *)
      ;;
  esac
}
complete -F _orion_pkg_completion orion-pkg
