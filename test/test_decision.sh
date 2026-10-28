#!/bin/bash
# Runs the decision script from the reusable workflow against a stubbed `gh`.
# Usage: test/test_decision.sh   (needs uv, jq and bash)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORKFLOW="$HERE/../.github/workflows/dependabot-auto-merge.yml"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; mkdir "$T/bin" "$T/work"
# Files in the working directory, to prove glob patterns are not expanded by the shell.
touch "$T/work/uv.lock" "$T/work/other.lock"
# Find the step by name, so reordering steps doesn't silently test the wrong one.
uv run --quiet --no-project --with pyyaml python - "$WORKFLOW" "$T/run.sh" <<'PY' || exit 1
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["auto-merge"]["steps"]
[run] = [s["run"] for s in steps if s.get("name") == "Arm auto-merge if low risk"]
open(sys.argv[2], "w").write(run)
PY
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
case "$1 $2" in
  "pr diff")
      [ -n "${FAKE_DIFF_ERR:-}" ] && { echo "HTTP 406: diff too large" >&2; exit 1; }
      printf '%s\n' $FAKE_FILES ;;
  "pr merge") echo "ARMED $4" ;;
  "pr review") [ -n "${FAKE_REVIEW_ERR:-}" ] && { echo "HTTP 403" >&2; exit 1; }; echo "APPROVED" ;;
  "api repos/o/r/branches/master")
      [ -n "${FAKE_CLASSIC_ERR:-}" ] && { echo "HTTP 403" >&2; exit 1; }
      echo "{\"protection\":{\"required_status_checks\":{\"contexts\":[${FAKE_CONTEXTS:-}]}}}" ;;
  "api repos/o/r/rules/branches/master")
      [ -n "${FAKE_RULES_ERR:-}" ] && { echo "HTTP 403" >&2; exit 1; }
      echo "${FAKE_RULES:-[]}" ;;
  *) echo "unexpected gh $*" >&2; exit 9 ;;
esac
STUB
chmod +x "$T/bin/gh"
fail=0
check() { # name expected(ARMED|SKIP, +APPROVED, !FAIL) env...
  name=$1; want=$2; shift 2
  out=$(cd "$T/work" && env PATH="$T/bin:$PATH" GH_TOKEN=x PR_URL=https://x/pull/1 REPO=o/r BASE=master \
    REQUIRED_CHECK=test ALLOWED_FILES="uv.lock pyproject.toml" MERGE_METHOD=squash APPROVE=false "$@" bash "$T/run.sh" 2>&1)
  rc=$?
  got=SKIP
  grep -q '^ARMED' <<<"$out" && got=ARMED
  grep -q '^APPROVED' <<<"$out" && got+="+APPROVED"
  [ "$rc" -ne 0 ] && got+="!FAIL"
  if [ "$got" = "$want" ]; then echo "ok   $name"; else echo "FAIL $name: wanted $want, got $got: $out"; fail=1; fi
}
# Like check, but also asserts the merge flag passed to `gh pr merge`.
check_method() { # name method
  out=$(cd "$T/work" && env PATH="$T/bin:$PATH" GH_TOKEN=x PR_URL=https://x/pull/1 REPO=o/r BASE=master \
    REQUIRED_CHECK=test ALLOWED_FILES="uv.lock" MERGE_METHOD="$2" APPROVE=false \
    DEPS="$MIN" FAKE_FILES="uv.lock" FAKE_CONTEXTS='"test"' bash "$T/run.sh" 2>&1)
  if grep -qx -- "ARMED --$2" <<<"$out"; then echo "ok   $1"; else echo "FAIL $1: $out"; fail=1; fi
}
MIN='[{"updateType":"version-update:semver-minor"},{"updateType":"version-update:semver-patch"}]'
RS_TEST='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"test"}]}}]'
RS_OTHER='[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"lint"}]}}]'
RS_NOCHECKS='[{"type":"code_scanning","parameters":{}},{"type":"pull_request","parameters":{}}]'

echo "# update types"
check "minor+patch group"          ARMED DEPS="$MIN" FAKE_FILES="uv.lock" FAKE_CONTEXTS='"test"'
check "contains a major"           SKIP  DEPS='[{"updateType":"version-update:semver-patch"},{"updateType":"version-update:semver-major"}]' FAKE_FILES="uv.lock" FAKE_CONTEXTS='"test"'
check "range update, no type"      SKIP  DEPS='[{"dependencyName":"mcp"}]' FAKE_FILES="pyproject.toml" FAKE_CONTEXTS='"test"'
check "empty dependency list"      SKIP  DEPS='[]' FAKE_FILES="uv.lock" FAKE_CONTEXTS='"test"'
check "no metadata output"         SKIP  DEPS='' FAKE_FILES="uv.lock" FAKE_CONTEXTS='"test"'

echo "# allowed files (exact names)"
check "with pyproject floor"       ARMED DEPS="$MIN" FAKE_FILES="uv.lock pyproject.toml" FAKE_CONTEXTS='"test","x"'
check "touches a source file"      SKIP  DEPS="$MIN" FAKE_FILES="uv.lock src/app.py" FAKE_CONTEXTS='"test"'
check "file list errors"           SKIP  DEPS="$MIN" FAKE_DIFF_ERR=1 FAKE_CONTEXTS='"test"'

