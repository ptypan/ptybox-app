#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# PtyBox - check_invariants.sh
# Comprueba las invariantes criticas del fork antes de compilar.
# Si algo falla, el fork esta roto: no tiene sentido seguir.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config/fork.env
source "$HERE/../../../config/fork.env"

FAIL=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=1; }

echo "== Invariantes del fork PtyBox =="

# 1. El paquete debe medir exactamente 10 caracteres ----------------------------
if [ ${#PTYBOX_PKG} -eq 10 ]; then
  ok "$PTYBOX_PKG mide 10 caracteres"
else
  bad "$PTYBOX_PKG mide ${#PTYBOX_PKG} caracteres, debe medir 10"
fi

# 2. Prefijos de igual longitud -------------------------------------------------
if [ ${#PTYBOX_PREFIX} -eq ${#UPSTREAM_PREFIX} ]; then
  ok "prefijo de igual longitud (${#PTYBOX_PREFIX} bytes): $PTYBOX_PREFIX"
else
  bad "prefijo ${#PTYBOX_PREFIX} != upstream ${#UPSTREAM_PREFIX} bytes"
fi

# 3. Prefijo derivado del paquete ------------------------------------------------
if [ "$PTYBOX_PREFIX" = "/data/data/${PTYBOX_PKG}/files/usr" ]; then
  ok "prefijo coherente con el paquete"
else
  bad "prefijo incoherente con el paquete"
fi

# 4. El paquete NO puede colisionar con el original ------------------------------
if [ "$PTYBOX_PKG" != "$UPSTREAM_PKG" ]; then
  ok "el paquete difiere de $UPSTREAM_PKG (sin colision)"
else
  bad "el paquete es identico al de Termux original"
fi

# 5. El paquete de la API debe ser distinto del de la app -----------------------
if [ "$PTYBOX_API_PKG" != "$PTYBOX_PKG" ]; then
  ok "$PTYBOX_API_PKG != $PTYBOX_PKG"
else
  bad "el paquete de la API debe ser distinto del de la app"
fi

# 6. versionName valida segun semver 2.0.0 --------------------------------------
if printf '%s' "${PTYBOX_VERSION_NAME#v}" | grep -qP '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$'; then
  ok "versionName '$PTYBOX_VERSION_NAME' valido (semver 2.0.0)"
else
  bad "versionName '$PTYBOX_VERSION_NAME' NO cumple semver 2.0.0"
fi

echo
if [ "$FAIL" -ne 0 ]; then
  echo "Invariantes rotas. Revisa config/fork.env"
  exit 1
fi
echo "Todas las invariantes se cumplen."