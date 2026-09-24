#!/usr/bin/env bash
# Small, side-effect-free probes shared by the master dispatcher and watchdog.

hook_timeout_os_name() {
  case "${1:-}" in
    Linux|linux|linux-*) printf 'linux' ;;
    Darwin|darwin|darwin-*) printf 'macos' ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT*|mingw*|msys*|cygwin*|windows*) printf 'windows' ;;
    *) printf 'other' ;;
  esac
}

hook_timeout_load_average() {
  local platform="${1:-}" proc_file="${2:-/proc/loadavg}" sysctl_bin="${3:-sysctl}"
  local value="" token
  case "$(hook_timeout_os_name "$platform")" in
    linux)
      if [ -r "$proc_file" ]; then
        IFS=' ' read -r value _ < "$proc_file" || true
      fi
      ;;
    macos)
      if [ -x "$sysctl_bin" ] || command -v "$sysctl_bin" >/dev/null 2>&1; then
        value="$("$sysctl_bin" -n vm.loadavg 2>/dev/null || true)"
        for token in $value; do
          case "$token" in '{'|'}') continue ;; esac
          value="$token"
          break
        done
      fi
      ;;
    *) printf 'unavailable'; return 0 ;;
  esac
  if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s' "$value"
  else
    printf 'unavailable'
  fi
}

hook_timeout_now_ms() {
  local realtime seconds fraction now
  realtime="${EPOCHREALTIME:-}"
  if [ -n "$realtime" ]; then
    seconds="${realtime%%.*}"
    fraction="${realtime#*.}000"
    fraction="${fraction:0:3}"
    if [[ "$seconds" =~ ^[0-9]+$ ]] && [[ "$fraction" =~ ^[0-9]{3}$ ]]; then
      printf '%s%s' "$seconds" "$fraction"
      return 0
    fi
  fi
  now="$(date +%s%3N 2>/dev/null || true)"
  if [[ "$now" =~ ^[0-9]+$ ]] && [ "${#now}" -gt 10 ]; then
    printf '%s' "$now"
    return 0
  fi
  if command -v perl >/dev/null 2>&1; then
    now="$(perl -MTime::HiRes=time -e 'printf "%.0f", time() * 1000' 2>/dev/null || true)"
    if [[ "$now" =~ ^[0-9]+$ ]]; then
      printf '%s' "$now"
      return 0
    fi
  fi
  now="$(date +%s 2>/dev/null || printf '0')"
  [[ "$now" =~ ^[0-9]+$ ]] || now=0
  printf '%s000' "$now"
}

hook_timeout_has_gnu_timeout() {
  local version=""
  command -v timeout >/dev/null 2>&1 || return 1
  version="$(timeout --version 2>/dev/null || true)"
  case "$version" in
    *"GNU coreutils"*) return 0 ;;
    *) return 1 ;;
  esac
}

hook_timeout_run_bounded() {
  local seconds="${1:-}"
  shift || true
  case "$seconds" in ''|*[!0-9]*|0) return 2 ;; esac
  if hook_timeout_has_gnu_timeout; then
    timeout -k 1s "${seconds}s" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV or exit 127' "$seconds" "$@"
  else
    return 127
  fi
}

hook_timeout_windows_spawn_ms() {
  local shell_bin="${1:-bash}" powershell_bin="${2:-}" native_shell
  [ -n "$powershell_bin" ] || {
    for candidate in powershell.exe powershell pwsh.exe pwsh; do
      powershell_bin="$(command -v "$candidate" 2>/dev/null || true)"
      [ -n "$powershell_bin" ] && break
    done
  }
  [ -n "$powershell_bin" ] || return 127
  [ -x "$shell_bin" ] || shell_bin="$(command -v "$shell_bin" 2>/dev/null || true)"
  [ -n "$shell_bin" ] && [ -x "$shell_bin" ] || return 127

  native_shell="$shell_bin"
  if command -v cygpath >/dev/null 2>&1; then
    native_shell="$(cygpath -aw "$shell_bin" 2>/dev/null || true)"
  fi
  [ -n "$native_shell" ] || return 127

  # Perl's alarm/exec implementation is not a reliable process timeout on
  # Win32. PowerShell starts the known, fixed `bash -c :` probe and bounds the
  # child wait with Process.WaitForExit; the caller caches this one measurement
  # for the rest of the session.
  HQ_HOOK_TIMEOUT_SPAWN_SHELL="$native_shell" \
    MSYS2_ARG_CONV_EXCL='*' \
    "$powershell_bin" -NoLogo -NoProfile -NonInteractive -Command '
      $ErrorActionPreference = "Stop"
      $shell = $env:HQ_HOOK_TIMEOUT_SPAWN_SHELL
      if ([string]::IsNullOrWhiteSpace($shell)) { exit 127 }
      $process = New-Object System.Diagnostics.Process
      $process.StartInfo.FileName = $shell
      $process.StartInfo.Arguments = "-c :"
      $process.StartInfo.UseShellExecute = $false
      $process.StartInfo.CreateNoWindow = $true
      $timer = [System.Diagnostics.Stopwatch]::StartNew()
      try {
        if (-not $process.Start()) { exit 127 }
        if (-not $process.WaitForExit(5000)) {
          try { $process.Kill() } catch {}
          try { $null = $process.WaitForExit(1000) } catch {}
          [Console]::Write("5000")
          exit 0
        }
        $timer.Stop()
        $elapsed = [Math]::Max(0, [Math]::Min(5000, $timer.ElapsedMilliseconds))
        [Console]::Write([int]$elapsed)
        exit 0
      } catch {
        exit 127
      }
    ' 2>/dev/null
}

