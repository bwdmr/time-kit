#!/bin/sh
set -eu

# Absolute path to this script, without relying on dirname/basename/readlink
case "$0" in
  */*) _script_dir=${0%/*} ;;
  *)   _script_dir=. ;;
esac

_oldpwd=$PWD
cd "$_script_dir" >/dev/null 2>&1 || {
  echo "error: cannot resolve script path" >&2
  exit 1
}
SCRIPT_ABS="$PWD/${0##*/}"
cd "$_oldpwd" >/dev/null 2>&1 || exit 1

unset _script_dir _oldpwd


# -------------------------
# Selftest helpers
# -------------------------
fail() { echo "FAIL $*" >&2; exit 1; }
pass() { echo "PASS $*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing required tool: $1"; }

assert_eq() {
  exp="$1"; got="$2"; name="${3:-}"
  [ "$exp" = "$got" ] || fail "${name:+$name: }expected '$exp' got '$got'"
}
assert_ne() {
  a="$1"; b="$2"; name="${3:-}"
  [ "$a" != "$b" ] || fail "${name:+$name: }expected values to differ, both '$a'"
}
assert_match() {
  hay="$1"; needle="$2"; name="${3:-}"
  printf '%s' "$hay" | grep -q "$needle" || fail "${name:+$name: }expected match /$needle/, got: $hay"
}

jq_get() { jq -r "$1" "$2"; }