echo "# allowed files (globs, Maven)"
check "multi-module poms"          ARMED DEPS="$MIN" ALLOWED_FILES='**/pom.xml' REQUIRED_CHECK=build FAKE_FILES="pom.xml module-a/pom.xml module-b/sub/pom.xml" FAKE_CONTEXTS='"build"'
check "root pom only, **/ glob"    ARMED DEPS="$MIN" ALLOWED_FILES='**/pom.xml' REQUIRED_CHECK=build FAKE_FILES="pom.xml" FAKE_CONTEXTS='"build"'
check "pom plus java source"       SKIP  DEPS="$MIN" ALLOWED_FILES='**/pom.xml' REQUIRED_CHECK=build FAKE_FILES="module-a/pom.xml module-a/src/Main.java" FAKE_CONTEXTS='"build"'
check "lookalike pom.xml.bak"      SKIP  DEPS="$MIN" ALLOWED_FILES='**/pom.xml' REQUIRED_CHECK=build FAKE_FILES="pom.xml.bak" FAKE_CONTEXTS='"build"'
check "glob not shell-expanded"    ARMED DEPS="$MIN" ALLOWED_FILES='*.lock' FAKE_FILES="x.lock" FAKE_CONTEXTS='"test"'

echo "# required check: classic protection"
check "check not required"         SKIP  DEPS="$MIN" FAKE_FILES="uv.lock" FAKE_CONTEXTS='"other"'
check "no protection"              SKIP  DEPS="$MIN" FAKE_FILES="uv.lock" FAKE_CONTEXTS=''

echo "# required check: rulesets"
check "ruleset requires check"     ARMED DEPS="$MIN" FAKE_FILES="uv.lock" FAKE_CONTEXTS='' FAKE_RULES="$RS_TEST"
check "ruleset requires other"     SKIP  DEPS="$MIN" FAKE_FILES="uv.lock" FAKE_CONTEXTS='' FAKE_RULES="$RS_OTHER"
check "ruleset has no status rule" SKIP  DEPS="$MIN" FAKE_FILES="uv.lock" FAKE_CONTEXTS='' FAKE_RULES="$RS_NOCHECKS"
check "rules API errors"           SKIP  DEPS="$MIN" FAKE_FILES="uv.lock" FAKE_CONTEXTS='' FAKE_RULES_ERR=1
check "classic errors, ruleset ok" ARMED DEPS="$MIN" FAKE_FILES="uv.lock" FAKE_CLASSIC_ERR=1 FAKE_RULES="$RS_TEST"
check "both APIs error"            SKIP  DEPS="$MIN" FAKE_FILES="uv.lock" FAKE_CLASSIC_ERR=1 FAKE_RULES_ERR=1

echo "# merge method"
check_method "squash passed through" squash
check_method "merge passed through"  merge
check_method "rebase passed through" rebase
check "admin rejected"             SKIP!FAIL DEPS="$MIN" FAKE_FILES="uv.lock" FAKE_CONTEXTS='"test"' MERGE_METHOD=admin
check "empty method rejected"      SKIP!FAIL DEPS="$MIN" FAKE_FILES="uv.lock" FAKE_CONTEXTS='"test"' MERGE_METHOD=

echo "# opt-in approval"
check "approve off by default"       ARMED           DEPS="$MIN" FAKE_FILES="uv.lock" FAKE_CONTEXTS='"test"'
check "approve=false explicit"       ARMED           DEPS="$MIN" FAKE_FILES="uv.lock" FAKE_CONTEXTS='"test"' APPROVE=false
check "approve=true, all gates pass" ARMED+APPROVED  DEPS="$MIN" FAKE_FILES="uv.lock" FAKE_CONTEXTS='"test"' APPROVE=true
check "approve=true via ruleset"     ARMED+APPROVED  DEPS="$MIN" FAKE_FILES="uv.lock" FAKE_CONTEXTS='' FAKE_RULES="$RS_TEST" APPROVE=true
check "approve=true, major bump"     SKIP            DEPS='[{"updateType":"version-update:semver-major"}]' FAKE_FILES="uv.lock" FAKE_CONTEXTS='"test"' APPROVE=true
check "approve=true, extra file"     SKIP            DEPS="$MIN" FAKE_FILES="uv.lock src/app.py" FAKE_CONTEXTS='"test"' APPROVE=true
check "approve=true, check missing"  SKIP            DEPS="$MIN" FAKE_FILES="uv.lock" FAKE_CONTEXTS='"other"' APPROVE=true
check "approve=true, no protection"  SKIP            DEPS="$MIN" FAKE_FILES="uv.lock" FAKE_CONTEXTS='' APPROVE=true
check "approve fails after arming"   ARMED!FAIL      DEPS="$MIN" FAKE_FILES="uv.lock" FAKE_CONTEXTS='"test"' APPROVE=true FAKE_REVIEW_ERR=1
exit $fail
