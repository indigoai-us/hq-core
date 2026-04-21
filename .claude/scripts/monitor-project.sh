#!/usr/bin/env bash
# monitor-project.sh — single-project dashboard for run-project.sh orchestrator
#
# Reads workspace/orchestrator/{project}/{state.json,executions/*.json,progress.txt}
# and renders an HQ/{company}-branded TUI widget.
#
# Usage:
#   monitor-project.sh <project>              # one-shot render
#   monitor-project.sh <project> --watch      # live dashboard (default 5s)
#   monitor-project.sh <project> -w -i 2      # custom interval
#   monitor-project.sh <project> --plain      # no colors / no box chars
set -euo pipefail

HQ_ROOT="${HQ_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ORCH_DIR="${ORCH_DIR:-$HQ_ROOT/workspace/orchestrator}"

# ---------- arg parse ----------
PROJECT=""
WATCH=0
INTERVAL=5
PLAIN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--watch)    WATCH=1; shift ;;
    -i|--interval) INTERVAL="$2"; shift 2 ;;
    --plain)       PLAIN=1; shift ;;
    -h|--help)
      sed -n '2,15p' "$0"; exit 0 ;;
    -*)
      echo "unknown flag: $1" >&2; exit 2 ;;
    *)
      PROJECT="$1"; shift ;;
  esac
done

[[ -z "$PROJECT" ]] && { echo "usage: monitor-project.sh <project> [-w] [-i N] [--plain]" >&2; exit 2; }

STATE_FILE="$ORCH_DIR/$PROJECT/state.json"
EXEC_DIR="$ORCH_DIR/$PROJECT/executions"
PROGRESS_FILE="$ORCH_DIR/$PROJECT/progress.txt"

