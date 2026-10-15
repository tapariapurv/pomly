#!/bin/zsh
# Merge finished agent worktrees into main, then remove them.
# Done = clean tree, no non-shell process inside, idle >= IDLE_MIN minutes.
# Prints one line per worktree; silent when there is nothing to do.
set -u
cd "$(dirname $0)/.." || exit 1
IDLE_MIN=${IDLE_MIN:-10}
MAIN=$PWD
now=$(date +%s)

[[ $(git branch --show-current) == main ]] || { echo "SKIP: main repo not on main"; exit 0; }
[[ -z $(git status --porcelain -uno) ]] || { echo "SKIP: main repo has uncommitted changes"; exit 0; }
busy=$(lsof -d cwd 2>/dev/null | awk '$1!~/^(zsh|bash|sh|fish)$/{print $NF}')

git worktree list --porcelain | awk '/^worktree /{p=$2} /^branch /{sub("refs/heads/","",$2); if (p!=m) print p, $2}' m="$MAIN" |
while read wt br; do
  [[ -d $wt ]] || { git worktree prune; continue; }
  if print -r -- "$busy" | grep -qF "$wt"; then echo "BUSY: $br (agent running)"; continue; fi
  if [[ -n $(git -C $wt status --porcelain) ]]; then echo "WIP: $br (uncommitted changes)"; continue; fi
  last=$(git log -1 --format=%ct $br)
  newest=$(find $wt -type f -not -path '*/.git*' -not -path '*/build.noindex/*' -mmin -${IDLE_MIN} -print -quit 2>/dev/null)
  if [[ -n $newest ]] || (( now - last < IDLE_MIN*60 )); then echo "RECENT: $br (active < ${IDLE_MIN}m)"; continue; fi
  ahead=$(git rev-list --count main..$br)
  if (( ahead == 0 )); then
    # Never committed (reflog has only the creation entry) = not started; leave it.
    (( $(git reflog show --format=%h $br 2>/dev/null | wc -l) > 1 )) || continue
  else
    if ! git -C $wt rebase -q main >/dev/null 2>&1; then
      git -C $wt rebase --abort 2>/dev/null
      echo "CONFLICT: $br at $wt (rebase onto main failed, left untouched)"; continue
    fi
    git merge -q --ff-only $br || { echo "FAIL: ff-merge $br"; continue; }
  fi
  git worktree remove --force $wt && git branch -q -D $br && echo "MERGED: $br (+$ahead commits)"
done
git worktree prune
