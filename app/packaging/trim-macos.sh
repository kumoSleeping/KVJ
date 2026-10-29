#!/bin/bash
# Trim a deployed KVJ.app: Qt's deployment copies every Quick Controls style,
# network plugins, image formats and fat (x86_64 + arm64) binaries. KVJ uses the
# Basic style only and ships per architecture. Unused files cost disk, not RAM,
# but there is no reason to carry them.
#   trim-macos.sh <KVJ.app> [arch]
set -euo pipefail
APP="$1"
ARCH="${2:-$(uname -m)}"
C="$APP/Contents"
test -x "$C/MacOS/KVJ"

# 1. Styles other than Basic, and plugins KVJ never loads.
for style in FluentWinUI3 Fusion Imagine Material Universal iOS macOS; do
    rm -rf "$C/Resources/qml/QtQuick/Controls/$style"
done
rm -rf "$C/Resources/qml/QtQuick/NativeStyle"
for kind in fluentwinui3 fusion imagine material universal ios macos; do
    rm -f "$C/PlugIns/libqtquickcontrols2${kind}styleplugin.dylib" \
          "$C/PlugIns/libqtquickcontrols2${kind}styleimplplugin.dylib"
done
rm -f "$C/PlugIns/libqtquickcontrols2nativestyleplugin.dylib"
rm -rf "$C/PlugIns/styles" "$C/PlugIns/tls" "$C/PlugIns/networkinformation"
# Sound plays through AVFoundation (QT_MEDIA_BACKEND=darwin): no FFmpeg.
rm -f "$C/PlugIns/multimedia/libffmpegmediaplugin.dylib"
rm -f "$C"/Frameworks/libav*.dylib "$C"/Frameworks/libsw*.dylib
for format in "$C"/PlugIns/imageformats/*.dylib; do
    case "$(basename "$format")" in
        libqsvg.dylib|libqgif.dylib|libqjpeg.dylib|libqwebp.dylib) ;;
        *) rm -f "$format" ;;
    esac
done

# 2. Keep only the frameworks the executable and the remaining plugins reach.
# Bundled frameworks are referenced as @rpath/… or @executable_path/../Frameworks/…
deps() { otool -L "$1" | tail -n +2 | grep -v -E '^[[:space:]]*/(System|usr)/' | sed -n 's|.*/\([A-Za-z0-9]*\)\.framework/.*|\1|p'; }
needed=" "
queue=("$C/MacOS/KVJ")
while IFS= read -r plugin; do queue+=("$plugin"); done < <(find "$C/PlugIns" -name '*.dylib' -type f)
while [ ${#queue[@]} -gt 0 ]; do
    file="${queue[0]}"; queue=("${queue[@]:1}")
    for name in $(deps "$file"); do
        case "$needed" in *" $name "*) continue ;; esac
        needed="$needed$name "
        queue+=("$C/Frameworks/$name.framework/Versions/A/$name")
    done
done
for framework in "$C"/Frameworks/*.framework; do
    name="$(basename "$framework" .framework)"
    case "$needed" in *" $name "*) ;; *) rm -rf "$framework" ;; esac
done

for core in QtCore QtGui QtQml QtQuick; do
    test -d "$C/Frameworks/$core.framework" || { echo "trim: $core lost, dependency scan is wrong" >&2; exit 1; }
done

# 3. One architecture, no local symbols.
find "$C" -type f \( -perm -u+x -o -name '*.dylib' \) | while IFS= read -r file; do
    file "$file" | grep -q 'Mach-O' || continue
    if lipo -archs "$file" 2>/dev/null | grep -q ' '; then
        lipo -thin "$ARCH" "$file" -output "$file.thin" && mv "$file.thin" "$file"
    fi
    strip -x "$file" 2>/dev/null || true
done

# 4. Every change above invalidated the signatures. macOS remembers privacy
# grants (microphone, camera, audio capture) by the designated requirement;
# an ad-hoc signature's requirement is its own hash, so every build would ask
# again. With a local signing identity the requirement is "com.kumo.kvj signed
# by this certificate" and grants survive updates. Set it up with
# packaging/make-signing-identity.sh; without it the bundle is signed ad hoc.
SIGN_DIR="${KVJ_SIGN_DIR:-$HOME/kvj-toolchain/signing}"
RCODESIGN="${KVJ_RCODESIGN:-$HOME/kvj-toolchain/rcodesign/bin/rcodesign}"
if [ -f "$SIGN_DIR/cert.pem" ] && [ -f "$SIGN_DIR/key.pem" ] && [ -f "$SIGN_DIR/requirement.bin" ] && [ -x "$RCODESIGN" ]; then
    "$RCODESIGN" sign --pem-file "$SIGN_DIR/cert.pem" --pem-file "$SIGN_DIR/key.pem" --timestamp-url none \
        --code-requirements-path "@main:$SIGN_DIR/requirement.bin" "$APP" > /dev/null 2>&1
    codesign --verify --deep --strict "$APP"
    echo "signed with the local KVJ identity"
else
    codesign --force --deep --sign - "$APP" > /dev/null
    echo "signed ad hoc (privacy grants will be asked again after updates)"
fi
du -sh "$APP"