hook_timeout_spawn_ms() {
  local cache_file="${1:-}" shell_bin="${2:-bash}" platform="${3:-}"
  local powershell_bin="${4:-}" cached lock_file started ended elapsed rc=0 temporary=""
  local probe_ok=yes cache_hit=no saved_hup_trap saved_int_trap saved_term_trap
  [ -n "$cache_file" ] || return 0
  [ -n "$platform" ] || platform="$(uname -s 2>/dev/null || true)"
  if [ -f "$cache_file" ]; then
    cached="$(<"$cache_file")"
    [[ "$cached" =~ ^[0-9]+$ ]] && { printf '%s' "$cached"; return 0; }
  fi
  if [ "$(hook_timeout_os_name "$platform")" = windows ]; then
    [ -n "$powershell_bin" ] || {
      for candidate in powershell.exe powershell pwsh.exe pwsh; do
        powershell_bin="$(command -v "$candidate" 2>/dev/null || true)"
        [ -n "$powershell_bin" ] && break
      done
    }
    [ -n "$powershell_bin" ] || return 0
  else
    hook_timeout_has_gnu_timeout || command -v perl >/dev/null 2>&1 || return 0
  fi
  [ -x "$shell_bin" ] || shell_bin="$(command -v "$shell_bin" 2>/dev/null || true)"
  [ -n "$shell_bin" ] && [ -x "$shell_bin" ] || return 0

  # noclobber makes claiming the per-session cache atomic. A concurrent event
  # uses an already-published value or leaves this event's spawn measurement
  # unavailable; it never waits on the probe or starts a duplicate shell.
  lock_file="$cache_file.lock"
  if ! (set -o noclobber; printf '%s\n' "$$" > "$lock_file") 2>/dev/null; then
    if [ -f "$cache_file" ]; then
      cached="$(<"$cache_file")"
      [[ "$cached" =~ ^[0-9]+$ ]] && printf '%s' "$cached"
    fi
    return 0
  fi

  saved_hup_trap="$(trap -p HUP)"
  saved_int_trap="$(trap -p INT)"
  saved_term_trap="$(trap -p TERM)"
  trap 'rm -f "$lock_file" "${temporary:-}" >/dev/null 2>&1 || true; exit 129' HUP
  trap 'rm -f "$lock_file" "${temporary:-}" >/dev/null 2>&1 || true; exit 130' INT
  trap 'rm -f "$lock_file" "${temporary:-}" >/dev/null 2>&1 || true; exit 143' TERM

  if [ -f "$cache_file" ]; then
    cached="$(<"$cache_file")"
    if [[ "$cached" =~ ^[0-9]+$ ]]; then
      elapsed="$cached"
      cache_hit=yes
    fi
  fi

  if [ "$cache_hit" = no ]; then
    if [ "$(hook_timeout_os_name "$platform")" = windows ]; then
      elapsed="$(hook_timeout_windows_spawn_ms "$shell_bin" "$powershell_bin")" || rc=$?
      [[ "$elapsed" =~ ^[0-9]+$ ]] || probe_ok=no
    else
      started="$(hook_timeout_now_ms)"
      hook_timeout_run_bounded 5 "$shell_bin" -c : >/dev/null 2>&1 || rc=$?
      ended="$(hook_timeout_now_ms)"
      elapsed=0
      if [[ "$started" =~ ^[0-9]+$ ]] && [[ "$ended" =~ ^[0-9]+$ ]] && [ "$ended" -ge "$started" ]; then
        elapsed=$((ended - started))
      fi
      case "$rc" in
        0) ;;
        124|137|142) elapsed=5000 ;;
        *) probe_ok=no ;;
      esac
    fi
  fi
  if [ "$probe_ok" = yes ] && [ "$cache_hit" = no ]; then
    temporary="$cache_file.tmp.$$"
    if printf '%s\n' "$elapsed" > "$temporary" 2>/dev/null; then
      mv -f "$temporary" "$cache_file" >/dev/null 2>&1 || rm -f "$temporary" >/dev/null 2>&1 || true
    else
      rm -f "$temporary" >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$lock_file" >/dev/null 2>&1 || true
  trap - HUP INT TERM
  [ -z "$saved_hup_trap" ] || eval "$saved_hup_trap"
  [ -z "$saved_int_trap" ] || eval "$saved_int_trap"
  [ -z "$saved_term_trap" ] || eval "$saved_term_trap"
  [ "$probe_ok" = no ] || printf '%s' "$elapsed"
  return 0
}
