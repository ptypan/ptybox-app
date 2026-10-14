#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# PtyBox - check_no_termux_leaks.sh
#
# Puerta de calidad del CI: ninguna parte del codigo puede seguir Speaking del
# paquete de Termux original. Un solo "com.termux" olvidado en una cadena puede
# hacer que la app mande un intent a la app que no es, que es exactamente la
# interferencia que este fork quiere evitar.
#
# Se ignoran:
#   - los paquetes java/import (ya renombrados, pero com.termux.am es externo)
#   - las lineas de comentario (// y javadoc), donde el nombre original es
#     documentacion legitima del upstream
#   - la documentacion .md, que cita upstream a proposito
#   - las dos referencias a la libreria externa com.termux:termux-am-library
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

SKIP_DIRS_RE='/\.(git|gradle|idea|build|site|fastlane|out)(/|$)'
SKIP_FILES_RE='\.(md|markdown|png|jpg|jks|keystore|apk|so|zip|woff2?|ttf)$'

LEAKS="$(
    find "$REPO" \( -type d -o -type f \) 2>/dev/null |
    grep -Ev "$SKIP_DIRS_RE" |
    grep -Ev "$SKIP_FILES_RE" |
    while read -r f; do
        [ -f "$f" ] || continue
        case "$f" in
            *.java)
                awk -v file="$f" '
                    {
                        line = $0
                        sub(/\/\/.*/, "", line)
                        if (line ~ /^[[:space:]]*\*/) next
                        if (line !~ /com\.termux/) next
                        if (line ~ /com\.termux\.am\./) next
                        if (line ~ /com\.termux:termux-am-library/) next
                        printf "%s:%d: %s\n", file, FNR, line
                    }' "$f"
                ;;
            *.xml)
                awk -v file="$f" '
                    {
                        line = $0
                        sub(/<!--.*-->/, "", line)
                        if (line !~ /com\.termux/) next
                        if (line ~ /com\.termux\.am\./) next
                        if (line ~ /com\.termux:termux-am-library/) next
                        printf "%s:%d: %s\n", file, FNR, line
                    }' "$f"
                ;;
            *.gradle|*.pro|*.cpp|*.c|*.h|*.yml|*.yaml|*.properties|*.json|*.kt)
                awk -v file="$f" '
                    {
                        line = $0
                        sub(/\/\*.*\*\//, "", line)   # comentario de bloque
                        sub(/\/\/.*/, "", line)          # comentario de linea
                        sub(/#.*/, "", line)               # comentario en gradle/yml
                        if (line !~ /com\.termux/) next
                        if (line ~ /com\.termux\.am\./) next
                        if (line ~ /com\.termux:termux-am-library/) next
                        printf "%s:%d: %s\n", file, FNR, line
                    }' "$f"
                ;;
        esac
    done
)"

if [ -z "$LEAKS" ]; then
    echo "OK: ninguna referencia funcional a com.termux en el codigo de $(basename "$REPO")."
    exit 0
fi

COUNT="$(printf '%s\n' "$LEAKS" | wc -l)"
echo "FALLO: ${COUNT} referencias a com.termux que deben cambiarse por com.ptybox:"
echo
printf '%s\n' "$LEAKS" | head -60 | sed 's/^/    /'
if [ "${COUNT}" -gt 60 ]; then
    echo "    ... y $((COUNT - 60)) mas"
fi
echo
echo "Si alguna es legitima (por ejemplo documentacion de una cadena que se"
echo "construye a mano), marcala como excepcion en este script."
exit 1