[[ -f "$STATE_FILE" ]] || { echo "no state.json for project '$PROJECT' at $STATE_FILE" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

# ---------- presentation helpers ----------
if [[ $PLAIN -eq 1 ]] || [[ ! -t 1 && $WATCH -eq 0 ]]; then
  C_RESET=""; C_DIM=""; C_BOLD=""
  C_FG=""; C_TEXT=""; C_MUTED=""; C_SUBTLE=""
  C_OK=""; C_WARN=""; C_ERR=""; C_LIVE=""
  TL="+"; TR="+"; BL="+"; BR="+"; HZ="-"; VT="|"; LT="+"; RT="+"
  BLK_FULL="#"; BLK_EMPTY="."
  GLYPH_OK="v"; GLYPH_RUN="*"; GLYPH_WAIT="o"; GLYPH_FAIL="x"
  BANNER_MODE="plain"
elif [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" ]]; then
  # {company} Midnight (24-bit) — sourced from .claude/skills/ascii-graphic/SKILL.md
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_FG=$'\033[38;2;123;155;199m'        # #7B9BC7 faded {company} — primary
  C_TEXT=$'\033[38;2;200;210;224m'      # #C8D2E0 — readable body text
  C_MUTED=$'\033[38;2;155;165;184m'     # #9BA5B8 — readable labels (bumped from #5A6270)
  C_SUBTLE=$'\033[38;2;61;67;76m'       # #3D434C — borders only (meant to recede)
  C_OK=$'\033[38;2;143;188;143m'        # Forest accent — success
  C_WARN=$'\033[38;2;196;148;100m'      # Ember accent — warning
  C_ERR=$'\033[38;2;220;90;90m'         # muted red — failure
  C_LIVE=$'\033[38;2;180;210;240m'      # brighter {company} — active pulse
  TL="╭"; TR="╮"; BL="╰"; BR="╯"; HZ="─"; VT="│"; LT="├"; RT="┤"
  BLK_FULL="█"; BLK_EMPTY="·"
  GLYPH_OK="✓"; GLYPH_RUN="●"; GLYPH_WAIT="◌"; GLYPH_FAIL="✗"
  BANNER_MODE="unicode"
else
  # 256-color fallback (xterm-256)
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_FG=$'\033[38;5;110m'                # nearest to #7B9BC7
  C_TEXT=$'\033[38;5;252m'              # bright grey body text
  C_MUTED=$'\033[38;5;246m'             # readable mid-grey labels (bumped from 242)
  C_SUBTLE=$'\033[38;5;238m'            # dim borders only
  C_OK=$'\033[38;5;108m'
  C_WARN=$'\033[38;5;173m'
  C_ERR=$'\033[38;5;167m'
  C_LIVE=$'\033[38;5;153m'
  TL="╭"; TR="╮"; BL="╰"; BR="╯"; HZ="─"; VT="│"; LT="├"; RT="┤"
  BLK_FULL="█"; BLK_EMPTY="·"
  GLYPH_OK="✓"; GLYPH_RUN="●"; GLYPH_WAIT="◌"; GLYPH_FAIL="✗"
  BANNER_MODE="unicode"
fi

WIDTH=72
INNER=$((WIDTH - 2))

# ---------- HQ block banner (ANSI Shadow, 6 rows) ----------
# Sourced from .claude/skills/ascii-graphic/SKILL.md lines 148-154 (H) + 220-226 (Q).
# Each row is H-glyph + 1 space + Q-glyph. Widths: 17–18 chars per row.
BANNER_ROWS=(
  "██╗  ██╗  ██████╗ "
  "██║  ██║ ██╔═══██╗"
  "███████║ ██║   ██║"
  "██╔══██║ ██║▄▄ ██║"
  "██║  ██║ ╚██████╔╝"
  "╚═╝  ╚═╝  ╚══▀▀═╝ "
)

# ---------- helpers ----------
iso_to_epoch() {
  local iso="$1"
  [[ -z "$iso" || "$iso" == "null" ]] && { echo 0; return; }
  date -juf "%Y-%m-%dT%H:%M:%S" "${iso%Z}" "+%s" 2>/dev/null || echo 0
}

human_duration() {
  local sec="$1"
  [[ -z "$sec" || "$sec" -le 0 ]] && { echo "—"; return; }
  local h=$(( sec / 3600 ))
  local m=$(( (sec % 3600) / 60 ))
  local s=$(( sec % 60 ))
  if   (( h > 0 )); then printf "%dh%02dm" "$h" "$m"
  elif (( m > 0 )); then printf "%dm%02ds" "$m" "$s"
  else                   printf "%ds" "$s"
  fi
}

progress_bar() {
  local done="$1" total="$2" width="$3"
  (( total <= 0 )) && total=1
  local filled=$(( done * width / total ))
  (( filled > width )) && filled=$width
  local empty=$(( width - filled ))
  local bar=""
  while (( filled-- > 0 )); do bar+="$BLK_FULL"; done
  while (( empty-- > 0 )); do bar+="$BLK_EMPTY"; done
  printf "%s" "$bar"
}

# visible width of a string (strips ANSI + counts characters, not bytes)
visible_width() {
  local n
  n=$(LC_ALL=en_US.UTF-8 printf "%s" "$1" | sed -E $'s/\033\\[[0-9;]*m//g' | LC_ALL=en_US.UTF-8 wc -m)
  printf "%d" "$(( n + 0 ))"
}

# print a row inside the box: │ <text padded to INNER> │
row() {
  local text="$1"
  local vlen
  vlen=$(visible_width "$text")
  local pad=$(( INNER - vlen - 2 ))
  (( pad < 0 )) && pad=0
  printf "%s%s%s %s%*s %s%s%s\n" "$C_SUBTLE" "$VT" "$C_RESET" "$text" "$pad" "" "$C_SUBTLE" "$VT" "$C_RESET"
}

hrule() {
  local ch="$1" left="$2" right="$3"
  printf "%s%s" "$C_SUBTLE" "$left"
  local i=0
  while (( i++ < INNER )); do printf "%s" "$ch"; done
  printf "%s%s\n" "$right" "$C_RESET"
}

status_badge() {
  case "$1" in
    in_progress) printf "%s%s%s %s%sIN PROGRESS%s"   "$C_LIVE" "$GLYPH_RUN" "$C_RESET" "$C_BOLD" "$C_LIVE" "$C_RESET" ;;
    completed)   printf "%s%s%s %s%sCOMPLETED%s"     "$C_OK"   "$GLYPH_OK"  "$C_RESET" "$C_BOLD" "$C_OK"   "$C_RESET" ;;
    paused)      printf "%s❚❚%s %s%sPAUSED%s"        "$C_WARN" "$C_RESET"   "$C_BOLD" "$C_WARN"  "$C_RESET" ;;
    failed)      printf "%s%s%s %s%sFAILED%s"        "$C_ERR"  "$GLYPH_FAIL" "$C_RESET" "$C_BOLD" "$C_ERR"  "$C_RESET" ;;
    *)           printf "%s?%s %s%s%s"               "$C_MUTED" "$C_RESET" "$C_BOLD" "${1^^}" "$C_RESET" ;;
  esac
}

