#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
publisher="$repo_root/core/scripts/publish-hq-anywhere-runtime-assets.sh"
workflow="$repo_root/.github/workflows/release.yml"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GH_CALLS"
GH
chmod +x "$tmp/bin/gh"
for name in plugin marketplace pack; do
  printf '%s\n' "$name" > "$tmp/$name.tar.gz"
done

export PATH="$tmp/bin:$PATH"
export GH_CALLS="$tmp/gh-calls"

bash "$publisher" false indigoai-us/hq-core-staging v1.2.3 \
  "$tmp/plugin.tar.gz" "$tmp/marketplace.tar.gz" "$tmp/pack.tar.gz" > "$tmp/off.out"
grep -q 'publish_runtime_assets is false' "$tmp/off.out"
test ! -e "$GH_CALLS" || test ! -s "$GH_CALLS"

bash "$publisher" true indigoai-us/hq-core-staging v1.2.3 \
  "$tmp/plugin.tar.gz" "$tmp/marketplace.tar.gz" "$tmp/pack.tar.gz"
grep -q '^release upload --repo indigoai-us/hq-core-staging --clobber v1.2.3 ' "$GH_CALLS"

if bash "$publisher" true indigoai-us/hq-core-staging feature-branch \
  "$tmp/plugin.tar.gz" "$tmp/marketplace.tar.gz" "$tmp/pack.tar.gz" > "$tmp/invalid-tag.out" 2>&1; then
  echo 'publisher accepted a non-release ref' >&2
  exit 1
fi
grep -q 'refusing to upload runtime assets to non-release tag' "$tmp/invalid-tag.out"

if bash "$publisher" true bad-repo v1.2.3 \
  "$tmp/plugin.tar.gz" "$tmp/marketplace.tar.gz" "$tmp/pack.tar.gz" > "$tmp/invalid-repo.out" 2>&1; then
  echo 'publisher accepted a non-anchored repository name' >&2
  exit 1
fi
grep -q 'repository must be an explicit owner/repo pair' "$tmp/invalid-repo.out"

node - "$workflow" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');
const parserRoot = process.env.HQ_AGENT_RUNTIME_PARSER_ROOT;
assert.ok(parserRoot, 'HQ_AGENT_RUNTIME_PARSER_ROOT must point to the pinned js-yaml installation');
const requireFromParser = createRequire(path.join(parserRoot, 'release-workflow.test.cjs'));
const yaml = requireFromParser('js-yaml');
const workflow = yaml.load(fs.readFileSync(process.argv[2], 'utf8'));
assert.equal(workflow.on.workflow_dispatch.inputs.publish_runtime_assets.default, false);
assert.equal(workflow.jobs['publish-runtime-assets'].if,
  "${{ github.event_name == 'workflow_dispatch' && github.ref_type == 'tag' && inputs.publish_runtime_assets == true }}");
assert.equal(workflow.jobs['publish-runtime-assets'].needs, 'runtime-assets');
assert.ok(workflow.jobs['publish-runtime-assets'].steps.some((step) =>
  step.run?.includes('publish-hq-anywhere-runtime-assets.sh')));
assert.ok(workflow.jobs['runtime-assets'].steps.some((step) =>
  step.uses === 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02'));
assert.equal(workflow.jobs.release.if,
  "${{ github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') }}");
NODE

echo 'Runtime asset publisher gate tests passed.'
