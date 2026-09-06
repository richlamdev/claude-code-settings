#!/bin/sh
# Claude Code status line -- one line, no machine- or user-specific content.
#
#   <session> <TICKET|branch><drift> <PR> <cwd> <wt> <model> <ctx%> <cost> [<effort>]
#
# Most fields are conditional: they render only when they have something to say,
# so a clean tree on a plain branch with no cloud context costs no width.
#
# Claude Code renders its own mode indicator (auto / plan / accept edits) on the
# line below this one; that footer is not configurable, so this stays to one line.
#
# Every field is optional: whatever the harness omits is simply not drawn, so
# this renders correctly on any machine, any account, any project.
#
# Requires: jq, git (both optional -- degrades rather than erroring).
# Tune the thresholds without editing this file by exporting any of the
# CC_STATUSLINE_* variables below.
#
# Runs on every redraw, so it is written to fork as little as possible:
# one jq, one git, and no command substitution for the colour fragments.

input=$(cat)

# ESC once, then colours are plain string concatenation instead of $(printf).
ESC=$(printf '\033')
US=$(printf '\037') # field separator for the jq output; see the note below
C_NAME="${ESC}[35m" C_BRANCH="${ESC}[32m" C_CWD="${ESC}[33m"
C_TICKET="${ESC}[1;32m"
C_MODEL="${ESC}[36m" C_EFFORT="${ESC}[90m" C_OFF="${ESC}[0m"
C_DIRTY="${ESC}[33m" C_WT="${ESC}[95m"

