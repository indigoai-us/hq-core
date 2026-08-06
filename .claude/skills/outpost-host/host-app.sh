#!/usr/bin/env bash
# host-app.sh — provision nginx on an HQ Outpost / EC2 VM to serve an app.
#
# This is the worker behind /outpost-host. It is GATED: it refuses to do anything
# until guard.sh confirms the host is an HQ Outpost or EC2 instance. nginx is used
# as the front door for whatever the user wants to serve:
#   - static:  serve a directory of files directly
#   - proxy:   reverse-proxy to an already-running app on a local port
#
# Subcommands:
#   check                         run the env guard (exit 1 + message if not an outpost/EC2)
#   ensure-nginx                  install + enable nginx if missing
#   free-port [START] [END]       print the first free TCP listen port in a range (default 8080-8099)
#   public-url PORT               print the externally-reachable URL for a listen port
#   deploy   --name N --mode static --root DIR   [--port P]
#   deploy   --name N --mode proxy  --upstream HOST:PORT [--port P]
#   list                          list apps this skill is currently serving
#   remove   --name N             remove an app's nginx site and reload
#
# All nginx/system mutations go through sudo (outposts grant passwordless sudo).
# Site configs live in /etc/nginx/conf.d/outpost-<name>.conf so they are easy to
# enumerate and remove without touching the operator's other nginx config.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="/etc/nginx/conf.d"
CONF_PREFIX="outpost-"
# Managed web root for static sites. User dirs (e.g. /home/<user> is 0700 on
# Amazon Linux) are not traversable by the nginx worker user, so static content
# is copied here where nginx can read it.
WEBROOT_BASE="/usr/share/nginx/outpost-host"

die() { printf 'outpost-host: %s\n' "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*"; }

run_guard() {
  bash "$SKILL_DIR/guard.sh"
}

# ---- environment gate ------------------------------------------------------
cmd_check() {
  run_guard || exit 1
}

require_outpost() {
  if ! run_guard >/dev/null 2>&1; then
    run_guard   # re-run to surface the human-readable refusal message
    exit 1
  fi
}

# ---- nginx install ---------------------------------------------------------
cmd_ensure_nginx() {
  require_outpost
  if command -v nginx >/dev/null 2>&1; then
    info "nginx already installed: $(nginx -v 2>&1)"
  else
    info "installing nginx..."
    if   command -v dnf    >/dev/null 2>&1; then sudo dnf install -y nginx
    elif command -v yum    >/dev/null 2>&1; then sudo yum install -y nginx
    elif command -v apt-get>/dev/null 2>&1; then sudo apt-get update -y && sudo apt-get install -y nginx
    else die "no supported package manager (dnf/yum/apt-get) found"; fi
  fi
  sudo mkdir -p "$CONF_DIR"
  sudo systemctl enable --now nginx >/dev/null 2>&1 || sudo systemctl restart nginx
  info "nginx is running."
}

# ---- free port discovery ("looks for a free host slot") --------------------
port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p\$"
  else
    lsof -iTCP:"$p" -sTCP:LISTEN -Pn >/dev/null 2>&1
  fi
}

cmd_free_port() {
  local start="${1:-8080}" end="${2:-8099}" p
  for ((p=start; p<=end; p++)); do
    if ! port_in_use "$p"; then echo "$p"; return 0; fi
  done
  die "no free port in range ${start}-${end}"
}

# ---- public URL ------------------------------------------------------------
public_host() {
  local host=""
  local token
  token="$(curl -s -m 2 -X PUT 'http://169.254.169.254/latest/api/token' \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)"
  if [[ -n "$token" ]]; then
    host="$(curl -s -m 2 -H "X-aws-ec2-metadata-token: $token" \
      'http://169.254.169.254/latest/meta-data/public-ipv4' 2>/dev/null || true)"
    [[ -z "$host" ]] && host="$(curl -s -m 2 -H "X-aws-ec2-metadata-token: $token" \
      'http://169.254.169.254/latest/meta-data/public-hostname' 2>/dev/null || true)"
  fi
  [[ -z "$host" ]] && host="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ -z "$host" ]] && host="localhost"
  echo "$host"
}

cmd_public_url() {
  local port="${1:?usage: public-url PORT}"
  local host; host="$(public_host)"
  if [[ "$port" == "80" ]]; then echo "http://$host"; else echo "http://$host:$port"; fi
}

