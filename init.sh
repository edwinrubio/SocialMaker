#!/usr/bin/env bash
# =============================================================================
# init.sh — Verificación de entorno de SocialMaker (Hearness base/07)
#
# Uso:
#   ./init.sh            # corre todos los chequeos
#
# Contrato:
#   exit 0  -> todo verde, se puede empezar / cerrar sesión
#   exit !=0 -> algo falla; el agente PARA y reporta qué chequeo falló
#
# Solo lectura / idempotente. Sin gate de skills (desactivado, ver AGENTS.md §8).
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")"

# El SDK vive en ~/flutter; se agrega al PATH por si el shell no lo tiene.
export PATH="$HOME/flutter/bin:$PATH"

FALLOS=0

# --- helpers ----------------------------------------------------------------
ok()   { printf '  ✅ %s\n' "$1"; }
fail() { printf '  ❌ %s\n' "$1"; FALLOS=$((FALLOS+1)); }

check_cmd() {  # check_cmd <comando> <nombre legible>
  if command -v "$1" >/dev/null 2>&1; then ok "$2 disponible ($(command -v "$1"))"
  else fail "$2 NO encontrado (instala $1)"; fi
}

check_path() { # check_path <ruta> <nombre>
  if [ -e "$1" ]; then ok "$2 existe ($1)"
  else fail "$2 falta ($1)"; fi
}

# ============================================================================
# CHEQUEOS
# ============================================================================
echo "🔎 Verificando entorno..."

echo "· Herramientas de runtime"
check_cmd flutter "Flutter"
check_cmd dart "Dart"
check_cmd git "Git"
check_cmd java "Java (Gradle)"
if command -v adb >/dev/null 2>&1 || [ -x "$HOME/Library/Android/sdk/platform-tools/adb" ]; then
  ok "adb disponible"
else
  fail "adb NO encontrado (Android SDK platform-tools)"
fi
if [ "$(uname)" = "Darwin" ]; then
  check_cmd xcodebuild "Xcode"
  check_cmd pod "CocoaPods"
fi

echo "· Dependencias instaladas"
check_path .dart_tool "dependencias de la app (flutter pub get)"
check_path packages/bg_camera/.dart_tool "dependencias del plugin bg_camera"

echo "· Compila / smoke test"
if flutter analyze --no-pub >/tmp/socialmaker-analyze.log 2>&1; then ok "flutter analyze sin issues"
else fail "flutter analyze con issues (ver /tmp/socialmaker-analyze.log)"; fi
if flutter test --no-pub >/tmp/socialmaker-test.log 2>&1; then ok "flutter test pasa"
else fail "flutter test falla (ver /tmp/socialmaker-test.log)"; fi

# ============================================================================
# RESULTADO
# ============================================================================
echo "----------------------------------------"
if [ "$FALLOS" -eq 0 ]; then
  echo "✅ Entorno sano. Puedes empezar / cerrar sesión."
  exit 0
else
  echo "❌ $FALLOS chequeo(s) fallaron. NO empieces a programar hasta arreglarlos."
  exit 1
fi