# One jq call for every field. Joined on 0x1f (unit separator) rather than tab:
# tab counts as IFS whitespace, so `read` would collapse runs of it and a null
# field would silently shift every later value one slot to the left.
if command -v jq >/dev/null 2>&1; then
  fields=$(printf '%s' "$input" | jq -j '
    [ .cwd, .session_name, .model.display_name,
      .context_window.used_percentage, .cost.total_cost_usd, .effort.level,
      .pr.number, .pr.review_state, .pr.kind, .workspace.git_worktree ]
    | map(if . == null then "" else tostring end) | join("\u001f")' 2>/dev/null)
  IFS="$US" read -r cwd session_name model ctx_used cost_usd effort \
    pr_num pr_state pr_kind worktree <<EOF
$fields
EOF
fi
[ -n "$cwd" ] || cwd=$PWD

# Branch, ahead/behind and dirty state all come from one git call.
git_branch=""
ahead=""
behind=""
dirty=""
if git_out=$(git -C "$cwd" --no-optional-locks status --porcelain=v2 --branch 2>/dev/null); then
  while IFS= read -r _ln; do
    case "$_ln" in
      '# branch.head '*) git_branch=${_ln#\# branch.head } ;;
      '# branch.ab '*)
        _ab=${_ln#\# branch.ab }
        ahead=${_ab%% *}
        ahead=${ahead#+}
        behind=${_ab#* }
        behind=${behind#-}
        ;;
      '1 '* | '2 '* | 'u '* | '?'*) dirty="*" ;;
    esac
  done <<EOF
$git_out
EOF
fi
[ "$git_branch" = "(detached)" ] && git_branch="detached"

ticket=""
if [ -n "$git_branch" ]; then
  _b=${git_branch##*/} # drop any owner/ prefix
  _tp=${_b%%-*}        # leading letters
  _rest=${_b#*-}       # digits, then the description
  _tn=${_rest%%-*}     # following digits
  case "$_tp" in '' | *[!A-Za-z]*) _tp="" ;; esac
  case "$_tn" in '' | *[!0-9]*) _tn="" ;; esac
  # Require a description after the number, so release-2026 or v2-1 are not
  # mistaken for issue keys.
  [ "$_rest" = "$_tn" ] && _tn=""
  if [ -n "$_tp" ] && [ -n "$_tn" ]; then
    ticket="$(printf '%s' "$_tp" | tr '[:lower:]' '[:upper:]')-$_tn"
  fi
fi

# Thresholds: green below yellow, yellow up to red, red at/above.
CTX_YELLOW=${CC_STATUSLINE_CTX_YELLOW:-50}
CTX_RED=${CC_STATUSLINE_CTX_RED:-80}
COST_YELLOW=${CC_STATUSLINE_COST_YELLOW:-5} # USD - tune to taste
COST_RED=${CC_STATUSLINE_COST_RED:-20}
# Deliberately no AWS/cluster field here. Every field below is recomputed on
# each render, so none of them can go stale; an environment name taken from the
# launch-time env would be a frozen snapshot wearing the same authority, and it
# drifts the moment a kube context is switched. Confirm the account directly
# rather than trusting a badge.

# Ahead/behind/dirty markers: nothing renders when the tree is clean and synced.
drift=""
[ -n "$ahead" ] && [ "$ahead" != "0" ] && drift="${drift}^${ahead}"
[ -n "$behind" ] && [ "$behind" != "0" ] && drift="${drift}v${behind}"
drift="${drift}${dirty}"
# Pre-wrap it so a clean tree emits no colour codes at all.
drift_part=""
[ -n "$drift" ] && drift_part="${C_DIRTY}${drift}${C_OFF}"

# Match zsh's %~: collapse $HOME to ~ so the line never prints a home path
# (and so it stays the same width whoever runs it).
case "$cwd" in
  "$HOME") disp_cwd="~" ;;
  "$HOME"/*) disp_cwd="~${cwd#"$HOME"}" ;;
  *) disp_cwd="$cwd" ;;
esac
[ -n "$HOME" ] || disp_cwd="$cwd"

left=""
[ -n "$session_name" ] && left="${left}${C_NAME}${session_name}${C_OFF} "
if [ -n "$ticket" ] && [ "$ticket" = "$session_name" ]; then
  # Session already named after this ticket -- do not print it twice, but the
  # drift markers still belong on the line, attached to the name rather than
  # floating as a separate field.
  [ -n "$drift" ] && left="${left% }${drift_part} "
elif [ -n "$ticket" ]; then
  left="${left}${C_TICKET}${ticket}${C_OFF}${drift_part} "
elif [ -n "$git_branch" ]; then
  left="${left}${C_BRANCH}|${git_branch}${C_OFF}${drift_part} "
fi

# PR / MR on this branch, coloured by what it wants from you.
if [ -n "$pr_num" ]; then
  case "$pr_state" in
    approved) pr_color=32 ;;
    changes_requested) pr_color=31 ;;
    draft) pr_color=90 ;;
    *) pr_color=33 ;;
  esac
  if [ "$pr_kind" = "mr" ]; then pr_sigil="!"; else pr_sigil="#"; fi
  left="${left}${ESC}[${pr_color}m${pr_sigil}${pr_num}${C_OFF} "
fi

left="${left}${C_CWD}${disp_cwd}${C_OFF}"
[ -n "$worktree" ] && left="${left} ${C_WT}wt:${worktree}${C_OFF}"

right=""
[ -n "$model" ] && right="${right} ${C_MODEL}${model}${C_OFF}"

if [ -n "$ctx_used" ]; then
  # Round half-up without forking printf: split on the decimal point.
  ctx_int=${ctx_used%%.*}
  case "$ctx_used" in
    *.[5-9]*) ctx_int=$((ctx_int + 1)) ;;
  esac
  case "$ctx_int" in
    '' | *[!0-9]*) ctx_int="" ;;
  esac
  if [ -n "$ctx_int" ]; then
    if [ "$ctx_int" -ge "$CTX_RED" ]; then
      ctx_color=31
    elif [ "$ctx_int" -ge "$CTX_YELLOW" ]; then
      ctx_color=33
    else
      ctx_color=32
    fi
    right="${right} ${ESC}[${ctx_color}m${ctx_int}%${C_OFF}"
  fi
fi

if [ -n "$cost_usd" ]; then
  # Truncate, do not round: $4.99 must stay under a $5 threshold.
  cost_int=${cost_usd%%.*}
  case "$cost_int" in '' | *[!0-9]*) cost_int=0 ;; esac
  if [ "$cost_int" -ge "$COST_RED" ]; then
    cost_color=31
  elif [ "$cost_int" -ge "$COST_YELLOW" ]; then
    cost_color=33
  else
    cost_color=92
  fi
  # Two decimals, still no fork: pad the fractional part to width 2.
  cost_frac="00"
  case "$cost_usd" in *.*) cost_frac="${cost_usd#*.}00" ;; esac
  cost_frac=${cost_frac%"${cost_frac#??}"} # keep the first two digits
  right="${right} ${ESC}[${cost_color}m\$${cost_int}.${cost_frac}${C_OFF}"
fi

[ -n "$effort" ] && right="${right} ${C_EFFORT}[${effort}]${C_OFF}"

printf '%s%s' "$left" "$right"
