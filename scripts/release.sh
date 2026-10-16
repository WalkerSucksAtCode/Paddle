#!/usr/bin/env bash
# Paddle: build a Developer ID-signed Release, verify it, zip it, and optionally notarize and install it.
# Local Mac only (needs the Developer ID identity in the login keychain).
#
# Usage:
#   scripts/release.sh                       build, sign, verify, zip to dist/Paddle-<v>-<b>-unnotarized.zip
#   scripts/release.sh --notarize            ... notarize, staple, Gatekeeper check, then dist/Paddle-<v>-<b>.zip
#   scripts/release.sh --install             ... then quit Paddle and replace /Applications/Paddle.app
#   scripts/release.sh --notarize --install  both (installs the stapled app)
#
# Env:
#   NOTARY_PROFILE  notarytool keychain profile (default: walker-notary). Never run store-credentials here.
#   SIGN_IDENTITY   codesign identity (default: "Developer ID Application"). Pass a SHA-1 from
#                   `security find-identity -v -p codesigning` if two Developer ID certificates match.
#
# Every step prints PASS or FAIL; steps that did not run are listed as SKIP in the summary. A command that fails
# outside a check (or Ctrl-C) marks the step it was in as FAIL through the ERR/INT traps.
# Only a notarized, stapled build is written to dist/ without the -unnotarized suffix.
# Signing is set on the xcodebuild command line only; project.yml stays on automatic Apple Development signing.
# CURRENT_PROJECT_VERSION is the commit count on the command line (project.yml's "1" stays the Debug value), so
# each release has its own build number: <b> in the zip names and the install line is the built app's CFBundleVersion.
# CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO keeps Xcode from adding get-task-allow, which it otherwise does here.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="com.walker.Paddle"
TEAM_ID="VB3UP263YT"
NOTARY_PROFILE="${NOTARY_PROFILE:-walker-notary}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
DERIVED="$ROOT/build/ReleaseDerivedData.noindex"
APP="$DERIVED/Build/Products/Release/Paddle.app"
DIST="$ROOT/dist"
LOG_DIR="$ROOT/build/release-logs"
SCRATCH="$ROOT/build/release-scratch"
INSTALL_PATH="/Applications/Paddle.app"

NOTARIZE=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --notarize) NOTARIZE=1 ;;
    --install) INSTALL=1 ;;
    -h|--help) awk 'NR > 1 && !/^#/ {exit} NR > 1 {print}' "$0"; exit 0 ;;
    *) echo "unknown option: $arg (use --notarize, --install)" >&2; exit 2 ;;
  esac
done

STEPS=(build verify entitlements zip)
if [[ $NOTARIZE -eq 1 ]]; then STEPS+=(notarize staple gatekeeper); fi
if [[ $INSTALL -eq 1 ]]; then STEPS+=(install); fi

# Step results live in RESULT_<step> (macOS /bin/bash is 3.2: no associative arrays).
summary() {
  echo
  echo "== summary =="
  local step var
  for step in build verify entitlements zip notarize staple gatekeeper install; do
    var="RESULT_$step"
    printf '  %-13s %s\n' "$step" "${!var:-SKIP (not run)}"
  done
}
trap summary EXIT

CURRENT_STEP=""
pass() { printf -v "RESULT_$1" '%s' PASS; echo "PASS: $1${2:+ — $2}"; }
fail() { printf -v "RESULT_$1" '%s' FAIL; echo "FAIL: $1 — $2" >&2; exit 1; }
step() { CURRENT_STEP="$1"; echo; echo "== $1 =="; }
# An unchecked command failing under set -e (e.g. a PlistBuddy or codesign substitution) or Ctrl-C would otherwise
# exit with the step still unset, which the summary shows as SKIP.
on_err() {
  local rc=$?
  [[ -n "$CURRENT_STEP" ]] && printf -v "RESULT_$CURRENT_STEP" '%s' "FAIL (command exited $rc)"
  echo "FAIL: ${CURRENT_STEP:-setup} — a command exited $rc" >&2
}
on_int() {
  [[ -n "$CURRENT_STEP" ]] && printf -v "RESULT_$CURRENT_STEP" '%s' "FAIL (interrupted)"
  exit 130
}
trap on_err ERR
trap on_int INT TERM

mkdir -p "$LOG_DIR" "$DIST" "$SCRATCH"
echo "Paddle release: steps ${STEPS[*]}"
echo "repo: $ROOT"

# ---- build ---------------------------------------------------------------------------------------
step build
BUILD_LOG="$LOG_DIR/xcodebuild.log"
echo "xcodebuild Release -> $DERIVED (log: $BUILD_LOG)"
if ! xcodebuild -project "$ROOT/Paddle.xcodeproj" -scheme Paddle -configuration Release \
    -derivedDataPath "$DERIVED" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PROVISIONING_PROFILE_SPECIFIER= \
    OTHER_CODE_SIGN_FLAGS=--timestamp \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    CURRENT_PROJECT_VERSION="$(git -C "$ROOT" rev-list --count HEAD)" \
    clean build >"$BUILD_LOG" 2>&1; then
  grep -E 'error:|BUILD FAILED' "$BUILD_LOG" | tail -20 >&2 || true
  fail build "xcodebuild failed, see $BUILD_LOG"