# Convert unix seconds -> ISO-8601 UTC string for git env vars
iso_utc_from_unix() {
  ts="$1"
  command -v python3 >/dev/null 2>&1 || fail "selftest needs python3 for timestamp formatting"
  python3 - "$ts" <<'PY'
import sys, datetime
ts = int(sys.argv[1])
print(datetime.datetime.fromtimestamp(ts, tz=datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

# Create a commit on current branch with controlled message/body and timestamp.
# args: <subject> <body> <unix_ts>
mkcommit() {
  subj="$1"; body="$2"; ts="$3"
  iso="$(iso_utc_from_unix "$ts")"

  printf '%s\n' "$subj $ts" >>file.txt
  git add file.txt
  GIT_AUTHOR_DATE="$iso" GIT_COMMITTER_DATE="$iso" \
    git commit -q -m "$subj" -m "$body"
}

# Setup a tiny git repo with main branch and an initial commit.
setup_repo() {
  repo="$1"
  mkdir -p "$repo"
  (cd "$repo" && {
    git init -q
    git config user.email "selftest@example.com"
    git config user.name "Self Test"
    git checkout -q -b main
    : >file.txt
    git add file.txt
    # no forced timestamp needed for the init commit
    git commit -q -m "init"
  })
}

selftest_noargs() {
  set +e
  out="$("$SCRIPT_ABS" 2>&1)"
  rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    echo "FAIL selftest_noargs: expected non-zero exit, got 0" >&2
    echo "output: $out" >&2
    return 1
  fi

  printf '%s' "$out" | grep -q "usage:" \
    || { echo "FAIL selftest_noargs: missing 'usage:' message, got: $out" >&2; return 1; }
  printf '%s' "$out" | grep -q "<branch>" \
    || { echo "FAIL selftest_noargs: missing '<branch>' in usage message, got: $out" >&2; return 1; }

  echo "PASS selftest_noargs" >&2
}

selftest_jq_missing() {
  # PATH is blank so jq cannot be found; script should fail before using git.
  if out="$(PATH="" "$SCRIPT_ABS" foo 2>&1)"; then
    fail "selftest_jq_missing: expected non-zero exit, got 0 (out=$out)"
  fi
  printf '%s' "$out" | grep -q "error: jq not installed" \
    || fail "selftest_jq_missing: expected jq error, got: $out"
  pass "selftest_jq_missing"
}

selftest_fresh_file_creation_and_metrics() {
  need git
  need jq

  tmp="${TMPDIR:-/tmp}/genchlg.repo.$$"
  setup_repo "$tmp"

  (cd "$tmp" && {
    # branch br1: one commit, so FIRST == BR tip.
    git checkout -q -b br1
    body="- timestamp: 1000
- issue: https://example.com/issue/1"
    mkcommit "feat: first attempt" "$body" 1000

    rm -f CHANGELOG.json

    "$SCRIPT_ABS" br1 >/dev/null

    [ -f CHANGELOG.json ] || fail "fresh file creation: CHANGELOG.json not created"

    # File is JSON array with one entry
    typ="$(jq -r 'type' CHANGELOG.json)"
    assert_eq "array" "$typ" "fresh file: top-level type"
    len="$(jq -r 'length' CHANGELOG.json)"
    assert_eq "1" "$len" "fresh file: array length"

    # One attempt, attempts_len == 1, pickup null, lead == 0, mttr == 0
    issue="$(jq_get '.[0].meta.issue' CHANGELOG.json)"
    assert_eq "https://example.com/issue/1" "$issue" "stored issue"
    attempts_len="$(jq_get '.[0].meta.attempts_len' CHANGELOG.json)"
    assert_eq "1" "$attempts_len" "attempts_len"

    started="$(jq_get '.[0].meta.attempts.a1.started_at_unix' CHANGELOG.json)"
    attempted="$(jq_get '.[0].meta.attempts.a1.attempted_at_unix' CHANGELOG.json)"
    assert_eq "1000" "$started" "a1 started_at_unix"
    assert_eq "1000" "$attempted" "a1 attempted_at_unix"

    mttr="$(jq_get '.[0].meta.mean_time_to_recovery_seconds' CHANGELOG.json)"
    assert_eq "0" "$mttr" "mttr sanity (attempted == started)"
    pickup="$(jq -r '.[0].meta.pickup_frequency_seconds // "null"' CHANGELOG.json)"
    assert_eq "null" "$pickup" "pickup with 1 attempt must be null/absent"
    lead="$(jq_get '.[0].meta.lead_time_seconds' CHANGELOG.json)"
    assert_eq "0" "$lead" "lead time with 1 attempt"
  })

  rm -rf "$tmp"
  pass "selftest_fresh_file_creation_and_metrics"
}

selftest_idempotency_by_commit_hash() {
  need git
  need jq

  tmp="${TMPDIR:-/tmp}/genchlg.repo.$$"
  setup_repo "$tmp"

  (cd "$tmp" && {
    git checkout -q -b br1
    body="- timestamp: 1000
- issue: https://example.com/issue/1"
    mkcommit "feat: first attempt" "$body" 1000

    rm -f CHANGELOG.json
    "$SCRIPT_ABS" br1 >/dev/null
    before="$(jq_get '.[0].meta.attempts_len' CHANGELOG.json)"

    "$SCRIPT_ABS" br1 >/dev/null
    after="$(jq_get '.[0].meta.attempts_len' CHANGELOG.json)"

    assert_eq "1" "$before" "idempotency: before"
    assert_eq "1" "$after" "idempotency: after"

    # Ensure no a2 was created
    has_a2="$(jq -r '.[0].meta.attempts | has("a2")' CHANGELOG.json)"
    assert_eq "false" "$has_a2" "idempotency: should not add a2"
  })

  rm -rf "$tmp"
  pass "selftest_idempotency_by_commit_hash"
}

selftest_second_attempt_same_issue_new_first_commit() {
  need git
  need jq

  tmp="${TMPDIR:-/tmp}/genchlg.repo.$$"
  setup_repo "$tmp"

  (cd "$tmp" && {
    # First attempt on br1
    git checkout -q -b br1
    body1="- timestamp: 1000
- issue: https://example.com/issue/1"
    mkcommit "feat: first attempt" "$body1" 1000
    rm -f CHANGELOG.json
    "$SCRIPT_ABS" br1 >/dev/null

    # Second attempt on br2 for same issue, different FIRST commit hash
    git checkout -q main
    git checkout -q -b br2
    body2="- timestamp 2000
- issue: https://example.com/issue/1"
    mkcommit "feat: second attempt" "$body2" 2000
    "$SCRIPT_ABS" br2 >/dev/null

    attempts_len="$(jq_get '.[0].meta.attempts_len' CHANGELOG.json)"
    assert_eq "2" "$attempts_len" "second attempt increments attempts_len"

    # Ensure keys are a1, a2 and ordered correctly
    keys="$(jq -r '.[0].meta.attempts | keys | join(",")' CHANGELOG.json)"
    assert_eq "a1,a2" "$keys" "attempt keys must be a1,a2"

    a1s="$(jq_get '.[0].meta.attempts.a1.started_at_unix' CHANGELOG.json)"
    a2s="$(jq_get '.[0].meta.attempts.a2.started_at_unix' CHANGELOG.json)"
    assert_eq "1000" "$a1s" "a1 started"
    assert_eq "2000" "$a2s" "a2 started (timestamp parsing variant without colon)"

    # Lead time sanity: lead == lastAtt - occurred
    occurred="$(jq_get '.[0].meta.occurred_at_unix' CHANGELOG.json)"
    lastAtt="$(jq -r '.[0].meta.attempts.a2.attempted_at_unix' CHANGELOG.json)"
    lead="$(jq_get '.[0].meta.lead_time_seconds' CHANGELOG.json)"
    assert_eq "1000" "$occurred" "occurred_at_unix"
    assert_eq "2000" "$lastAtt" "last attempted_at_unix"
    assert_eq "1000" "$lead" "lead_time_seconds"

    # Pickup frequency with 2 attempts: should be (a2.started - a1.attempted) which is 2000-1000=1000
    pickup="$(jq_get '.[0].meta.pickup_frequency_seconds' CHANGELOG.json)"
    assert_eq "1000" "$pickup" "pickup_frequency_seconds"
  })

  rm -rf "$tmp"
  pass "selftest_second_attempt_same_issue_new_first_commit"
}

selftest_different_issue_new_entry_and_issue_prefix_variants() {
  need git
  need jq

  tmp="${TMPDIR:-/tmp}/genchlg.repo.$$"
  setup_repo "$tmp"

  (cd "$tmp" && {
    # issue/1
    git checkout -q -b br1
    body1="- timestamp: 1000
- issue: https://example.com/issue/1"
    mkcommit "feat: first attempt" "$body1" 1000
    rm -f CHANGELOG.json
    "$SCRIPT_ABS" br1 >/dev/null

    # issue/2 (new entry)
    git checkout -q main
    git checkout -q -b br3
    body2="- timestamp: 3000
- issue: https://example.com/issue/2"
    mkcommit "feat: other issue" "$body2" 3000
    "$SCRIPT_ABS" br3 >/dev/null

    len="$(jq -r 'length' CHANGELOG.json)"
    assert_eq "2" "$len" "different issue must create new entry"
    issues="$(jq -r 'map(.meta.issue) | sort | join(",")' CHANGELOG.json)"
    assert_eq "https://example.com/issue/1,https://example.com/issue/2" "$issues" "issues present"

    # issue prefix variant: no "issue:" prefix, should store URL as-is
    git checkout -q main
    git checkout -q -b br4
    body3="- timestamp: 4000
- https://example.com/issue/3"
    mkcommit "feat: issue prefix variant" "$body3" 4000
    "$SCRIPT_ABS" br4 >/dev/null
    has3="$(jq -r 'any(.meta.issue == "https://example.com/issue/3")' CHANGELOG.json)"
    assert_eq "true" "$has3" "issue line without prefix should still store URL"
  })

  rm -rf "$tmp"
  pass "selftest_different_issue_new_entry_and_issue_prefix_variants"
}

selftest_missing_body_bullets_fails_fast() {
  need git
  need jq

  tmp="${TMPDIR:-/tmp}/genchlg.repo.$$"
  setup_repo "$tmp"

  (cd "$tmp" && {
    git checkout -q -b br_bad
    # commit with no "- " body bullets at all
    mkcommit "feat: bad body" "" 5000

    rm -f CHANGELOG.json
    if out="$("$SCRIPT_ABS" br_bad 2>&1)"; then
      fail "missing body bullets: expected failure, got success (out=$out)"
    fi
    assert_match "$out" "error: first commit body must contain bullets" "missing bullets error message"
    [ ! -f CHANGELOG.json ] || fail "missing bullets: should not create/overwrite CHANGELOG.json on failure"
  })

  rm -rf "$tmp"
  pass "selftest_missing_body_bullets_fails_fast"
}

# -------------------------
# Selftest entry point
# -------------------------
if [ "${1:-}" = "--selftest" ]; then
  selftest_noargs
  selftest_jq_missing
  selftest_fresh_file_creation_and_metrics
  selftest_idempotency_by_commit_hash
  selftest_second_attempt_same_issue_new_first_commit
  selftest_different_issue_new_entry_and_issue_prefix_variants
  selftest_missing_body_bullets_fails_fast
  echo "ALL SELFTESTS PASSED" >&2
  exit 0
fi

# -------------------------
# Main script
# -------------------------
command -v jq >/dev/null 2>&1 || { echo "error: jq not installed" >&2; exit 1; }

BR="${1:?usage: $SCRIPT_ABS <branch>}"
BASE=main
F=CHANGELOG.json
range="$BASE..$BR"

FIRST="$(git rev-list --reverse "$range" | sed -n '1p')"
[ -n "$FIRST" ] || { echo "error: no commits found in range $range" >&2; exit 1; }

SUBJ="$(git show -s --format=%s "$FIRST")"

# First two "- " bullets from the FIRST commit body
B1="$(git show -s --format=%b "$FIRST" | sed -n 's/^- //p;1q')"
B2="$(git show -s --format=%b "$FIRST" | sed -n 's/^- //p' | sed -n '2p')"

# Fail fast if bullets missing
if [ -z "${B1:-}" ] || [ -z "${B2:-}" ]; then
  echo "error: first commit body must contain bullets:" >&2
  echo "  - timestamp: <unix>" >&2
  echo "  - issue: <url>" >&2
  exit 1
fi

START_UNIX="$(printf %s "$B1" | sed 's/.*timestamp[: ]*//; s/[^0-9].*$//')"
ISSUE_LINK="$(printf %s "$B2" | sed 's/^[[:space:]]*//; s/^issue[: ]*//')"

# Validate parsed fields
case "$START_UNIX" in
  ''|*[!0-9]*) echo "error: could not parse unix timestamp from first bullet: $B1" >&2; exit 1 ;;
esac
case "$ISSUE_LINK" in
  http://*|https://*) : ;;
  *) echo "error: could not parse issue url from second bullet: $B2" >&2; exit 1 ;;
esac

ATT_UNIX="$(git show -s --format=%ct "$BR")"
COMMITREF="$(printf %.7s "$FIRST")"

[ -f "$F" ] || printf '[]\n' >"$F"

jq -c \
  --arg issue "$ISSUE_LINK" \
  --arg summary "$SUBJ" \
  --arg commitTitle "$SUBJ" \
  --arg commitRef "$COMMITREF" \
  --arg start_unix "$START_UNIX" \
  --arg att_unix "$ATT_UNIX" \
  '
  def iso(u): (u|tonumber|todateiso8601|sub("Z$";".000Z"));
  def next_a(atts): ((atts|keys|map(ltrimstr("a")|tonumber)|max // 0) + 1) as $n | ("a"+($n|tostring));
  def attempt_obj:
    { started_at_unix: ($start_unix|tonumber),
      started_at_iso8601: iso($start_unix),
      attempted_at_unix: ($att_unix|tonumber),
      attempted_at_iso8601: iso($att_unix),
      commitTitle: $commitTitle,
      commitRef: $commitRef };

  def metrics(e):
    (e.meta.attempts // {}) as $a
    | ($a|keys|sort_by(ltrimstr("a")|tonumber)) as $ks
    | ($ks|map($a[.])) as $L
    | ($L|length) as $n
    | (if $n>0 then $L[0].started_at_unix else null end) as $occ
    | (if $n>0 then $L[-1].attempted_at_unix else null end) as $lastAtt
    | (if $n>0 then ($L|map(.attempted_at_unix - .started_at_unix)|add)/$n else null end) as $mttr
    | (if $n>1 then
          (($L|to_entries|map(select(.key>0)|(.value.started_at_unix - $L[.key-1].attempted_at_unix))|add))/($n-1)
        else null end) as $pickup
    | (if $n>0 then ($lastAtt - $occ) else null end) as $lead
    | (if $n>0 then (($n-1)/$n) else null end) as $cfr
    | e
    | .meta.attempts_len = $n
    | .meta.occurred_at_unix = $occ
    | .meta.occurred_at_iso8601 = (if $occ==null then null else iso($occ) end)
    | .meta.lead_time_seconds = $lead
    | .meta.mean_time_to_recovery_seconds = $mttr
    | .meta.pickup_frequency_seconds = $pickup
    | .meta.change_failure_rate = $cfr;

  def has_commitref(e):
    ((e.meta.attempts // {}) | to_entries | any(.value.commitRef == $commitRef));

  def maybe_add_attempt(e):
    if has_commitref(e) then e else
      (e.meta.attempts // {}) as $atts
      | next_a($atts) as $k
      | e
      | .meta.issue = $issue
      | .meta.attempts = ($atts + {($k): attempt_obj})
      | metrics(.)
    end;

  map(if .meta.issue == $issue then maybe_add_attempt(.) else . end) as $m
  | if ($m|any(.meta.issue == $issue)) then
      $m
    else
      [ maybe_add_attempt({summary:$summary, meta:{issue:$issue, attempts:{}}}) ] + .
    end
  ' \
  "$F" >"$F.tmp" && mv "$F.tmp" "$F"

echo "updated $F for $BR ($ISSUE_LINK)"

