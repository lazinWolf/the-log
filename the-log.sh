# the-log — capture → append → timestamp → persist.
#
# Bash only. Source this file from ~/.bashrc (or symlink it into
# ~/.bashrc.d/ if your bashrc sources that directory):
#
#     source ~/Projects/the-log/the-log.sh
#
#   tlog <anything>     append an entry
#   tlog                open a prompt, type, press Enter
#   tlogs [filters]     read entries back (today by default)
#   tlogs --help        show all filters
#
# Piping in: the tlog alias starts with `set -f;`, which would end the
# pipe, so pipe into the function instead: `echo "..." | _the_log_write`.
#
# Entries live in one JSON Lines file, one entry per line:
#     {"ts":"2026-10-20T19:07:41+05:30","text":"bought new shoes"}
# Override the location with THE_LOG_FILE before sourcing.
# Nothing to install: plain bash, date and awk.

: "${THE_LOG_FILE:=$HOME/the-log.jsonl}"

# Re-sourcing is safe: drop old aliases before (re)defining anything.
unalias tlog tlogs 2>/dev/null

# ---------------------------------------------------------------- write ---

# ISO 8601 local time with offset, e.g. 2026-10-20T19:07:41+05:30.
# Built from %z so it works with both GNU (Linux) and BSD (macOS) date.
_the_log_ts() {
  local t
  t=$(date +%Y-%m-%dT%H:%M:%S%z)
  printf '%s:%s' "${t%??}" "${t#"${t%??}"}"
}

_the_log_write() {
  set +f  # undo the alias's glob guard
  local text="$*"
  if [ "$#" -eq 0 ]; then
    # No arguments: open a one-line prompt. Enter saves; an empty line,
    # Ctrl-C or Ctrl-D cancels. Nothing typed here is touched by the
    # shell, so apostrophes, quotes, * and ? all go in as-is.
    if [ -t 0 ]; then
      read -e -r -p 'tlog> ' text || { echo; return 1; }
    else
      IFS= read -r text || [ -n "$text" ] || return 1   # echo "..." | _the_log_write
    fi
  fi
  if [ -z "${text//[[:space:]]/}" ]; then
    [ "$#" -gt 0 ] && printf 'usage: tlog <anything>, or just: tlog\n' >&2
    return 1
  fi
  text=${text//\\/\\\\}      # \  ->  \\
  text=${text//\"/\\\"}      # "  ->  \"
  text=${text//$'\n'/\\n}    # newline
  text=${text//$'\r'/\\r}    # carriage return
  text=${text//$'\t'/\\t}    # tab
  printf '{"ts":"%s","text":"%s"}\n' "$(_the_log_ts)" "$text" >> "$THE_LOG_FILE"
}

# ----------------------------------------------------------------- read ---

_the_log_days_ago() {  # YYYY-MM-DD, $1 days before today
  date -d "-$1 days" +%Y-%m-%d 2>/dev/null || date -v-"$1"d +%Y-%m-%d
}

# Turns a word into a timestamp prefix, or fails if it isn't a date.
_the_log_when() {
  case $1 in
    today)     date +%Y-%m-%d ;;
    yesterday) _the_log_days_ago 1 ;;
    [1-9]d|[1-9][0-9]d|[1-9][0-9][0-9]d|[1-9][0-9][0-9][0-9]d)
               _the_log_days_ago $(( ${1%d} - 1 )) ;;
    [0-9][0-9][0-9][0-9] \
    | [0-9][0-9][0-9][0-9]-[0-9][0-9] \
    | [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] \
    | [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9] \
    | [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9])
               printf '%s\n' "$1" ;;
    *)         return 1 ;;
  esac
}

_the_log_help() {
  cat <<'EOF'
tlogs — read the-log

  tlogs                     today
  tlogs all                 everything
  tlogs yesterday           yesterday
  tlogs 7d                  the last 7 days (including today)
  tlogs 2026                a year      (any prefix of a timestamp works)
  tlogs 2026-10             a month
  tlogs 2026-10-20          a day
  tlogs 2026-10-20T19       an hour
  tlogs 2026-10-01..2026-10-15   a range, both ends included
  tlogs 2026-10..           from October onward
  tlogs 30d..yesterday      ranges accept today, yesterday and Nd too
  tlogs -20                 only the last 20 matching entries
  tlogs shoes               entries containing "shoes" (case-insensitive)
  tlogs /today              a leading / forces a search word (here: "today")
  tlogs 2026-10 shoes -5    filters combine

  --raw                    print matching lines as JSONL, for jq or scripts
EOF
}

