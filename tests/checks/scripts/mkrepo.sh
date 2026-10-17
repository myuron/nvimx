# shellcheck shell=bash
# mkrepo <dir> [tag...]
mkrepo() {
  local d="$1"
  shift
  mkdir -p "$d"
  git init -q -b main "$d"
  git -C "$d" -c user.name=nvimx -c user.email=nvimx@example.com commit -q --allow-empty -m init
  for t in "$@"; do
    git -C "$d" -c user.name=nvimx -c user.email=nvimx@example.com tag -a "$t" -m "$t"
  done
}
