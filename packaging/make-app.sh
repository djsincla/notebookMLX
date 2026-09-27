#!/bin/bash
#
# Wrap the executable into a .app bundle.
#
# A SwiftUI binary run straight from `swift run` has no bundle, so macOS treats
# it as a background process: it starts, it never activates, and it shows no
# window. That is not a SwiftUI problem and no amount of `activate(ignoringOther)`
# fixes it properly. The bundle is what makes it an app.
#
# Xcode will own this later, when the document type needs declaring. Until then
# this is enough to look at.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/.build/NotebookMLX.app"

swift build -c "$CONFIG" --package-path "$ROOT" --product NotebookApp >/dev/null
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/NotebookApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotebookMLX"

# The Metal shader library, without which every GPU call aborts.
#
# SwiftPM cannot compile MLX's Metal shaders, which is why the agent is built
# with xcodebuild and ships mlx-swift_Cmlx.bundle beside its binary. Rather than
# stand up a second xcodebuild for this package, the agent's already-built
# bundle is borrowed: it is the same vendored mlx-swift, by path, so it is the
# same shaders. If the agent has not been built, embedding will abort with
# "Failed to load the default metallib" and this says so now instead.
# Where to look for it. This was a single relative path into `../agent`, which
# was correct while this app lived inside dAI's tree and broke silently the day
# it moved out: the warning below is easy to miss and the app it produces aborts
# at the first embedding with "Failed to load the default metallib".
#
# So: an explicit override first, then a sibling dAI checkout, then the old
# in-tree layout for anyone who still has one.
CMLX_REL="Build/Products/Release/mlx-swift_Cmlx.bundle"
CMLX=""
for candidate in \
  "${DAI_CMLX_BUNDLE:-}" \
  "$ROOT/../dAI/agent/.xcbuild/$CMLX_REL" \
  "$ROOT/../agent/.xcbuild/$CMLX_REL"
do
  [[ -n "$candidate" && -d "$candidate" ]] || continue
  CMLX="$candidate"
  break
done
[[ -n "$CMLX" ]] || CMLX="$ROOT/../dAI/agent/.xcbuild/$CMLX_REL"
if [[ -d "$CMLX" ]]; then
  # Both locations, because the lookup differs by how the binary is launched.
  # A bare SwiftPM executable finds its package bundles beside itself; inside a
  # .app, Bundle.module resolves to Contents/Resources. Copying to only one is
  # how this shipped an app that ran from the command line and crashed on
  # launch with "Failed to load the default metallib".
  cp -R "$CMLX" "$APP/Contents/MacOS/"
  cp -R "$CMLX" "$APP/Contents/Resources/"
else
  echo "warning: no Metal shader bundle found" >&2
  echo "         looked for: $CMLX" >&2
  echo "         build dAI's agent with xcodebuild, or set DAI_CMLX_BUNDLE." >&2
  echo "         Without it embedding aborts at runtime with" >&2
  echo "         'Failed to load the default metallib'." >&2
fi

# The icon, if it has been built. Checked in rather than generated here so a
# build needs no SVG renderer; packaging/icon/make-icon.py regenerates the SVG
# and the README beside it says how to turn that back into an icns.
ICON="$ROOT/packaging/icon/AppIcon.icns"
if [ -f "$ICON" ]; then
  cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "warning: no icon at $ICON, the app will use the generic one" >&2
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>notebookMLX</string>
  <key>CFBundleDisplayName</key><string>notebookMLX</string>
  <key>CFBundleIdentifier</key><string>com.dai.notebookmlx</string>
  <key>CFBundleExecutable</key><string>NotebookMLX</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Regular, not accessory: it needs a Dock icon, a menu bar and focus. -->
  <key>LSUIElement</key><false/>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Dictation. Without these macOS refuses the microphone outright rather
       than asking, and the reason shown in the prompt is the only explanation
       anybody gets for why a notebook wants to listen. -->
  <key>NSMicrophoneUsageDescription</key>
  <string>notebookMLX listens only while you hold space or click the microphone, to turn a spoken question into text. Recognition happens on this Mac.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Your spoken question is recognised on this Mac and never sent anywhere.</string>
  <!-- Reach a local OpenAI-compatible server over plain http.
       App Transport Security blocks http:// by default, which is right for the
       internet and wrong for the thing this app is now built to do: LM Studio
       on 127.0.0.1:1234, Ollama on 11434, a vLLM on the bench next to you. All
       of them are http, and without this the request fails before it is sent,
       with an error about a secure connection rather than about the server.
       NSAllowsLocalNetworking is the narrow form - loopback, .local and
       unqualified names only. It does not permit arbitrary http to the
       internet, and a public endpoint is https anyway. -->
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
  <!-- The notebook package, declared so the Finder shows one file rather than
       a folder and the open panel can filter for it. -->
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.dai.notebook</string>
      <key>UTTypeDescription</key><string>dAI Notebook</string>
      <key>UTTypeConformsTo</key>
      <array><string>com.apple.package</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array><string>dainotebook</string></array>
      </dict>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>dAI Notebook</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSItemContentTypes</key>
      <array><string>com.dai.notebook</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Prefer a real signing identity, and fall back to ad-hoc.
