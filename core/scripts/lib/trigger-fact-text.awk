# Shared source for non-literal text facts derived by derive-trigger-facts.sh
# and the adapter policy-vocabulary prefilter. Keep every text-derived fact
# here so the prefilter cannot drift from the real policy trigger path.
function hq_is_shared_branch(t) {
  return t ~ /(^|[^a-z0-9_])(main|master|staging|production)([^a-z0-9_]|$)/ || t ~ /release\//
}

function hq_emit_fact(f) {
  if (policy_vocab_cache != "") {
    if (f in vocab) matched = 1
  } else {
    print f
  }
}

function hq_emit_derived_text_facts(t) {
  if (t ~ /(^|[^a-z0-9_])aws_profile/ || t ~ /op:\/\/|\.env([^a-z0-9]|$)/) hq_emit_fact("secret")
  if (hq_is_shared_branch(t)) hq_emit_fact("shared_branch")
  if (t ~ /(^|[^a-z0-9])sk-[a-z0-9]/ \
     || t ~ /(^|[^a-z0-9])(gh[opsur]_|github_pat_)[a-z0-9_]/ \
     || t ~ /(^|[^a-z0-9])akia[a-z0-9][a-z0-9]/ \
     || t ~ /(^|[^a-z0-9])xox[bpsa]-[a-z0-9]/ \
     || t ~ /(^|[^a-z0-9])glpat-[a-z0-9]/ \
     || t ~ /-----begin[a-z -]*private key/ \
     || t ~ /(^|[^a-z0-9])bearer[ ][a-z0-9._-][a-z0-9._-][a-z0-9._-]/) {
    hq_emit_fact("apikey")
    hq_emit_fact("secret")
  }
  if (t ~ /successfully (merged|deployed|pushed|published|created)/ \
     || t ~ /(deployment|deploy|build|release) (complete|completed|succeeded|ready)/ \
     || t ~ /merged pull request/ \
     || t ~ /pull request #?[0-9]+ .* merged/) hq_emit_fact("completed")
}

BEGIN {
  if (policy_vocab_cache != "") {
    while ((cache_status = getline cache_line < policy_vocab_cache) > 0) {
      if (index(cache_line, "token=") == 1) vocab[substr(cache_line, 7)] = 1
    }
    close(policy_vocab_cache)
    if (cache_status < 0) cache_error = 1
  }
}

{
  if (NR > 1) text = text "\n"
  text = text $0
}

END {
  t = tolower(text)
  if (mode == "derived") {
    hq_emit_derived_text_facts(t)
    if (hq_is_shared_branch(tolower(branch))) hq_emit_fact("shared_branch")
    exit
  }
  if (mode == "normalize") {
    rest = t
    while (match(rest, /[^[:space:]]+/)) {
      fact = substr(rest, RSTART, RLENGTH)
      rest = substr(rest, RSTART + RLENGTH)
      if (!seen[fact]++) {
        if (out != "") out = out " "
        out = out fact
      }
    }
    if (hq_is_shared_branch(tolower(branch)) && !seen["shared_branch"]++) {
      if (out != "") out = out " "
      out = out "shared_branch"
    }
    printf "%s", out
    exit
  }

  # Open tokenization: every word token in the text becomes a fact. Tokens are
  # letter-led and length >= 2; underscores and internal hyphens are retained.
  tw = t
  while (match(tw, /[a-z][a-z0-9_-]+/)) {
    hq_emit_fact(substr(tw, RSTART, RLENGTH))
    tw = substr(tw, RSTART + RLENGTH)
  }
  hq_emit_derived_text_facts(t)

  # File references emit their basename and extension as facts.
  tmp = t
  while (match(tmp, "\\.?[a-z0-9_][a-z0-9_./-]*\\.[a-z][a-z0-9]+")) {
    fn = substr(tmp, RSTART, RLENGTH)
    tmp = substr(tmp, RSTART + RLENGTH)
    bn = fn
    sub(/.*\//, "", bn)
    ext = bn
    sub(/.*\./, "", ext)
    hq_emit_fact("." ext)
    hq_emit_fact(bn)
  }

  # Slash-command mentions emit /command facts; paths such as repos/public do not.
  tmp2 = " " t
  while (match(tmp2, " /[a-z][a-z0-9-]*")) {
    sc = substr(tmp2, RSTART + 1, RLENGTH - 1)
    tmp2 = substr(tmp2, RSTART + RLENGTH)
    hq_emit_fact(sc)
  }
  if (hq_is_shared_branch(tolower(branch))) hq_emit_fact("shared_branch")
  if (policy_vocab_cache != "") exit cache_error ? 2 : (matched ? 0 : 1)
}
