#!/usr/bin/env bash
# =============================================================================
# PtyBox - check_invariants.sh
#
# Comprueba que TODOS los lugares del repo que declaran el paquete y el nombre
# de la app dicen lo mismo. Es mas util que comparar contra constantes fijas
# porque los desacuerdos entre ficheros son justo el fallo que rompe el fork:
# si TermuxConstants dijera com.ptybox pero el applicationId com.otracosa, las
# clases que se construyen por concatenacion apuntarian a sitios que no existen.
#
# Fuentes que se cruzan:
#   - app/build.gradle                          -> applicationId, versionName
#   - termux-shared/.../TermuxConstants.java    -> TERMUX_PACKAGE_NAME, TERMUX_APP_NAME
#   - app/src/main/res/values/strings.xml       -> entidades XML
#   - app/src/main/java/.../TermuxInstaller.java-> debe leer de assets, no de una .so
#
# No depende de nada fuera del repo: funciona igual en Termux que en CI.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
cd "$REPO"

FAIL=0
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=1; }

# first <fichero> <expresion sed>   -> imprime el grupo 1 de la primera coincidencia
first() {
    [ -f "$1" ] || return 1
    sed -nE "s|.*$2.*|\1|p" "$1" 2>/dev/null | head -1
}

APP_GRADLE="app/build.gradle"
CONSTANTS="termux-shared/src/main/java/com/ptybox/shared/termux/TermuxConstants.java"
STRINGS="app/src/main/res/values/strings.xml"
INSTALLER="app/src/main/java/com/ptybox/app/TermuxInstaller.java"

GRADLE_PKG="$(first "$APP_GRADLE" 'applicationId[[:space:]]+"([^"]+)"')"
GRADLE_VERSION="$(first "$APP_GRADLE" 'versionName[[:space:]]+"([^"]+)"')"
CONST_PKG="$(first "$CONSTANTS" 'TERMUX_PACKAGE_NAME[[:space:]]*=[[:space:]]*"([^"]+)"')"
CONST_NAME="$(first "$CONSTANTS" 'TERMUX_APP_NAME[[:space:]]*=[[:space:]]*"([^"]+)"')"
XML_PKG="$(first "$STRINGS" '<!ENTITY TERMUX_PACKAGE_NAME "([^"]+)"')"
XML_NAME="$(first "$STRINGS" '<!ENTITY TERMUX_APP_NAME "([^"]+)"')"

echo "== Invariantes del fork PtyBox =="
echo
echo "-- Valores declarados --"
printf '  %-32s %s\n' "build.gradle applicationId" "${GRADLE_PKG:-<NO ENCONTRADO>}"
printf '  %-32s %s\n' "build.gradle versionName"   "${GRADLE_VERSION:-<NO ENCONTRADO>}"
printf '  %-32s %s\n' "TermuxConstants PACKAGE"    "${CONST_PKG:-<NO ENCONTRADO>}"
printf '  %-32s %s\n' "TermuxConstants APP_NAME"   "${CONST_NAME:-<NO ENCONTRADO>}"
printf '  %-32s %s\n' "strings.xml PACKAGE"        "${XML_PKG:-<NO ENCONTRADO>}"
printf '  %-32s %s\n' "strings.xml APP_NAME"       "${XML_NAME:-<NO ENCONTRADO>}"
echo

echo "-- Coherencia entre ficheros --"
REF="${PTYBOX_PKG:-${GRADLE_PKG}}"
[ -n "$REF" ] || { bad "no se pudo determinar el paquete"; exit 1; }

for pair in "build.gradle:applicationId:${GRADLE_PKG}" \
            "TermuxConstants:TERMUX_PACKAGE_NAME:${CONST_PKG}" \
            "strings.xml:entidad TERMUX_PACKAGE_NAME:${XML_PKG}"; do
    where="${pair%%:*}"; rest="${pair#*:}"; value="${rest#*:}"
    if [ -z "$value" ]; then
        bad "$where no declara el paquete"
    elif [ "$value" = "$REF" ]; then
        ok "$where = $value"
    else
        bad "$where dice '$value' pero el paquete es '$REF'"
    fi
done

if [ -n "$CONST_NAME" ] && [ -n "$XML_NAME" ]; then
    if [ "$CONST_NAME" = "$XML_NAME" ]; then
        ok "nombre visible coherente: $XML_NAME"
    else
        bad "nombre visible incoherente: TermuxConstants='$CONST_NAME' vs strings.xml='$XML_NAME'"
    fi
else
    bad "no se pudo leer el nombre visible"
fi

echo
echo "-- Invariante critica: longitud del paquete --"
if [ ${#REF} -eq 10 ]; then
    ok "el paquete '$REF' mide 10 caracteres"
else
    bad "el paquete '$REF' mide ${#REF} caracteres y debe medir 10"
    echo "       Sin 10 caracteres el bootstrap no se puede parchear byte a byte."
    echo "       Lee docs/04-bootstrap.md antes de cambiar nada."
fi

PREFIX="/data/data/${REF}/files/usr"
if [ ${#PREFIX} -eq 31 ]; then
    ok "prefijo de 31 bytes: $PREFIX"
else
    bad "prefijo de ${#PREFIX} bytes (debe ser 31): $PREFIX"
fi
if [ "$REF" = "com.termux" ]; then
    bad "el paquete es el de Termux original: no habria aislamiento"
else
    ok "el paquete no es el de Termux original"
fi

API_PKG="${PTYBOX_API_PKG:-com.ptybox.api}"
if [ "$API_PKG" != "$REF" ]; then
    ok "la API usa $API_PKG, distinto de $REF"
else
    bad "la API comparte paquete con la app: no pueden convivir con permisos separados"
fi

echo
echo "-- Version --"
if [ -n "$GRADLE_VERSION" ] && printf '%s' "${GRADLE_VERSION#v}" \
   | grep -qP '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$'; then
    ok "versionName '$GRADLE_VERSION' valido (semver 2.0.0)"
else
    bad "versionName '${GRADLE_VERSION:-<vacio>}' no cumple semver 2.0.0: validateVersionName de Gradle abortara el build"
fi

echo
echo "-- Bootstrap desde assets, sin NDK en este modulo (F1B) --"
if [ -d app/src/main/cpp ]; then
    bad "app/src/main/cpp sigue existiendo: el bootstrap deberia ir en assets"
elif grep -q 'public static native byte\[\] getZip' "$INSTALLER" 2>/dev/null; then
    bad "TermuxInstaller todavia declara el metodo nativo getZip()"
elif grep -q 'loadZipBytes(Context' "$INSTALLER" 2>/dev/null; then
    ok "TermuxInstaller.loadZipBytes(Context) lee el zip de assets"
else
    bad "TermuxInstaller no parece leer el bootstrap de assets: revisa loadZipBytes()"
fi

echo
if [ "$FAIL" -ne 0 ]; then
    echo "Invariantes rotas: NO se debe compilar."
    exit 1
fi
echo "Todas las invariantes se cumplen."