# pid_alive <pid> — returns 0 if the process is alive, 1 otherwise
pid_alive() {
  [[ -n "${1:-}" && "$1" != "null" && "$1" != "0" ]] || return 1
  kill -0 "$1" 2>/dev/null
}

# file_age_sec <path> — seconds since last mtime, or -1 if file missing / stat unavailable
file_age_sec() {
  [[ -f "$1" ]] || { echo -1; return; }
  local m
  m=$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo "")
  [[ -z "$m" ]] && { echo -1; return; }
  echo $(( $(date +%s) - m ))
}

# truncate "s" to max_len characters, append … if truncated
trunc() {
  local s="$1" max="$2"
  if (( ${#s} > max )); then printf "%s…" "${s:0:max}"
  else printf "%s" "$s"
  fi
}

# glyph_for_status <status> — echoes colored glyph
glyph_for_status() {
  case "$1" in
    completed)   printf "%s%s%s" "$C_OK"    "$GLYPH_OK"   "$C_RESET" ;;
    in_progress) printf "%s%s%s" "$C_LIVE"  "$GLYPH_RUN"  "$C_RESET" ;;
    failed)      printf "%s%s%s" "$C_ERR"   "$GLYPH_FAIL" "$C_RESET" ;;
    pending|*)   printf "%s%s%s" "$C_SUBTLE" "$GLYPH_WAIT" "$C_RESET" ;;
  esac
}

# phase_duration_sec <phase_json> <now_epoch> — seconds between started_at and completed_at
#   falls back to (now - started_at) if still in_progress, or 0 if no timestamps
phase_duration_sec() {
  local p="$1" now="$2" s c
  s=$(jq -r '.started_at // ""' <<<"$p")
  c=$(jq -r '.completed_at // ""' <<<"$p")
  local se ce
  se=$(iso_to_epoch "$s")
  ce=$(iso_to_epoch "$c")
  if (( se > 0 && ce > se )); then echo $(( ce - se ))
  elif (( se > 0 )); then echo $(( now - se ))
  else echo 0
  fi
}

