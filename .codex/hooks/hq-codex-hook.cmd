@echo off
rem HQ Codex hook launcher for Windows (feedback_d0c2f082).
rem Codex runs a hook's commandWindows through cmd.exe /C, so the POSIX
rem `exec /bin/bash` command in .codex/config.toml cannot run there. This
rem launcher finds Git Bash and runs hq-codex-hook-adapter.sh with the hook's
rem stdin. It never uses `where bash`, which can return the WSL bash in
rem System32. Set HQ_BASH_EXE to override the bash.exe path; a path under
rem %SystemRoot% (the WSL bash) is ignored.
rem The event name is the first argument. The launcher never reads stdin,
rem which reaches bash byte for byte. It fails closed: when the adapter or bash
rem is missing, PreToolUse exits 2 (deny) and every other event exits 1.
rem The file is LF-only (repo eol=lf), so it uses no labels or goto.
setlocal EnableExtensions
set "HQ_HOOK_EVENT=%~1"
set "HQ_HOOK_FAIL_RC=1"
if /i "%HQ_HOOK_EVENT%"=="PreToolUse" set "HQ_HOOK_FAIL_RC=2"
set "HQ_HOOK_ADAPTER=%~dp0hq-codex-hook-adapter.sh"
if not exist "%HQ_HOOK_ADAPTER%" (
  echo HQ codex hook: hq-codex-hook-adapter.sh not found next to the launcher - HQ safety rails did NOT run for %HQ_HOOK_EVENT% 1>&2
  exit /b %HQ_HOOK_FAIL_RC%
)
set "HQ_HOOK_ADAPTER=%HQ_HOOK_ADAPTER:\=/%"
set "HQ_BASH="
set "HQ_BASH_REL="
if defined HQ_BASH_EXE set "HQ_BASH_REL=%HQ_BASH_EXE%"
if defined HQ_BASH_REL if defined SystemRoot call set "HQ_BASH_REL=%%HQ_BASH_REL:%SystemRoot%\=%%"
if defined HQ_BASH_REL call set "HQ_BASH_REL=%%HQ_BASH_REL:\WindowsApps\=%%"
if defined HQ_BASH_EXE if /i not "%HQ_BASH_REL%"=="%HQ_BASH_EXE%" echo HQ codex hook: ignoring HQ_BASH_EXE=%HQ_BASH_EXE% because a bash under the Windows folder is the WSL bash, which cannot run HQ hooks 1>&2
if defined HQ_BASH_EXE if /i "%HQ_BASH_REL%"=="%HQ_BASH_EXE%" if exist "%HQ_BASH_EXE%" set "HQ_BASH=%HQ_BASH_EXE%"
if not defined HQ_BASH if exist "%ProgramFiles%\Git\bin\bash.exe" set "HQ_BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined HQ_BASH if defined ProgramW6432 if exist "%ProgramW6432%\Git\bin\bash.exe" set "HQ_BASH=%ProgramW6432%\Git\bin\bash.exe"
if not defined HQ_BASH if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "HQ_BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
if not defined HQ_BASH for /f "delims=" %%G in ('where git.exe 2^>nul') do if not defined HQ_BASH if exist "%%~dpG..\bin\bash.exe" for %%B in ("%%~dpG..\bin\bash.exe") do set "HQ_BASH=%%~fB"
if not defined HQ_BASH for /f "delims=" %%G in ('where git.exe 2^>nul') do if not defined HQ_BASH if exist "%%~dpG..\usr\bin\bash.exe" for %%B in ("%%~dpG..\usr\bin\bash.exe") do set "HQ_BASH=%%~fB"
if not defined HQ_BASH (
  echo HQ codex hook: Git Bash not found. Install Git for Windows or set HQ_BASH_EXE - HQ safety rails did NOT run for %HQ_HOOK_EVENT% 1>&2
  exit /b %HQ_HOOK_FAIL_RC%
)
"%HQ_BASH%" "%HQ_HOOK_ADAPTER%"
exit /b %ERRORLEVEL%
