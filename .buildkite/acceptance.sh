#!/usr/bin/env bash
# One independent complete acceptance invocation. Provisioning precedes the
# guarded Bundler/Rake command; artifacts survive failures and are never reused.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd -P)"
mode="${1:?usage: acceptance.sh legacy|split}"
case "$mode" in legacy|split) ;; *) exit 2 ;; esac
test "$#" -eq 1

unset ACT_RESOLVED_COMPOSITION ACT_SPLIT_DEVELOPMENT_ROOT ACT_COMPONENT_ROOT
unset ACT_COVERAGE_CONTEXT ACT_TEST_QUALIFY ACT_TEST_HANG_SECONDS RUBYOPT
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
export ACT_IMPLEMENTATION="$mode" BUNDLE_FROZEN=true BUNDLE_GEMFILE="$root/Gemfile"
# Coverage's source census and Ruby's compiler must use the same spelling of
# macOS temporary roots, including /var -> /private/var aliases.
TMPDIR="$(ruby -rtmpdir -e 'puts File.realpath(Dir.tmpdir)')"
export TMPDIR
test -n "${ACT_TEST_POLICY:-}"
test -f "$ACT_TEST_POLICY"
mkdir -p tmp
evidence="$(mktemp -d "tmp/ci-${mode}.XXXXXXXX")"
artifacts="$evidence/artifacts"
mkdir "$artifacts"

# Upload exactly this invocation, including partial logs on failure. An upload
# failure cannot turn a failed test green, and also prevents a successful job.
function upload_evidence() {
  status=$?
  trap - EXIT
  buildkite-agent artifact upload "$artifacts/**/*" || { test "$status" -ne 0 || status=1; }
  exit "$status"
}
trap upload_evidence EXIT
cp split-composition.json "$artifacts/split-composition.json"
ruby --version
bundle --version
bundle install
if test "$mode" = split; then
  export ACT_COMPONENT_ROOT="$root/$evidence/components"
  ruby .buildkite/prepare_components.rb "$ACT_COMPONENT_ROOT" 2>&1 | tee "$artifacts/provision.log"
fi

# Each new interpreter resolves afresh. Only its own descendants inherit the
# frozen resolved composition. The probe never supplies coverage to test:all.
env -u ACT_RESOLVED_COMPOSITION -u ACT_SPLIT_DEVELOPMENT_ROOT \
  ruby -r "$root/test/support/no_git_execution.rb" -rbundler/setup \
  .buildkite/verify_implementation.rb "$mode" > "$artifacts/implementation.json"
cat "$artifacts/implementation.json"
set +e
env -u ACT_RESOLVED_COMPOSITION -u ACT_SPLIT_DEVELOPMENT_ROOT \
  PATH="$root/test/support/bin:$PATH" \
  RUBYOPT="-r$root/test/support/no_git_execution.rb" \
  bundle exec rake test:all 2>&1 | tee "$artifacts/acceptance.log"
statuses=("${PIPESTATUS[@]}")
set -e
status="${statuses[0]}"
if test "${statuses[1]}" -ne 0 && test "$status" -eq 0; then status=1; fi
# Finalization preserves the harness evidence before checking its result.
collection_status=0
ruby .buildkite/collect_evidence.rb "$artifacts" "$mode" "$status" || collection_status=$?
test "$status" -eq 0 || exit "$status"
exit "$collection_status"
