# shellcheck shell=bash
# bash completion for macelium, which the formula installs into Homebrew's
# etc/bash_completion.d. tests/test_cli.sh checks it offers every command and
# option macelium --help lists.

# Takes the words to offer, and sets COMPREPLY to those the current word
# starts.
_macelium_offer() {
  local word
  COMPREPLY=()
  while IFS= read -r word; do
    COMPREPLY+=("$word")
  done < <(compgen -W "$1" -- "${COMP_WORDS[COMP_CWORD]}")
}

# Takes -d for directories or -f for files, and sets COMPREPLY to the paths
# the current word starts.
_macelium_paths() {
  local path
  COMPREPLY=()
  while IFS= read -r path; do
    COMPREPLY+=("$path")
  done < <(compgen "$1" -- "${COMP_WORDS[COMP_CWORD]}")
}

_macelium() {
  local commands='init bootstrap plan apply settings help'
  local current=${COMP_WORDS[COMP_CWORD]} previous=${COMP_WORDS[COMP_CWORD - 1]}
  if ((COMP_CWORD == 1)); then
    _macelium_offer "$commands -h --help -V --version"
    return
  fi
  case ${COMP_WORDS[1]} in
    init)
      if [[ $current == -* ]]; then _macelium_offer '--public -h --help'; else _macelium_paths -d; fi
      ;;
    bootstrap)
      if [[ $current == -* ]]; then _macelium_offer '-h --help'; else _macelium_paths -d; fi
      ;;
    plan) _macelium_offer '--notify -h --help' ;;
    apply) _macelium_offer '-h --help' ;;
    settings)
      if [[ $previous == --file ]]; then _macelium_paths -f; else _macelium_offer '--file -h --help'; fi
      ;;
    help) if ((COMP_CWORD == 2)); then _macelium_offer "$commands"; fi ;;
  esac
}

complete -o filenames -F _macelium macelium