#
# This is what makes a permission stick. TCC keys its grants on code signing
# identity: a Developer ID signature gives the same designated requirement on
# every build, so "allow Documents" is answered once. Ad-hoc signing hashes the
# binary instead, so every `swift build` presents a new identity and the grant
# silently stops applying - which is the failure this whole block exists to
# stop somebody hitting again.
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
if [ -n "$SIGN_ID" ]; then
  SIGN_AS="$SIGN_ID"
else
  # Ad-hoc still beats unsigned, but say why it is worse rather than leaving
  # somebody to discover it as an app that forgets its permissions.
  echo "note: no Developer ID found; signing ad-hoc." >&2
  echo "      macOS will treat each rebuild as a new app and ask again." >&2
  SIGN_AS="-"
fi

# Sign the bundle, not just the binary SwiftPM already ad-hoc signed.
#
# Without this the bundle carries `Sealed Resources=none`, `Info.plist=not
# bound`, and a signing identifier derived from the binary
# (`NotebookApp-5555...`) rather than the one in Info.plist. TCC keys its grants
# on code signing identity, so an app in that state cannot hold a Documents
# folder permission against `com.dai.notebookmlx`: the identifier it presents is
# not the identifier anybody grants, and `tccutil reset com.dai.notebookmlx`
# matches nothing.
#
# The symptom is that the notebook list comes back empty while the app can still
# write new notebooks to the same folder - `reload()` swallows the error from
# `contentsOfDirectory` and shows an empty shelf, which reads as "there are no
# notebooks" rather than "this app was not allowed to look".
#
# Ad-hoc, so the hash still changes on every build and macOS still treats each
# build as a new app. That is the remaining cost of not having a signing
# certificate, and it is a re-prompt rather than a silent denial.
# Nested bundles first: signing the outer one fails with "code object is not
# signed at all" while anything inside it is unsigned, and MLX ships a resource
# bundle that SwiftPM copies in without signing.
# The hardened runtime and a secure timestamp are both required for
# notarisation, and only meaningful with a real certificate - an ad-hoc build
# has nothing to timestamp against. No entitlements for MLX: dAI's agent signs the same
# MLX stack this way and Apple notarises it, so Metal shader loading out of the
# nested bundle works under library validation as long as both are signed by the
# same team, which they are.
if [ "$SIGN_AS" = "-" ]; then
  HARDEN=()
else
  HARDEN=(--timestamp --options runtime)
fi

find "$APP/Contents/MacOS" -name '*.bundle' -maxdepth 1 -exec \
  codesign --force "${HARDEN[@]}" --sign "$SIGN_AS" {} \;
# One entitlement, on the app only: the microphone, for dictation. The hardened
# runtime denies audio input to anything not entitled to it, silently - the
# prompt never appears and the recogniser hears nothing. The nested MLX bundle
# records nothing and needs none.
codesign --force "${HARDEN[@]}" --sign "$SIGN_AS" \
  --entitlements "$ROOT/packaging/NotebookMLX.entitlements" \
  --identifier com.dai.notebookmlx "$APP"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'


echo "$APP"
