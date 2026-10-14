#!/usr/bin/env bash
# =============================================================================
# PtyBox - verify_apk.sh <ruta.apk> [paquete_esperado]
#
# Comprueba sobre el APK construido que:
#   1. El paquete Android es el esperado (com.ptybox), no com.termux.
#   2. No aparece NINGUNA referencia a com.termux en el manifiesto fusionado.
#      Es la garantia dura de que no vamos a colisionar con Termux original:
#      permisos, authorities, receivers e intents son todos Prefijo-dependientes.
#   3. El permiso RUN_COMMAND propio existe y el ajeno no.
#   4. El sharedUserId es el nuestro.
#   5. El APK trae el asset del bootstrap para su ABI.
#
# Requiere aapt (build-tools del Android SDK).
# =============================================================================
set -uo pipefail

APK="${1:?uso: verify_apk.sh <apk> [paquete]}"
EXPECTED_PKG="${2:-com.ptybox}"
FORBIDDEN_PKG="${FORBIDDEN_PKG:-com.termux}"

FAIL=0
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=1; }

[ -f "$APK" ] || { echo "No existe el APK: $APK" >&2; exit 1; }

# --- Localizar aapt -----------------------------------------------------------
find_aapt() {
    if command -v aapt >/dev/null 2>&1; then command -v aapt; return 0; fi
    local root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}}"
    local candidate
    candidate="$(ls -1d "$root"/build-tools/*/aapt 2>/dev/null | sort -V | tail -1)"
    [ -n "$candidate" ] && { echo "$candidate"; return 0; }
    return 1
}

AAPT="$(find_aapt)" || { echo "ERROR: no encuentro 'aapt'. Instala build-tools del Android SDK." >&2; exit 2; }
echo "aapt: $AAPT"
echo "APK : $APK"
echo

BADGING="$("$AAPT" dump badging "$APK" 2>/dev/null)"
MANIFEST_TREE="$("$AAPT" dump xmltree "$APK" AndroidManifest.xml 2>/dev/null)"

# --- 1. Paquete ---------------------------------------------------------------
if grep -q "^package: name='${EXPECTED_PKG}'" <<< "$BADGING"; then
    ok "package = ${EXPECTED_PKG}"
else
    bad "el paquete no es ${EXPECTED_PKG}:"
    grep '^package:' <<< "$BADGING" | sed 's/^/        /'
fi

# --- 2. Cero referencias a Termux original ------------------------------------
LEAKS="$(grep -c "${FORBIDDEN_PKG}" <<< "$MANIFEST_TREE" || true)"
if [ "${LEAKS}" -eq 0 ]; then
    ok "el manifiesto fusionado no menciona ${FORBIDDEN_PKG}"
else
    bad "el manifiesto fusionado menciona ${FORBIDDEN_PKG} en ${LEAKS} lineas:"
    grep -n "${FORBIDDEN_PKG}" <<< "$MANIFEST_TREE" | head -20 | sed 's/^/        /'
fi

# --- 3. Permisos --------------------------------------------------------------
if grep -q "${EXPECTED_PKG}\.permission\.RUN_COMMAND" <<< "$BADGING"; then
    ok "permiso ${EXPECTED_PKG}.permission.RUN_COMMAND declarado"
else
    bad "falta el permiso ${EXPECTED_PKG}.permission.RUN_COMMAND"
fi
if grep -q "${FORBIDDEN_PKG}\.permission\.RUN_COMMAND" <<< "$BADGING"; then
    bad "permiso ${FORBIDDEN_PKG}.permission.RUN_COMMAND presente: colisionaria con Termux"
else
    ok "sin permiso ${FORBIDDEN_PKG}.permission.RUN_COMMAND"
fi

# --- 4. sharedUserId ----------------------------------------------------------
SHARED_UID="$(grep -A2 'sharedUserId' <<< "$MANIFEST_TREE" | grep -oE 'Raw: "[^"]+"' | head -1)"
if grep -q "Raw: \"${EXPECTED_PKG}\"" <<< "$MANIFEST_TREE"; then
    ok "sharedUserId = ${EXPECTED_PKG}"
else
    bad "sharedUserId inesperado: ${SHARED_UID:-<sin sharedUserId>}"
fi

# --- 5. Authorities de los providers -----------------------------------------
for suffix in ".files" ".documents"; do
    if grep -q "${EXPECTED_PKG}${suffix}" <<< "$MANIFEST_TREE"; then
        ok "provider authority ${EXPECTED_PKG}${suffix}"
    else
        bad "falta el provider authority ${EXPECTED_PKG}${suffix}"
    fi
done
if grep -q "${FORBIDDEN_PKG}\.files" <<< "$MANIFEST_TREE"; then
    bad "provider authority ${FORBIDDEN_PKG}.files presente: colisionaria con Termux"
else
    ok "sin provider authority ${FORBIDDEN_PKG}.files"
fi

# --- 6. Asset del bootstrap ---------------------------------------------------
# La app principal lo lleva; la API no (no instala $PREFIX). Se puede desactivar
# con PTYBOX_SKIP_BOOTSTRAP_CHECK=1.
if [ "${PTYBOX_SKIP_BOOTSTRAP_CHECK:-0}" = "1" ]; then
    echo "  ---   comprobacion del asset de bootstrap omitida"
else
    ASSET_COUNT="$(unzip -l "$APK" 2>/dev/null | grep -cE 'assets/bootstrap-(aarch64|arm|i686|x86_64)\.zip$' || true)"
    if [ "${ASSET_COUNT}" -ge 1 ]; then
        ok "asset del bootstrap presente (${ASSET_COUNT})"
        unzip -l "$APK" | grep -E 'assets/bootstrap-.*\.zip$' | sed 's/^/        /'
    else
        bad "el APK no lleva ningun assets/bootstrap-<abi>.zip (falta ejecutar 'patchBootstraps')"
    fi
fi

echo
if [ "$FAIL" -ne 0 ]; then
    echo "VERIFICACION FALLIDA: el APK no cumple los requisitos de aislamiento de PtyBox."
    exit 1
fi
echo "Verificacion correcta: el APK es com.${EXPECTED_PKG#*.} y no colisiona con Termux."