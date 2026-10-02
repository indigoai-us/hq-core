#!/bin/sh
# CLI for priming the cache out of band and exercising cache behavior in tests.
case "$0" in */*) FLAG_DIR=${0%/*} ;; *) FLAG_DIR=. ;; esac
. "$FLAG_DIR/hqd-hook-flag-cache-lib.sh"
if [ "${1:-}" = --refresh ]; then refresh_cache; exit $?; fi
hqd_hook_flag_enabled
printf '%s\n' "$HQD_FLAG_ENABLED"