# ---- deploy ----------------------------------------------------------------
write_site_and_reload() {
  local conf_path="$1" conf_body="$2"
  printf '%s\n' "$conf_body" | sudo tee "$conf_path" >/dev/null
  if ! sudo nginx -t 2>/tmp/outpost-nginx-test.log; then
    sudo rm -f "$conf_path"
    cat /tmp/outpost-nginx-test.log >&2
    die "nginx config test failed; site not installed (reverted)"
  fi
  sudo systemctl reload nginx 2>/dev/null || sudo systemctl restart nginx
}

cmd_deploy() {
  require_outpost
  local name="" mode="" root="" upstream="" port=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)     name="$2"; shift 2;;
      --mode)     mode="$2"; shift 2;;
      --root)     root="$2"; shift 2;;
      --upstream) upstream="$2"; shift 2;;
      --port)     port="$2"; shift 2;;
      *) die "unknown arg: $1";;
    esac
  done
  [[ -n "$name" ]] || die "--name is required"
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "--name must be a slug ([a-z0-9-], no leading dash)"
  [[ "$mode" == "static" || "$mode" == "proxy" ]] || die "--mode must be 'static' or 'proxy'"

  cmd_ensure_nginx
  [[ -z "$port" ]] && port="$(cmd_free_port)"
  local conf_path="${CONF_DIR}/${CONF_PREFIX}${name}.conf"
  local body

  if [[ "$mode" == "static" ]]; then
    [[ -n "$root" ]] || die "--root is required for static mode"
    root="$(cd "$root" 2>/dev/null && pwd)" || die "--root dir not found"
    [[ -f "$root/index.html" ]] || info "warning: no index.html in $root — directory has no default page"
    # Copy into an nginx-readable managed web root (user dirs are not traversable
    # by the nginx worker), then make it world-readable.
    local webroot="${WEBROOT_BASE}/${name}"
    sudo rm -rf "$webroot"
    sudo mkdir -p "$webroot"
    sudo cp -aT "$root" "$webroot"
    sudo chmod -R a+rX "$WEBROOT_BASE"
    body="# managed by /outpost-host — app: ${name}
# static content copied from: ${root}
server {
    listen ${port};
    listen [::]:${port};
    server_name _;
    root ${webroot};
    index index.html;
    location / {
        try_files \$uri \$uri/ =404;
    }
}"
  else
    [[ -n "$upstream" ]] || die "--upstream HOST:PORT is required for proxy mode"
    [[ "$upstream" =~ ^[A-Za-z0-9_.-]+:[0-9]+$ ]] || die "--upstream must be HOST:PORT"
    body="# managed by /outpost-host — app: ${name}
server {
    listen ${port};
    listen [::]:${port};
    server_name _;
    location / {
        proxy_pass http://${upstream};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
    }
}"
  fi

  write_site_and_reload "$conf_path" "$body"
  local url; url="$(cmd_public_url "$port")"
  echo "DEPLOYED name=${name} mode=${mode} port=${port}"
  echo "URL=${url}"
  echo "CONF=${conf_path}"
  echo
  info "Note: make sure the instance's security group allows inbound TCP on port ${port}."
}

cmd_list() {
  require_outpost
  shopt -s nullglob
  local found=0 f name port
  for f in "${CONF_DIR}/${CONF_PREFIX}"*.conf; do
    found=1
    name="$(basename "$f" .conf)"; name="${name#${CONF_PREFIX}}"
    port="$(grep -m1 -oE 'listen +[0-9]+' "$f" 2>/dev/null | awk '{print $2}')"
    echo "${name}  port=${port:-?}  $(cmd_public_url "${port:-80}")"
  done
  [[ "$found" == 0 ]] && echo "(no apps hosted by /outpost-host)"
}

cmd_remove() {
  require_outpost
  local name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="$2"; shift 2;;
      *) die "unknown arg: $1";;
    esac
  done
  [[ -n "$name" ]] || die "--name is required"
  local conf_path="${CONF_DIR}/${CONF_PREFIX}${name}.conf"
  [[ -f "$conf_path" ]] || die "no app named '${name}' is hosted here"
  sudo rm -f "$conf_path"
  sudo rm -rf "${WEBROOT_BASE}/${name}"   # managed static content, if any
  sudo nginx -t >/dev/null 2>&1 && (sudo systemctl reload nginx 2>/dev/null || sudo systemctl restart nginx)
  echo "REMOVED name=${name}"
}

main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    check)        cmd_check "$@";;
    ensure-nginx) cmd_ensure_nginx "$@";;
    free-port)    cmd_free_port "$@";;
    public-url)   cmd_public_url "$@";;
    deploy)       cmd_deploy "$@";;
    list)         cmd_list "$@";;
    remove)       cmd_remove "$@";;
    ""|-h|--help)
      grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//';;
    *) die "unknown subcommand: $sub (try --help)";;
  esac
}

main "$@"
