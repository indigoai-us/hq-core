# shellcheck shell=bash
# hq-core: public
# Decision-only allow cases for the arithmetic check: a variable that holds a
# program path from command -v, which or type -P with one literal name may be
# run as the command name, the same as the resolver substitution written as
# the head. v16.0.41 allowed these in the credential guard; #1698 blocked them
# (feedback 40a7cdf9). The refuse cases live in bash-arith-guard.cases.sh.
#
# Sourced by the credential-read and vault-write suites. The scope suite does
# not source this file: mandatory-scope-authorizer.sh has its own, older rule
# that refuses a command name held in a substitution-assigned variable.
arith_case 0 resolved-var-command-v "PY=\$(command -v python3); \$PY -c 'print(1)'"
arith_case 0 resolved-var-quoted-jq 'BIN="$(command -v jq)"; "$BIN" --version'
arith_case 0 resolved-var-which 'G=$(which git); $G status'
arith_case 0 resolved-var-type-p 'J=$(type -P jq); "$J" --version'
arith_case 0 resolved-var-backtick 'PY=`command -v python3`; $PY -V'
arith_case 0 resolved-var-then-arith 'PY=$(command -v python3); i=1; $PY -V; echo $((i+1))'