_the_log_read() {
  local arg a b from="" to="" terms="" raw=0 last=0 empty
  local file=$THE_LOG_FILE nl=$'\n'

  if [ "$#" -eq 0 ]; then
    set -- today
    empty="Nothing logged today."
  else
    empty="No matching entries."
  fi

  for arg in "$@"; do
    case $arg in
      -h|--help) _the_log_help; return 0 ;;
      --raw)     raw=1 ;;
      -[0-9]*)   last=${arg#-}
                 case $last in *[!0-9]*) printf 'tlogs: bad count %s\n' "$arg" >&2; return 1 ;; esac ;;
      all)       from=""; to="" ;;
      /*)        terms="$terms${terms:+$nl}${arg#/}" ;;
      *..*)      a=${arg%%..*}; b=${arg#*..}
                 from=""; to=""
                 if [ -n "$a" ]; then from=$(_the_log_when "$a") || { printf 'tlogs: not a date: %s\n' "$a" >&2; return 1; }; fi
                 if [ -n "$b" ]; then to=$(_the_log_when "$b")   || { printf 'tlogs: not a date: %s\n' "$b" >&2; return 1; }; fi ;;
      [0-9]*d)   from=$(_the_log_when "$arg") || { printf 'tlogs: bad span %s\n' "$arg" >&2; return 1; }
                 to="" ;;
      *)         if a=$(_the_log_when "$arg"); then
                   from=$a; to=$a
                 else
                   terms="$terms${terms:+$nl}$arg"
                 fi ;;
    esac
  done

  if [ ! -s "$file" ]; then
    printf 'Nothing logged yet. Start with: tlog <anything>\n' >&2
    return 0
  fi

  local color=0 pager=0
  if [ -t 1 ] && [ "$raw" -eq 0 ]; then
    [ -z "${NO_COLOR-}" ] && color=1
    command -v less >/dev/null 2>&1 && pager=1
  fi

  _the_log_awk() {
    TL_FROM=$from TL_TO=$to TL_TERMS=$terms TL_RAW=$raw TL_LAST=$last \
    TL_COLOR=$color TL_EMPTY=$empty awk '
      function hexval(h,   i, v, c) {
        v = 0; h = tolower(h)
        for (i = 1; i <= length(h); i++) {
          c = index("0123456789abcdef", substr(h, i, 1))
          if (c == 0) return -1
          v = v * 16 + c - 1
        }
        return v
      }
      # Value of a JSON string field, unescaped. "" if missing.
      function jstr(s, key,   rest, out, c, p, v) {
        if (!match(s, "\"" key "\"[ \t]*:[ \t]*\"")) return ""
        rest = substr(s, RSTART + RLENGTH); out = ""
        while (match(rest, /["\\]/)) {
          out = out substr(rest, 1, RSTART - 1)
          c = substr(rest, RSTART, 1)
          if (c == "\"") return out
          c = substr(rest, RSTART + 1, 1)
          p = RSTART + 2
          if (c == "n") out = out "\n"
          else if (c == "t") out = out "\t"
          else if (c == "r" || c == "b" || c == "f") out = out
          else if (c == "u") {
            v = hexval(substr(rest, p, 4))
            if (v == 10) out = out "\n"
            else if (v >= 32 && v < 127) out = out sprintf("%c", v)
            else out = out "\\u" substr(rest, p, 4)
            p += 4
          }
          else out = out c
          rest = substr(rest, p)
        }
        return out rest
      }
      function weekday(y, m, d) {  # 0 = Sunday
        if (m < 3) y--
        return (y + int(y/4) - int(y/100) + int(y/400) + OFF[m] + d) % 7
      }
      BEGIN {
        from = ENVIRON["TL_FROM"]; to = ENVIRON["TL_TO"]
        nt = split(ENVIRON["TL_TERMS"], term, "\n")
        for (i = 1; i <= nt; i++) term[i] = tolower(term[i])
        raw = ENVIRON["TL_RAW"] + 0; last = ENVIRON["TL_LAST"] + 0
        color = ENVIRON["TL_COLOR"] + 0
        split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", MON, " ")
        split("Sun Mon Tue Wed Thu Fri Sat", DOW, " ")
        split("0 3 2 5 0 3 5 1 4 6 2 4", OFF, " ")
        B = color ? "\033[1m" : ""; D = color ? "\033[2m" : ""; R = color ? "\033[0m" : ""
      }
      {
        ts = jstr($0, "ts")
        if (ts == "") next
        if (from != "" && ts < from) next
        if (to != "" && substr(ts, 1, length(to)) > to) next
        text = jstr($0, "text")
        if (nt) {
          lt = tolower(text)
          for (i = 1; i <= nt; i++) if (index(lt, term[i]) == 0) next
        }
        n++; TS[n] = ts; TX[n] = text; LINE[n] = $0
      }
      END {
        if (n == 0) { print ENVIRON["TL_EMPTY"] > "/dev/stderr"; exit }
        start = (last && n > last) ? n - last + 1 : 1
        for (k = start; k <= n; k++) {
          if (raw) { print LINE[k]; continue }
          day = substr(TS[k], 1, 10)
          if (day != prev) {
            if (prev != "") print ""
            y = substr(day, 1, 4) + 0; m = substr(day, 6, 2) + 0; d = substr(day, 9, 2) + 0
            printf "%s%s %d %s %d%s\n", B, DOW[weekday(y, m, d) + 1], d, MON[m], y, R
            prev = day
          }
          text = TX[k]
          gsub(/\n/, "\n         ", text)
          printf "  %s%s%s  %s\n", D, substr(TS[k], 12, 5), R, text
        }
      }' "$file"
  }

  if [ "$pager" -eq 1 ]; then
    _the_log_awk | less -FRX
  else
    _the_log_awk
  fi
}

# ------------------------------------------------------------- commands ---

# tlog switches off filename expansion for the words that follow, so
# `tlog did I lock the door?` and `tlog *sigh*` are saved as typed.
# Not usable after a pipe: `x | set -f; ...` ends the pipe at set -f.
alias tlog='set -f; _the_log_write'
# No guard here: in `tlogs --raw | jq` the function runs in a subshell,
# so its set +f would never reach this shell and globbing would stay off.
alias tlogs='_the_log_read'