fi
[[ -d "$APP" ]] || fail build "no app at $APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
pass build "Paddle $VERSION ($BUILD_NUMBER)"

# ---- verify --------------------------------------------------------------------------------------
step verify
if ! codesign --verify --deep --strict --verbose=2 "$APP"; then
  fail verify "codesign --verify --deep --strict rejected $APP"
fi
SIGN_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1)"
echo "$SIGN_INFO"
grep -q "^Authority=Developer ID Application: .*($TEAM_ID)" <<<"$SIGN_INFO" \
  || fail verify "not signed with a Developer ID Application certificate for team $TEAM_ID"
grep -q "^TeamIdentifier=$TEAM_ID" <<<"$SIGN_INFO" || fail verify "TeamIdentifier is not $TEAM_ID"
grep -Eq '^CodeDirectory .*flags=.*runtime' <<<"$SIGN_INFO" || fail verify "hardened runtime flag missing"
grep -q '^Timestamp=' <<<"$SIGN_INFO" || fail verify "no secure timestamp (OTHER_CODE_SIGN_FLAGS=--timestamp)"
HELPER="$APP/Contents/Helpers/paddle-mcp"
[[ -x "$HELPER" ]] || fail verify "paddle-mcp helper missing at $HELPER"
HELPER_INFO="$(codesign -dv --verbose=4 "$HELPER" 2>&1)"
grep -q "^Authority=Developer ID Application: .*($TEAM_ID)" <<<"$HELPER_INFO" || fail verify "paddle-mcp is not Developer ID signed for team $TEAM_ID"
grep -Eq '^CodeDirectory .*flags=.*runtime' <<<"$HELPER_INFO" || fail verify "paddle-mcp lacks the hardened runtime flag"
grep -q '^Timestamp=' <<<"$HELPER_INFO" || fail verify "paddle-mcp has no secure timestamp"
pass verify "Developer ID, hardened runtime, timestamped (app and paddle-mcp)"

# ---- entitlements --------------------------------------------------------------------------------
step entitlements
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
if [[ -z "$ENTITLEMENTS" ]]; then
  fail entitlements "could not read entitlements"
fi
echo "$ENTITLEMENTS"
if grep -q 'get-task-allow' <<<"$ENTITLEMENTS"; then
  fail entitlements "com.apple.security.get-task-allow is present (debug entitlement; notarization rejects it)"
fi
pass entitlements "no get-task-allow"

# ---- zip -----------------------------------------------------------------------------------------
# make_zip <dest>: zips $APP via a temporary name; mv replaces an older <dest> in one step, so <dest> is never
# missing or half-written.
make_zip() {
  local dest="$1"
  rm -f "$dest.partial"
  ditto -c -k --keepParent "$APP" "$dest.partial" && mv "$dest.partial" "$dest"
}
ZIP_BASE="Paddle-$VERSION-$BUILD_NUMBER"
FINAL_ZIP="$DIST/$ZIP_BASE.zip"
if [[ $NOTARIZE -eq 1 ]]; then
  # Submission copy only; nothing reaches dist/ until notarize and staple pass.
  ZIP="$SCRATCH/$ZIP_BASE-unnotarized.zip"
else
  ZIP="$DIST/$ZIP_BASE-unnotarized.zip"
fi
step zip
make_zip "$ZIP" || fail zip "ditto could not create $ZIP"
pass zip "$ZIP ($(du -h "$ZIP" | cut -f1 | tr -d ' '))"

# ---- notarize, staple, gatekeeper ----------------------------------------------------------------
if [[ $NOTARIZE -eq 1 ]]; then
  step notarize
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    fail notarize "keychain profile '$NOTARY_PROFILE' is missing or unusable (do not run store-credentials from here)"
  fi
  NOTARY_LOG="$LOG_DIR/notarytool.log"
  echo "\$ xcrun notarytool submit $ZIP --keychain-profile $NOTARY_PROFILE --wait"
  set +e
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "$NOTARY_LOG"
  SUBMIT_RC=${PIPESTATUS[0]}
  set -e
  SUBMISSION_ID="$(awk '/^ *id:/{print $2; exit}' "$NOTARY_LOG" || true)"
  STATUS="$(awk '/^ *status:/{s=$2} END{print s}' "$NOTARY_LOG" || true)"
  if [[ $SUBMIT_RC -ne 0 || "$STATUS" != "Accepted" ]]; then
    if [[ -n "$SUBMISSION_ID" ]]; then
      xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" 2>&1 || true
    fi
    fail notarize "status ${STATUS:-unknown} (rc $SUBMIT_RC, submission ${SUBMISSION_ID:-unknown})"
  fi
  pass notarize "Accepted, submission $SUBMISSION_ID"

  step staple
  xcrun stapler staple "$APP" || fail staple "stapler staple failed"
  xcrun stapler validate "$APP" || fail staple "stapler validate failed"
  make_zip "$FINAL_ZIP" || fail staple "could not zip the stapled app to $FINAL_ZIP"
  rm -f "$ZIP"
  pass staple "ticket stapled; $FINAL_ZIP ($(du -h "$FINAL_ZIP" | cut -f1 | tr -d ' '))"

  step gatekeeper
  spctl -a -vv "$APP" 2>&1 || fail gatekeeper "spctl rejected $APP"
  pass gatekeeper "spctl accepts $APP"
