#!/usr/bin/env bash
# Put ShellCheck on PATH for a CI job without requiring sudo.
#
# GitHub-hosted runners can apt-install it, but the self-hosted Linux pools
# run jobs as an unprivileged user with no sudo.
# Order: use an existing shellcheck, else apt on a GitHub-hosted runner with
# passwordless sudo, else download the pinned upstream release and verify its
# SHA-256. Self-hosted runners never apt-install, so a job cannot change the
# host image even where sudo happens to work.
#
# Usage: install-shellcheck.sh [bin-dir]
# The bin dir defaults to $RUNNER_TEMP/bin and is appended to $GITHUB_PATH
# when running under Actions.
set -euo pipefail

version="v0.10.0"
bin_dir="${1:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/bin}"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --version | sed -n 2p
  exit 0
fi

if [[ "${RUNNER_ENVIRONMENT:-}" == "github-hosted" && "$(uname -s)" == "Linux" ]] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  sudo -n apt-get update -qq
  sudo -n apt-get install -y -qq shellcheck
  shellcheck --version | sed -n 2p
  exit 0
fi

case "$(uname -s)-$(uname -m)" in
  Linux-aarch64|Linux-arm64)
    asset="shellcheck-${version}.linux.aarch64.tar.xz"
    sha256="324a7e89de8fa2aed0d0c28f3dab59cf84c6d74264022c00c22af665ed1a09bb"
    ;;
  Linux-x86_64|Linux-amd64)
    asset="shellcheck-${version}.linux.x86_64.tar.xz"
    sha256="6c881ab0698e4e6ea235245f22832860544f17ba386442fe7e9d629f8cbedf87"
    ;;
  *)
    echo "install-shellcheck: unsupported platform $(uname -s)-$(uname -m)" >&2
    exit 1
    ;;
esac

for tool in curl sha256sum tar xz; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "install-shellcheck: $tool is required on the runner image to install shellcheck $version" >&2
    exit 1
  fi
done

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
curl -fsSL --retry 3 -o "$work_dir/$asset" \
  "https://github.com/koalaman/shellcheck/releases/download/${version}/${asset}"
actual="$(sha256sum "$work_dir/$asset" | awk '{print $1}')"
if [[ "$actual" != "$sha256" ]]; then
  echo "install-shellcheck: checksum mismatch for $asset (got $actual)" >&2
  exit 1
fi
tar -xJf "$work_dir/$asset" -C "$work_dir"
mkdir -p "$bin_dir"
install -m 0755 "$work_dir/shellcheck-${version}/shellcheck" "$bin_dir/shellcheck"
if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$bin_dir" >> "$GITHUB_PATH"
fi
"$bin_dir/shellcheck" --version | sed -n 2p
