# Shared source for non-literal text facts derived by derive-trigger-facts.sh
# and the adapter policy-vocabulary prefilter. Keep every text-derived fact
# here so the prefilter cannot drift from the real policy trigger path.
function hq_is_shared_branch(t) {
  return t ~ /(^|[^a-z0-9_])(main|master|staging|production)([^a-z0-9_]|$)/ || t ~ /release\//
}

# Linear-time tokenizing. A loop of the form
#   while (match(x, re)) { ...; x = substr(x, RSTART + RLENGTH) }
# copies the rest of x on every match, so it is quadratic in the length of x.
# Hooks feed this file whole tool outputs as one line (JSON, or text with LF
# flattened), and a 1 MB line took seconds; 5 MB took minutes. The loops below
# run on short segments instead. Segments come only from single-character
# split() calls, which are linear in every awk; regex split() and gsub() are
# quadratic on long strings in the BWK awk that macOS ships.

# hq_segments(s, S): split s into segments that each hold every
# [a-z0-9_./-] run whole, so a token or file-reference match never crosses a
# segment boundary. Whitespace-mode split first; then a segment longer than
# the limit is split on the first separator in the list, and any piece still
# too long on the next one, and so on. Only long pieces are re-split, so short
# segments are copied once. No token or file-reference byte is in the list.
# LF and tab are left out: the whitespace split already removed them, and BWK
# single-character split() also breaks on LF. hq_segment_limit (-v) only
# exists so tests can force every re-split level with a tiny limit.
function hq_segments(s, S,    i, m, n, W) {
  hq_seg_lim = hq_segment_limit > 0 ? hq_segment_limit + 0 : 4096
  if (!hq_seg_ns) hq_seg_ns = split("\" \\ , : ; = { } ( ) [ ] < > ' + * & ? ! @ # $ % ^ ~ ` | \r \v \f \036", hq_seg_seps, " ")
  m = split(s, W, " ")
  n = 0
  for (i = 1; i <= m; i++) n = hq_segment_add(W[i], 1, S, n)
  return n
}

# hq_segment_add(p, level, S, n): append p to S[n+1...], split on the
# separator at this level and deeper while a piece is over the limit.
function hq_segment_add(p, level, S, n,    B, j, k) {
  if (length(p) <= hq_seg_lim || level > hq_seg_ns) {
    S[++n] = p
    return n
  }
  k = split(p, B, hq_seg_seps[level])
  for (j = 1; j <= k; j++) n = hq_segment_add(B[j], level + 1, S, n)
  return n
}

# hq_join(A, n, sep): join A[1..n] with sep, consuming A. Appending one piece
# at a time copies the whole string once per piece, which is quadratic for
# many pieces; joining neighbours in pairs copies it once per halving, so the
# cost is size * log2(n).
function hq_join(A, n, sep,    i, k) {
  if (n == 0) return ""
  while (n > 1) {
    k = 0
    for (i = 1; i <= n; i += 2) {
      if (i < n) A[++k] = A[i] sep A[i + 1]
      else A[++k] = A[i]
    }
    for (i = k + 1; i <= n; i++) delete A[i]
    n = k
  }
  return A[1]
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
  hq_lines[++hq_nlines] = $0
}

END {
  text = hq_join(hq_lines, hq_nlines, "\n")
  t = tolower(text)
  if (mode == "derived") {
    hq_emit_derived_text_facts(t)
    if (hq_is_shared_branch(tolower(branch))) hq_emit_fact("shared_branch")
    exit
  }
  if (mode == "normalize") {
    # Whitespace-mode split removes space, tab and LF; the match loop still
    # runs on each word for any other [:space:] byte (CR, VT, FF).
    nw = split(t, W, " ")
    for (wi = 1; wi <= nw; wi++) {
      rest = W[wi]
      while (match(rest, /[^[:space:]]+/)) {
        fact = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        if (!seen[fact]++) OUT[++nout] = fact
      }
    }
    if (hq_is_shared_branch(tolower(branch)) && !seen["shared_branch"]++) OUT[++nout] = "shared_branch"
    printf "%s", hq_join(OUT, nout, " ")
    exit
  }

  # Open tokenization: every word token in the text becomes a fact. Tokens are
  # letter-led and length >= 2; underscores and internal hyphens are retained.
  nseg = hq_segments(t, SEG)
  for (si = 1; si <= nseg; si++) {
    # A token holds no "." or "/", so split on them too: each piece then holds
    # at most one token, because a token runs to the end of its piece.
    np = split(SEG[si], P, ".")
    for (pi = 1; pi <= np; pi++) {
      nq = split(P[pi], Q, "/")
      for (qi = 1; qi <= nq; qi++) {
        tw = Q[qi]
        while (match(tw, /[a-z][a-z0-9_-]+/)) {
          hq_emit_fact(substr(tw, RSTART, RLENGTH))
          tw = substr(tw, RSTART + RLENGTH)
        }
      }
    }
  }
  # Prefilter mode only needs to know whether any fact is in the vocabulary.
  # The final exit below returns the same status for this case.
  if (policy_vocab_cache != "" && matched && !cache_error) exit 0
  hq_emit_derived_text_facts(t)

  # File references emit their basename and extension as facts. A reference
  # ends in "." then a letter then [a-z0-9], so the cheap literal check stops
  # the loop once the rest of a segment cannot hold one (a failed match of
  # the full pattern costs the square of a long run in BWK awk). The basename
  # is the last "/" piece and the extension the last "." piece: the same
  # strings sub(/.*\//) and sub(/.*\./) leave, without their quadratic cost.
  for (si = 1; si <= nseg; si++) {
    tmp = SEG[si]
    while (match(tmp, /\.[a-z][a-z0-9]/) \
        && match(tmp, "\\.?[a-z0-9_][a-z0-9_./-]*\\.[a-z][a-z0-9]+")) {
      fn = substr(tmp, RSTART, RLENGTH)
      tmp = substr(tmp, RSTART + RLENGTH)
      nb = split(fn, FB, "/")
      bn = FB[nb]
      ne = split(bn, FE, ".")
      ext = FE[ne]
      hq_emit_fact("." ext)
      hq_emit_fact(bn)
    }
  }

  # Slash-command mentions emit /command facts; paths such as repos/public do
  # not. A fact is " /" then [a-z][a-z0-9-]*, where the space is a real space
  # (not LF or tab), and line 1 counts as preceded by one. Per line (BWK
  # single-character split() also breaks on LF), split on "/": every piece
  # after the first follows a slash, and the previous piece's last byte says
  # whether a space came before that slash.
  nl = split(t, L, "\n")
  for (li = 1; li <= nl; li++) {
    np = split((li == 1 ? " " : "") L[li], P, "/")
    for (pi = 2; pi <= np; pi++) {
      if (substr(P[pi - 1], length(P[pi - 1])) != " ") continue
      # Match on a bounded head so a long piece costs little; re-match the
      # whole piece only when the name fills the head.
      head = substr(P[pi], 1, 256)
      if (match(head, /^[a-z][a-z0-9-]*/)) {
        if (RLENGTH == 256) match(P[pi], /^[a-z][a-z0-9-]*/)
        hq_emit_fact("/" substr(P[pi], 1, RLENGTH))
      }
    }
  }
  if (hq_is_shared_branch(tolower(branch))) hq_emit_fact("shared_branch")
  if (policy_vocab_cache != "") exit cache_error ? 2 : (matched ? 0 : 1)
}