# ---------- render ----------
render() {
  local state project status started updated total completed failed in_progress prd_path
  state=$(cat "$STATE_FILE")
  project=$(jq -r '.project // "?"' <<<"$state")
  status=$(jq -r '.status // "unknown"' <<<"$state")
  started=$(jq -r '.started_at // ""' <<<"$state")
  updated=$(jq -r '.updated_at // ""' <<<"$state")
  total=$(jq -r '.progress.total // 0' <<<"$state")
  completed=$(jq -r '.progress.completed // 0' <<<"$state")
  failed=$(jq -r '.progress.failed // 0' <<<"$state")
  in_progress=$(jq -r '.progress.in_progress // 0' <<<"$state")
  prd_path=$(jq -r '.prd_path // ""' <<<"$state")

  # Cache PRD once per render for story title lookup (lazy — only if file exists)
  local prd_cache=""
  if [[ -n "$prd_path" && -f "$HQ_ROOT/$prd_path" ]]; then
    prd_cache=$(cat "$HQ_ROOT/$prd_path")
  fi

  local now start_epoch upd_epoch elapsed eta_str avg_ready
  now=$(date +%s)
  start_epoch=$(iso_to_epoch "$started")
  upd_epoch=$(iso_to_epoch "$updated")
  elapsed=$(( now - start_epoch ))
  (( start_epoch == 0 )) && elapsed=0

  if (( completed > 0 && upd_epoch > start_epoch )); then
    local avg_per=$(( (upd_epoch - start_epoch) / completed ))
    local remaining=$(( total - completed ))
    local eta_sec=$(( avg_per * remaining ))
    eta_str=$(human_duration "$eta_sec")
    avg_ready=$(human_duration "$avg_per")
  else
    eta_str="—"
    avg_ready="—"
  fi

  local pct=0
  (( total > 0 )) && pct=$(( completed * 100 / total ))

  # --- header: HQ banner + subtitle ---
  hrule "$HZ" "$TL" "$TR"
  if [[ "$BANNER_MODE" == "unicode" ]]; then
    local brow
    for brow in "${BANNER_ROWS[@]}"; do
      row "$(printf "%s%s%s" "$C_FG" "$brow" "$C_RESET")"
    done
  else
    row "$(printf "%sHQ%s" "$C_BOLD" "$C_RESET")"
  fi
  row "$(printf "%sralph orchestrator%s  %s·%s  %s%s%s" \
    "$C_MUTED" "$C_RESET" \
    "$C_MUTED" "$C_RESET" \
    "$C_FG" "$project" "$C_RESET")"
  row "$(status_badge "$status")"
  hrule "$HZ" "$LT" "$RT"

  # --- progress ---
  local bar_width=$(( INNER - 18 ))
  local bar
  bar=$(progress_bar "$completed" "$total" "$bar_width")
  row "$(printf "%s%s%s %s%2d/%2d%s %s(%3d%%)%s" \
    "$C_FG" "$bar" "$C_RESET" \
    "$C_BOLD$C_FG" "$completed" "$total" "$C_RESET" \
    "$C_MUTED" "$pct" "$C_RESET")"

  local failed_col
  if (( failed > 0 )); then failed_col="$C_ERR"; else failed_col="$C_TEXT"; fi
  row "$(printf "%sin-progress%s %s%d%s   %sfailed%s %s%d%s" \
    "$C_MUTED" "$C_RESET" "$C_TEXT" "$in_progress" "$C_RESET" \
    "$C_MUTED" "$C_RESET" "$failed_col" "$failed" "$C_RESET")"

  # --- timing ---
  row "$(printf "%selapsed%s %s%-10s%s  %savg/story%s %s%-8s%s  %seta%s %s%s%s" \
    "$C_MUTED" "$C_RESET" "$C_TEXT" "$(human_duration "$elapsed")" "$C_RESET" \
    "$C_MUTED" "$C_RESET" "$C_TEXT" "$avg_ready" "$C_RESET" \
    "$C_MUTED" "$C_RESET" "$C_TEXT" "$eta_str" "$C_RESET")"

  # --- active work (per-task phase timeline) ---
  hrule "$HZ" "$LT" "$RT"
  local cur_count
  cur_count=$(jq -r '.current_tasks | length' <<<"$state")
  if (( cur_count == 0 )); then
    row "$(printf "%sno active task%s" "$C_MUTED" "$C_RESET")"
  else
    local i=0
    while (( i < cur_count )); do
      local tid tstarted tpid exec_file
      tid=$(jq -r ".current_tasks[$i].id" <<<"$state")
      tstarted=$(jq -r ".current_tasks[$i].started_at // \"\"" <<<"$state")
      tpid=$(jq -r ".current_tasks[$i].pid // \"\"" <<<"$state")
      exec_file="$EXEC_DIR/$tid.json"

      # story title from PRD (if cached)
      local ttitle=""
      if [[ -n "$prd_cache" ]]; then
        ttitle=$(jq -r --arg id "$tid" '[.stories[]? | select(.id==$id) | .title] | first // ""' <<<"$prd_cache" 2>/dev/null || true)
      fi

      # elapsed on the task
      local tsec=0 tstart_epoch
      tstart_epoch=$(iso_to_epoch "$tstarted")
      (( tstart_epoch > 0 )) && tsec=$(( now - tstart_epoch ))

      # task header row: ▸ US-005  Story title                           5m25s
      local task_hdr
      task_hdr=$(printf "%s▸%s %s%s%s  %s%s%s" \
        "$C_WARN" "$C_RESET" \
        "$C_BOLD$C_FG" "$tid" "$C_RESET" \
        "$C_MUTED" "$(trunc "$ttitle" $(( INNER - 20 )))" "$C_RESET")
      local task_dur
      task_dur=$(printf "%s%s%s" "$C_MUTED" "$(human_duration "$tsec")" "$C_RESET")
      # pad task header + right-align duration
      local hdr_vlen dur_vlen pad
      hdr_vlen=$(visible_width "$task_hdr")
      dur_vlen=$(visible_width "$task_dur")
      pad=$(( INNER - hdr_vlen - dur_vlen - 2 ))
      (( pad < 0 )) && pad=0
      printf "%s%s%s %s%*s%s %s%s%s\n" "$C_SUBTLE" "$VT" "$C_RESET" "$task_hdr" "$pad" "" "$task_dur" "$C_SUBTLE" "$VT" "$C_RESET"

      # --- resolve active worker with layered precedence ---
      local cur_worker="?" cur_pstatus="pending" phases_done=0 phases_total=0 cur_phase_idx=0
      local phase_json="{}"
      if [[ -f "$exec_file" ]]; then
        phases_total=$(jq -r '.phases | length // 0' "$exec_file")
        phases_done=$(jq -r '[.phases[]? | select(.status=="completed")] | length' "$exec_file")
        cur_phase_idx=$(jq -r '.current_phase // 0' "$exec_file")
        # clamp
        (( cur_phase_idx < 0 )) && cur_phase_idx=0
        (( phases_total > 0 && cur_phase_idx >= phases_total )) && cur_phase_idx=$(( phases_total - 1 ))

        # 1) explicit in_progress phase (codex-exec flow)
        phase_json=$(jq -c '[.phases[]? | select(.status=="in_progress")][0] // empty' "$exec_file")
        # 2) current_phase index (bash-v2 flow)
        if [[ -z "$phase_json" ]]; then
          phase_json=$(jq -c --argjson i "$cur_phase_idx" '.phases[$i] // empty' "$exec_file")
        fi
        # 3) last phase fallback
        if [[ -z "$phase_json" ]]; then
          phase_json=$(jq -c '.phases[-1] // empty' "$exec_file")
        fi

        if [[ -n "$phase_json" ]]; then
          cur_worker=$(jq -r '.worker // "?"' <<<"$phase_json")
          cur_pstatus=$(jq -r '.status // "pending"' <<<"$phase_json")
        fi
      else
        cur_worker="starting"; cur_pstatus="pending"
      fi

      # 4) liveness override
      local live_note=""
      if pid_alive "$tpid"; then
        cur_pstatus="in_progress"
        live_note=$(printf "%spid %s%s" "$C_MUTED" "$tpid" "$C_RESET")
      elif [[ -n "$tpid" && "$tpid" != "null" && "$tpid" != "0" && "$tpid" != "" ]]; then
        cur_pstatus="stalled"
        live_note=$(printf "%spid %s dead%s" "$C_ERR" "$tpid" "$C_RESET")
      fi

      # 5) activity freshness from stderr file
      local stderr_file="$EXEC_DIR/${tid}.stderr"
      local age
      age=$(file_age_sec "$stderr_file")
      local fresh_note=""
      if (( age >= 0 )); then
        if (( age <= 30 )); then
          fresh_note=$(printf "%sactive %ds ago%s" "$C_LIVE" "$age" "$C_RESET")
        elif (( age <= 300 )); then
          fresh_note=$(printf "%squiet %s%s" "$C_MUTED" "$(human_duration "$age")" "$C_RESET")
        else
          fresh_note=$(printf "%sstale %s%s" "$C_WARN" "$(human_duration "$age")" "$C_RESET")
        fi
      fi

      # status line: ● dev-qa-tester · phase 2/5 · pid 33450 · active 3s ago
      local status_glyph stat_label
      status_glyph=$(glyph_for_status "$cur_pstatus")
      case "$cur_pstatus" in
        in_progress) stat_label="$C_LIVE$cur_worker$C_RESET" ;;
        stalled)     stat_label="$C_ERR$cur_worker$C_RESET" ;;
        *)           stat_label="$C_FG$cur_worker$C_RESET" ;;
      esac
      local phase_fragment=""
      if (( phases_total > 0 )); then
        local disp_idx=$(( cur_phase_idx + 1 ))
        (( disp_idx > phases_total )) && disp_idx=$phases_total
        phase_fragment=$(printf "  %s·%s phase %s%d/%d%s" \
          "$C_SUBTLE" "$C_RESET" \
          "$C_FG" "$disp_idx" "$phases_total" "$C_RESET")
      else
        phase_fragment=$(printf "  %s·%s %sscaffolding%s" \
          "$C_SUBTLE" "$C_RESET" \
          "$C_MUTED" "$C_RESET")
      fi
      local detail="$(printf "  %s %s%s" "$status_glyph" "$stat_label" "$phase_fragment")"
      if [[ -n "$live_note" ]]; then
        detail="$detail$(printf "  %s·%s %s" "$C_SUBTLE" "$C_RESET" "$live_note")"
      fi
      if [[ -n "$fresh_note" ]]; then
        detail="$detail$(printf "  %s·%s %s" "$C_SUBTLE" "$C_RESET" "$fresh_note")"
      fi
      row "$detail"

      # --- per-phase timeline ---
      if (( phases_total > 0 )); then
        local pi=0
        while (( pi < phases_total )); do
          local p w ps dur_sec dur_str
          p=$(jq -c --argjson i "$pi" '.phases[$i]' "$exec_file")
          w=$(jq -r '.worker // "?"' <<<"$p")
          ps=$(jq -r '.status // "pending"' <<<"$p")
          # if this is the active phase (by index) and it's still pending due to
          # pre-patch run-project.sh, promote the visual status to in_progress
          if (( pi == cur_phase_idx )) && [[ "$ps" == "pending" ]] && pid_alive "$tpid"; then
            ps="in_progress"
          fi
          dur_sec=$(phase_duration_sec "$p" "$now")
          if (( dur_sec > 0 )); then dur_str=$(human_duration "$dur_sec")
          elif [[ "$ps" == "pending" ]]; then dur_str="pending"
          else dur_str="—"
          fi
          local pg
          pg=$(glyph_for_status "$ps")

          local name_col
          case "$ps" in
            in_progress) name_col="$C_LIVE" ;;
            completed)   name_col="$C_OK" ;;
            failed)      name_col="$C_ERR" ;;
            *)           name_col="$C_MUTED" ;;
          esac

          local line_left line_right lv rv lp
          line_left=$(printf "    %s %s%-26s%s" "$pg" "$name_col" "$(trunc "$w" 26)" "$C_RESET")
          line_right=$(printf "%s%s%s" "$C_MUTED" "$dur_str" "$C_RESET")
          if (( pi == cur_phase_idx )) && [[ "$ps" == "in_progress" ]]; then
            line_right="$line_right$(printf "  %s← running%s" "$C_LIVE" "$C_RESET")"
          fi
          lv=$(visible_width "$line_left")
          rv=$(visible_width "$line_right")
          lp=$(( INNER - lv - rv - 2 ))
          (( lp < 0 )) && lp=0
          printf "%s%s%s %s%*s%s %s%s%s\n" "$C_SUBTLE" "$VT" "$C_RESET" "$line_left" "$lp" "" "$line_right" "$C_SUBTLE" "$VT" "$C_RESET"
          pi=$(( pi + 1 ))
        done
      fi

      # --- last stderr line (if any) ---
      if [[ -f "$stderr_file" ]]; then
        local last_line
        last_line=$(tail -n 1 "$stderr_file" 2>/dev/null | tr -d '\r' | head -c 200 || true)
        if [[ -n "$last_line" ]]; then
          local max_tail=$(( INNER - 10 ))
          row "$(printf "  %s⋮ %s%s" "$C_SUBTLE" "$(trunc "$last_line" "$max_tail")" "$C_RESET")"
        fi
      fi

      i=$(( i + 1 ))
    done
  fi

  # --- recent completions (last 5) ---
  if (( completed > 0 )); then
    hrule "$HZ" "$LT" "$RT"
    row "$(printf "%sRECENT%s" "$C_MUTED" "$C_RESET")"
    if [[ -f "$PROGRESS_FILE" ]]; then
      local line id title dur_raw
      while IFS= read -r line; do
        id=$(printf "%s" "$line" | sed -E 's/^\[[^]]+\] (US-[0-9]+):.*/\1/')
        title=$(printf "%s" "$line" | sed -E 's/^\[[^]]+\] US-[0-9]+: (.*) — (completed|failed).*/\1/')
        dur_raw=$(printf "%s" "$line" | sed -nE 's/.*\(([0-9]+)s\).*/\1/p')
        local dur_h
        dur_h=$(human_duration "${dur_raw:-0}")
        local max_title=$(( INNER - 22 ))
        title=$(trunc "$title" "$max_title")
        row "$(printf "  %s%s%s %s%-6s%s %s%-*s%s %s%6s%s" \
          "$C_OK" "$GLYPH_OK" "$C_RESET" \
          "$C_BOLD$C_FG" "$id" "$C_RESET" \
          "$C_TEXT" "$max_title" "$title" "$C_RESET" \
          "$C_MUTED" "$dur_h" "$C_RESET")"
      done < <(grep -E '] US-[0-9]+:.*(completed|failed) \([0-9]+s\)' "$PROGRESS_FILE" 2>/dev/null | tail -n 5)
    fi
  fi

  # --- failures / regression gates ---
  local reg_failed
  reg_failed=$(jq -r '[.regression_gates[]? | select(.passed==false)] | length' <<<"$state")
  if (( failed > 0 || reg_failed > 0 )); then
    hrule "$HZ" "$LT" "$RT"
    if (( failed > 0 )); then
      local failed_ids
      failed_ids=$(jq -r '[.failed_tasks[].id] | join(", ")' <<<"$state")
      row "$(printf "%s%s FAILED TASKS%s  %s" "$C_ERR" "$GLYPH_FAIL" "$C_RESET" "$failed_ids")"
    fi
    if (( reg_failed > 0 )); then
      local reg_after
      reg_after=$(jq -r '[.regression_gates[] | select(.passed==false) | .after_story] | join(", ")' <<<"$state")
      row "$(printf "%s⚠ REGRESSION GATE FAILED%s  after %s" "$C_ERR" "$C_RESET" "$reg_after")"
    fi
  fi

  # --- footer ---
  hrule "$HZ" "$BL" "$BR"
  local brand_label
  brand_label=$(printf "%sindigo%s %s·%s %shq orchestrator%s" \
    "$C_FG" "$C_RESET" \
    "$C_MUTED" "$C_RESET" \
    "$C_MUTED" "$C_RESET")
  if [[ $WATCH -eq 1 ]]; then
    local foot_right
    foot_right=$(printf "%supdated %s · refresh %ss · ^C to exit%s" "$C_MUTED" "$(date +%H:%M:%S)" "$INTERVAL" "$C_RESET")
    printf " %s    %s\n" "$brand_label" "$foot_right"
  else
    printf " %s\n" "$brand_label"
  fi
}

# ---------- main loop ----------
if [[ $WATCH -eq 1 ]]; then
  trap 'printf "\n\033[?25h"; exit 0' INT TERM EXIT
  printf '\033[?25l'
  while :; do
    printf '\033[2J\033[H'
    render
    sleep "$INTERVAL"
  done
else
  render
fi
