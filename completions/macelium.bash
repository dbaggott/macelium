# shellcheck shell=bash
# bash completion for macelium, which the formula installs into Homebrew's
# etc/bash_completion.d. tests/test_cli.sh checks it offers every command and
# option macelium --help lists.

# Takes compgen's options, and sets COMPREPLY to what compgen offers for the
# current word: -W and the words, -d for directories or -f for files.
_macelium_compgen() {
  local reply
  COMPREPLY=()
  while IFS= read -r reply; do
    COMPREPLY+=("$reply")
  done < <(compgen "$@" -- "${COMP_WORDS[COMP_CWORD]}")
}

_macelium() {
  local commands='init bootstrap plan apply settings help'
  local current=${COMP_WORDS[COMP_CWORD]} previous=${COMP_WORDS[COMP_CWORD - 1]}
  if ((COMP_CWORD == 1)); then
    _macelium_compgen -W "$commands -h --help -V --version"
    return
  fi
  case ${COMP_WORDS[1]} in
    init)
      if [[ $current == -* ]]; then _macelium_compgen -W '--public -h --help'; else _macelium_compgen -d; fi
      ;;
    bootstrap)
      if [[ $current == -* ]]; then _macelium_compgen -W '-h --help'; else _macelium_compgen -d; fi
      ;;
    plan) _macelium_compgen -W '--notify -h --help' ;;
    apply) _macelium_compgen -W '-h --help' ;;
    settings)
      if [[ $previous == --file ]]; then _macelium_compgen -f; else _macelium_compgen -W '--file -h --help'; fi
      ;;
    help) if ((COMP_CWORD == 2)); then _macelium_compgen -W "$commands"; fi ;;
  esac
}

complete -o filenames -F _macelium macelium
