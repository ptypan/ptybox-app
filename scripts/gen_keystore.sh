#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# PtyBox - gen_keystore.sh
# Genera el keystore de firma de PtyBox.
#
# Upstream Termux firma con 'testkey_untrusted.jks', una clave que es PUBLICA y
# que el proyecto publica en el repositorio: cualquiera con ella puede generar
# una "actualizacion" de Termux. No la reutilizamos.
#
# El keystore NUNCA se sube al repositorio (.gitignore lo cubre). En GitHub
# Actions se inyecta codificado en base64 por el secret PTYBOX_KEYSTORE_B64.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

KEYSTORE="${1:-$ROOT/src/ptybox-app/ptybox-release.jks}"
ALIAS="${PTYBOX_KEY_ALIAS:-ptybox}"
STOREPASS="${PTYBOX_STORE_PASSWORD:-}"
KEYPASS="${PTYBOX_KEY_PASSWORD:-$STOREPASS}"
VALIDITY="${PTYBOX_KEY_VALIDITY:-10000}"
DNAME="${PTYBOX_KEY_DNAME:-CN=PtyBox, OU=PtyBox, O=PtyBox, L=Unknown, ST=Unknown, C=ES}"

command -v keytool >/dev/null || { echo "ERROR: 'keytool' no encontrado. Instala un JDK (openjdk-17)." >&2; exit 1; }

if [ -f "$KEYSTORE" ]; then
  echo "El keystore ya existe: $KEYSTORE"
  echo "NO lo sobrescribas: perderias la capacidad de actualizar apps ya instaladas."
  exit 1
fi

if [ -z "$STOREPASS" ]; then
  STOREPASS="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-20)"
  echo "No se indico PTYBOX_STORE_PASSWORD; se ha generado una al azar para este keystore."
fi

mkdir -p "$(dirname "$KEYSTORE")"
keytool -genkeypair \
  -keystore "$KEYSTORE" \
  -alias "$ALIAS" \
  -keyalg RSA -keysize 4096 -validity "$VALIDITY" \
  -storetype PKCS12 \
  -dname "$DNAME" \
  -storepass "$STOREPASS" \
  -keypass "$KEYPASS" 2>&1 | grep -v '^Warning:' || true

echo
echo "Keystore generado: $KEYSTORE"
echo "Alias            : $ALIAS"
echo
echo "Guarda la contrasen FUERA del repositorio. Para GitHub Actions:"
echo
echo "  base64 -w0 '$KEYSTORE' | tr -d '\\n'"
echo "  -> secret PTYBOX_KEYSTORE_B64"
echo "  -> secrets PTYBOX_STORE_PASSWORD, PTYBOX_KEY_ALIAS, PTYBOX_KEY_PASSWORD"
echo
echo "Y crea 'keystore.properties' (gitignored) para compilar en local:"
cat <<EOF
storeFile=src/ptybox-app/$(basename "$KEYSTORE")
storePassword=$STOREPASS
keyAlias=$ALIAS
keyPassword=$KEYPASS
EOF