#!/bin/bash
#
# Submit the app to Apple, then staple the ticket to it.
#
# Signing and notarising are different things and it is easy to think the first
# is the second. A Developer ID signature says who built it; notarisation is
# Apple saying they scanned it. Without the second, Gatekeeper on any machine
# other than this one refuses the app with a dialog that says it "cannot be
# opened because the developer cannot be verified" - which reads as an expired
# or missing certificate rather than a missing scan.
#
#   ./notarize.sh --profile notebookmlx-notary
#
# Create the profile once with, and note the absent --password so it prompts
# rather than putting a live Apple credential in shell history:
#   xcrun notarytool store-credentials notebookmlx-notary \
#     --apple-id you@example.com --team-id TEAMID
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/NotebookMLX.app"
PROFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --app)     APP="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$PROFILE" ]] || { echo "--profile is required" >&2; exit 2; }
[[ -d "$APP" ]] || { echo "no app at $APP - run make-app.sh first" >&2; exit 2; }

# Checked here rather than left to Apple, because the rejection comes back as a
# log URL several minutes later and names the flag rather than the fix.
FLAGS="$(codesign -dv "$APP" 2>&1 | sed -n 's/.*flags=\([^ ]*\).*/\1/p')"
case "$FLAGS" in
  *runtime*) ;;
  *) echo "not signed with the hardened runtime; Apple will refuse it." >&2
     echo "run make-app.sh with a Developer ID in the keychain." >&2
     exit 1 ;;
esac
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
  # The entitlement that lets a debugger attach. Harmless locally and an
  # automatic rejection here, and it arrives by accident: SwiftPM puts it on
  # every binary it ad-hoc signs.
  echo "get-task-allow is present; Apple refuses notarisation with it." >&2
  exit 1
fi

# ditto, not zip. A plain zip flattens symlinks and drops the extended
# attributes the signature is stored in, so the upload is a bundle Apple reads
# as unsigned - and the rejection blames the signature rather than the archive.
ZIP="$ROOT/.build/NotebookMLX.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP"

echo "==> submitting $(basename "$APP") to Apple"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

# Stapled to the .app, not to the zip. The ticket has to travel with the thing
# somebody opens, and the archive was only ever the transport - an unstapled app
# has to reach Apple to be checked, so it fails on a machine that is offline or
# behind a filter, which is the worst kind of intermittent.
echo "==> stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# The whole point, asserted rather than assumed. This is the check that fails on
# somebody else's Mac, so it is the one worth running here.
echo "==> what Gatekeeper says"
spctl -a -vv "$APP"
