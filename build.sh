#!/bin/zsh
# Monta o Sísifo.app (e o .dmg com --dmg). Leva junto o Node e a ponte do WhatsApp,
# então quem instala não precisa de nada além do Claude Code.
#   ./build.sh            monta em build/Sisifo.app
#   ./build.sh --install  monta e copia pra /Applications
#   ./build.sh --dmg      monta e gera build/Sisifo.dmg
set -e
cd "$(dirname "$0")"
ROOT=$PWD
VERSION=$(cat VERSION 2>/dev/null || echo 0.1.0)
BUNDLE_ID="app.sisifo.Sisifo"

NODE_BIN=${NODE_BIN:-$(command -v node)}
[ -x "$NODE_BIN" ] || { echo "Precisa do Node 22.5+ pra montar (ele vai dentro do app)."; exit 1; }

node --check server/server.mjs
node --check server-privado/server.mjs
node --check bridge/src/bridge.js
(cd bridge && npm ci --omit=dev --no-audit --no-fund >/dev/null)
(cd app && swift build -c release)

APP="$ROOT/build/Sisifo.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
R="$APP/Contents/Resources"
cp app/.build/release/Sisifo "$APP/Contents/MacOS/Sisifo"

# servidores locais e ponte do WhatsApp
mkdir -p "$R/server" "$R/server-privado" "$R/bridge"
cp server/*.mjs "$R/server/"
cp server-privado/server.mjs "$R/server-privado/"
cp -R bridge/src bridge/package.json bridge/node_modules "$R/bridge/"

# Node embutido (só a parte da arquitetura desta máquina)
mkdir -p "$R/node/bin"
lipo "$NODE_BIN" -thin "$(uname -m)" -output "$R/node/bin/node" 2>/dev/null || cp "$NODE_BIN" "$R/node/bin/node"
chmod +x "$R/node/bin/node"

# sons e ícone
NOTIF_SOM="/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/AlertTones/ReceivedMessage.caf"
[ -f "$NOTIF_SOM" ] && cp "$NOTIF_SOM" "$R/ReceivedMessage.caf"
mkdir -p "$R/sounds" && cp sounds/*.wav "$R/sounds/"
if [ ! -f build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset; mkdir -p build/AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s assets/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) assets/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$R/AppIcon.icns"
cp -R app/Resources/*.lproj "$R/"

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Sísifo</string>
  <key>CFBundleDisplayName</key><string>Sísifo</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Sisifo</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>CFBundleDevelopmentRegion</key><string>pt-BR</string>
  <key>CFBundleLocalizations</key><array><string>pt-BR</string><string>en</string></array>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSMicrophoneUsageDescription</key><string>Gravar áudio pra mandar no WhatsApp.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL

# assinatura ad-hoc (sem conta de desenvolvedor da Apple). Fora de Documents pra não levar atributos.
SIGN="$(mktemp -d)/Sisifo.app"
ditto --norsrc --noextattr --noacl "$APP" "$SIGN"
xattr -cr "$SIGN"
codesign --force --deep -s - "$SIGN"
rm -rf "$APP"; ditto "$SIGN" "$APP"
echo "ok: $APP ($(du -sh "$APP" | cut -f1))"

if [[ "$1" == "--install" ]]; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
  sleep 1
  # guarda o ícone do Adesivo (Icon\r) pra ele não voltar pro ícone com fundo
  ICON_TMP="$(mktemp -d)"
  if [ -f "/Applications/Sisifo.app/Icon"$'\r' ]; then
    ditto "/Applications/Sisifo.app/Icon"$'\r' "$ICON_TMP/Icon"
    xattr -px com.apple.FinderInfo "/Applications/Sisifo.app" 2>/dev/null | tr -d ' \n' > "$ICON_TMP/finderinfo"
  fi
  rm -rf "/Applications/Sisifo.app"
  ditto "$APP" "/Applications/Sisifo.app"
  if [ -f "$ICON_TMP/Icon" ]; then
    ditto "$ICON_TMP/Icon" "/Applications/Sisifo.app/Icon"$'\r'
    FI="$(cat "$ICON_TMP/finderinfo" 2>/dev/null)"
    xattr -wx com.apple.FinderInfo "${FI:-0000000000000000040000000000000000000000000000000000000000000000}" "/Applications/Sisifo.app"
    chflags hidden "/Applications/Sisifo.app/Icon"$'\r'
    touch "/Applications/Sisifo.app"
  else
    # sem ícone salvo: pede pro Adesivo reaplicar
    open -gj -b dev.kevyn.adesivo 2>/dev/null || true
  fi
  rm -rf "$ICON_TMP"
  echo "instalado: /Applications/Sisifo.app"
fi

if [[ "$1" == "--dmg" ]]; then
  STAGE="$(mktemp -d)/Sísifo"
  mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/Sisifo.app"
  ln -s /Applications "$STAGE/Applications"
  rm -f build/Sisifo.dmg
  hdiutil create -volname "Sísifo" -srcfolder "$STAGE" -ov -format UDZO build/Sisifo.dmg >/dev/null
  echo "dmg: $ROOT/build/Sisifo.dmg ($(du -sh build/Sisifo.dmg | cut -f1))"
fi
