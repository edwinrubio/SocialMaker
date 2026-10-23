#!/usr/bin/env bash
# =============================================================================
# bootstrap-skills.sh — Instala las skills declaradas en skills.json (Hearness)
# Funciona en cualquier ambiente: lee el manifiesto y trae lo que falte.
#
# Uso:
#   ./bootstrap-skills.sh [ruta/skills.json]   # por defecto ./skills.json
#   AMBIENTE=frontend ./bootstrap-skills.sh     # filtra por 'aplica_si'
#
# NO marca nada como seguro. Instalar != confiar. El escaneo de seguridad
# (mcp-sentinel, gate bloqueante) lo hace el agente — ver base/09-skills.md.
#
# Requiere: jq, y el CLI `claude`.
# =============================================================================
set -uo pipefail

MANIFEST="${1:-skills.json}"
AMBIENTE="${AMBIENTE:-siempre}"   # 'siempre' instala solo las universales

command -v jq >/dev/null 2>&1     || { echo "❌ falta jq"; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "❌ falta el CLI claude"; exit 1; }
[ -f "$MANIFEST" ]                || { echo "❌ no existe $MANIFEST"; exit 1; }

echo "🔌 Bootstrap de skills desde $MANIFEST (ambiente: $AMBIENTE)"

INSTALADAS="$(claude plugin list 2>/dev/null || true)"
MERCADOS="$(claude plugin marketplace list 2>/dev/null || true)"
FALLOS=0

# ¿esta skill aplica a este ambiente?
aplica() { [ "$1" = "siempre" ] || [ "$1" = "$AMBIENTE" ]; }

# recorre cada skill del manifiesto
while IFS=$'\t' read -r nombre aplica_si fuente marketplace repo plugin_id commit; do
  aplica "$aplica_si" || { echo "· $nombre — omitida (aplica_si=$aplica_si)"; continue; }

  echo "· $nombre"

  # 1. registrar marketplace/repo si hace falta
  fuente_repo="${marketplace:-$repo}"
  if [ -n "$fuente_repo" ] && [ "$fuente_repo" != "null" ]; then
    if ! grep -qF "${marketplace:-$repo}" <<<"$MERCADOS" 2>/dev/null; then
      if [[ "$repo" == RELLENAR/* || "$repo" == "null" ]]; then
        echo "  ⚠️  sin repo válido en el manifiesto; no se puede reinstalar en ambiente limpio"
      else
        echo "  → claude plugin marketplace add $repo"
        claude plugin marketplace add "$repo" >/dev/null 2>&1 || echo "  ⚠️  no se pudo añadir $repo"
      fi
    fi
  fi

  # 2. instalar si falta
  if grep -qF "$nombre" <<<"$INSTALADAS" 2>/dev/null; then
    echo "  ✅ ya instalada"
  else
    echo "  → claude plugin install $plugin_id"
    if claude plugin install "$plugin_id" >/dev/null 2>&1; then
      echo "  ✅ instalada"
    else
      echo "  ❌ no se pudo instalar $plugin_id (revisa fuente/repo en skills.json)"
      FALLOS=$((FALLOS+1))
    fi
  fi

  # 3. verificar pin de commit (supply-chain)
  if [ -n "$commit" ] && [ "$commit" != "null" ]; then
    echo "  🔒 pin declarado: $commit — verifica que el sha instalado coincida antes de usar"
  fi
done < <(jq -r '.skills[] | [.nombre, .aplica_si, .fuente, (.marketplace//""), (.repo//""), .plugin_id, (.commit//"")] | @tsv' "$MANIFEST")

echo "----------------------------------------"
echo "ℹ️  Instalación terminada. FALTA el gate de seguridad:"
echo "    corre mcp-sentinel sobre las skills y escribe 'verificado'/'scan' en $MANIFEST."
echo "    Ninguna skill se usa hasta pasar ese escaneo (modo bloqueante)."
[ "$FALLOS" -eq 0 ] && exit 0 || { echo "❌ $FALLOS skill(s) no se instalaron."; exit 1; }