fi

# ---- install -------------------------------------------------------------------------------------
# pgrep: 0 = running, 1 = not running, anything else = could not tell (treated as a failure, never as "not running").
# Matches any process named Paddle, including a debug build, so it errs toward waiting rather than replacing a live app.
paddle_running() {
  local rc=0
  pgrep -x Paddle >/dev/null || rc=$?
  case $rc in
    0) return 0 ;;
    1) return 1 ;;
    *) fail install "could not tell whether Paddle is running (pgrep exited $rc)" ;;
  esac
}

if [[ $INSTALL -eq 1 ]]; then
  step install
  if paddle_running; then
    echo "Quitting Paddle…"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do
      paddle_running || break
      sleep 0.5
    done
    if paddle_running; then
      fail install "Paddle is still running after 30 s (a download prompt may be open, or a debug build is running); quit it and run again"
    fi
  fi
  STAGING="/Applications/.Paddle.app.installing"
  BACKUP="/Applications/.Paddle.app.old"
  # Until the swap finishes, any exit removes the staged copy and puts a moved-aside old app back.
  SWAPPED=0
  cleanup_install() {
    rm -rf "$STAGING"
    if [[ $SWAPPED -eq 0 && -d "$BACKUP" && ! -e "$INSTALL_PATH" ]]; then
      mv "$BACKUP" "$INSTALL_PATH" && echo "Restored the previous $INSTALL_PATH" >&2
    fi
  }
  trap 'cleanup_install; summary' EXIT

  # A leftover $BACKUP may be the only copy of the old app (an earlier swap was interrupted), so it is not
  # removed here; it goes only once the new copy is staged and verified, below.
  rm -rf "$STAGING"
  ditto "$APP" "$STAGING" || fail install "could not copy to $STAGING"
  codesign --verify --deep --strict "$STAGING" || fail install "staged copy fails codesign --verify; $INSTALL_PATH untouched"
  if [[ $NOTARIZE -eq 1 ]]; then
    xcrun stapler validate "$STAGING" || fail install "staged copy has no valid stapled ticket; $INSTALL_PATH untouched"
  fi

  if [[ -e "$INSTALL_PATH" ]]; then
    # $INSTALL_PATH exists, so a $BACKUP beside it is stale; without one, $BACKUP is kept until the swap is done.
    rm -rf "$BACKUP"
    mv "$INSTALL_PATH" "$BACKUP" || fail install "could not move the old app aside to $BACKUP"
  fi
  if ! mv "$STAGING" "$INSTALL_PATH"; then
    fail install "could not move the new app into $INSTALL_PATH (previous app restored)"
  fi
  if ! codesign --verify --deep --strict "$INSTALL_PATH"; then
    rm -rf "$INSTALL_PATH"
    fail install "installed copy fails codesign --verify (previous app restored)"
  fi
  SWAPPED=1
  rm -rf "$BACKUP"
  INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALL_PATH/Contents/Info.plist")"
  INSTALLED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALL_PATH/Contents/Info.plist")"

  # Gatekeeper's verdict on the installed copy. An unnotarized build is rejected here but still opens locally,
  # because a locally built copy carries no quarantine flag; say so instead of passing silently.
  # The exit code is caught inside the substitution: with errtrace on, a bare failing spctl in $(...) fires the ERR
  # trap (a false "FAIL: install") before an outer `||` could handle it.
  GK_RC=0
  GK_OUT="$(spctl -a -vv "$INSTALL_PATH" 2>&1 || echo "__spctl_rc=$?")"
  if [[ "$GK_OUT" == *"__spctl_rc="* ]]; then
    GK_RC="${GK_OUT##*__spctl_rc=}"
    GK_OUT="${GK_OUT%__spctl_rc=*}"
  fi
  echo "$GK_OUT"
  if [[ $GK_RC -eq 0 ]]; then
    GK_NOTE="Gatekeeper accepts it"
  elif [[ $NOTARIZE -eq 1 ]]; then
    fail install "$INSTALL_PATH is Paddle $INSTALLED_VERSION ($INSTALLED_BUILD) but spctl rejects the notarized copy"
  else
    GK_NOTE="UNNOTARIZED: Gatekeeper rejects it; opens locally only because it is not quarantined"
  fi
  pass install "$INSTALL_PATH is Paddle $INSTALLED_VERSION ($INSTALLED_BUILD); $GK_NOTE"
fi
