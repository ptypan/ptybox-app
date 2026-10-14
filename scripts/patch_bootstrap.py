#!/usr/bin/env python3
"""
PtyBox - patch_bootstrap.py
===========================
Descarga el bootstrap oficial de Termux, verifica su SHA-256 y lo reempaqueta
sustituyendo "com.termux" -> "com.ptybox" byte a byte.

Por que funciona
----------------
Los binarios del bootstrap tienen horneada la ruta del prefijo
    /data/data/com.termux/files/usr      (31 bytes)
en sus cadenas (ELF, scripts de shell, ficheros .list/.md5sums de dpkg...). Si
"com.termux" y "com.ptybox" miden lo mismo, sustituir byte a byte NO cambia
ningun offset del ELF ni ninguna longitud, asi que el binario sigue siendo
valido. Por eso el paquete debe medir exactamente 10 caracteres.

Uso
---
    python3 scripts/patch_bootstrap.py                 # las 4 arquitecturas
    python3 scripts/patch_bootstrap.py --abi aarch64   # solo una

Variables de entorno (las inyecta el Gradle task `patchBootstraps`):
    PTYBOX_BOOTSTRAP_PACKAGE_VARIANT  apt-android-7 | apt-android-5
    PTYBOX_BOOTSTRAP_OUTPUT_DIR       app/ (donde crear src/main/<abi>/assets/)
    PTYBOX_BOOTSTRAP_CACHE_DIR        donde cachear los zips oficiales
"""
import argparse
import hashlib
import os
import shutil
import sys
import tempfile
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

OLD_PKG = "com.termux"
NEW_PKG = "com.ptybox"

# arquitectura -> (nombre en assets de Gradle, sha256 oficial)
APT_ANDROID_7 = {
    "aarch64": ("arm64-v8a", "ea2aeba8819e517db711f8c32369e89e7c52cee73e07930ff91185e1ab93f4f3"),
    "arm":     ("armeabi-v7a", "a38f4d3b2f735f83be2bf54eff463e86dc32a3e2f9f861c1557c4378d249c018"),
    "i686":    ("x86", "f5bc0b025b9f3b420b5fcaeefc064f888f5f22a0d6fd7090f4aac0c33eb3555b"),
    "x86_64":  ("x86_64", "b7fd0f2e3a4de534be3144f9f91acc768630fc463eaf134ab2e64c545e834f7a"),
}
APT_ANDROID_5 = {
    "aarch64": ("arm64-v8a", "913609d439415c828c5640be1b0561467e539cb1c7080662decaaca2fb4820e7"),
    "arm":     ("armeabi-v7a", "26bfb45304c946170db69108e5eb6e3641aad751406ce106c80df80cad2eccf8"),
    "i686":    ("x86", "46dcfeb5eef67ba765498db9fe4c50dc4690805139aa0dd141a9d8ee0693cd27"),
    "x86_64":  ("x86_64", "615b590679ee6cd885b7fd2ff9473c845e920f9b422f790bb158c63fe42b8481"),
}
VARIANTS = {"apt-android-7": ("2026.02.12-r1", APT_ANDROID_7),
            "apt-android-5": ("2022.04.28-r6", APT_ANDROID_5)}

OLD = OLD_PKG.encode()
NEW = NEW_PKG.encode()

# Ficheros extra que se inyectan dentro del bootstrap ya parcheado. El
# instalador de la app da 0700 a todo lo que cuelga de bin/, asi que placing
# ptybox-prefix-fix ahi lo deja ejecutable sin permisos especiales en el zip.
INJECT_DIR = os.path.join(HERE, "inject")
INJECTIONS = [
    # (origen en scripts/inject, ruta dentro del zip, debe ser ejecutable)
    ("ptybox-prefix-fix", "bin/ptybox-prefix-fix", True),
    ("90ptybox-prefix-fix.aptconf", "etc/apt/apt.conf.d/90ptybox-prefix-fix", False),
]


def injections():
    """Devuelve [(nombre_zip, bytes, modo_zip)] o aborta si falta algun fichero."""
    out = []
    for src_name, zip_name, executable in INJECTIONS:
        path = os.path.join(INJECT_DIR, src_name)
        if not os.path.exists(path):
            raise SystemExit(f"Falta el fichero a inyectar: {path}")
        with open(path, "rb") as f:
            data = f.read()
        # Los scripts inyectados tambien llevan el prefijo viejo hardcodeado.
        if OLD in data:
            data = data.replace(OLD, NEW)
        mode = 0o755 if executable else 0o644
        out.append((zip_name, data, mode))
    return out


def log(msg):
    print(f"[patch_bootstrap] {msg}", flush=True)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url, dest):
    log(f"descargando {url}")
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + ".part"
    with urllib.request.urlopen(url, timeout=300) as resp, open(tmp, "wb") as out:
        shutil.copyfileobj(resp, out, 1 << 20)
    os.replace(tmp, dest)
    return dest


def ensure_official_zip(arch, version, expected_sha, cache_dir):
    """Devuelve la ruta al zip oficial, descargandolo y verificandolo si hace falta."""
    path = os.path.join(cache_dir, f"upstream-{version}-{arch}.zip")
    if os.path.exists(path) and sha256(path) == expected_sha:
        log(f"{arch}: zip oficial ya en cache y verificado")
        return path
    url = (f"https://github.com/termux/termux-packages/releases/download/"
           f"bootstrap-{version}%2B{version_tag(version)}/bootstrap-{arch}.zip")
    download(url, path)
    actual = sha256(path)
    if actual != expected_sha:
        os.remove(path)
        raise SystemExit(
            f"SHA-256 incorrecto para {arch}\n  esperado: {expected_sha}\n  obtenido: {actual}")
    log(f"{arch}: descarga verificada ({actual[:16]}...)")
    return path


def version_tag(version):
    # "2026.02.12-r1" -> "apt.android-7"; el tag real es "2026.02.12-r1+apt.android-7"
    return "apt.android-7" if version.startswith("2026") else "apt-android-5"


def patch_zip(src, dest, arch):
    """Reescribe el zip sustituyendo el paquete e inyecta los ficheros de PtyBox."""
    total = 0
    files = 0
    extra = injections()
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with zipfile.ZipFile(src, "r") as zin, \
         zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zout:
        for info in zin.infolist():
            data = zin.read(info.filename)
            if OLD in data:
                count = data.count(OLD)
                data = data.replace(OLD, NEW)
                total += count
                files += 1
            # Se preservan fecha y metodo de compresion original; el CRC lo
            # recalcula zipfile porque los bytes han cambiado.
            new_info = zipfile.ZipInfo(info.filename, date_time=info.date_time)
            new_info.compress_type = info.compress_type
            new_info.external_attr = info.external_attr
            new_info.create_system = info.create_system
            zout.writestr(new_info, data)

        for zip_name, data, mode in extra:
            info = zipfile.ZipInfo(zip_name, date_time=info_default_date())
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3  # Unix
            info.external_attr = (mode & 0xFFFF) << 16
            zout.writestr(info, data)
            log(f"{arch}: inyectado {zip_name} ({len(data)} bytes, modo {oct(mode)})")

    log(f"{arch}: {total} reemplazos en {files} ficheros -> {os.path.basename(dest)}")
    return total


def info_default_date():
    import time
    return time.localtime(time.time())[:6]


def verify_patched(path, arch):
    """Comprobaciones de seguridad: 0 restos y ELF intactos."""
    problems = []
    with zipfile.ZipFile(path, "r") as z:
        names = set(z.namelist())
        for zip_name, _, _ in injections():
            if zip_name not in names:
                problems.append(f"falta el fichero inyectado {zip_name}")
        for info in z.infolist():
            data = z.read(info.filename)
            if OLD in data:
                problems.append(f"{info.filename}: quedan {data.count(OLD)} ocurrencias de {OLD_PKG}")
            if data[:4] == b"\x7fELF":
                if len(data) < 64:
                    problems.append(f"{info.filename}: ELF truncado")
                    continue
                cls = data[4]
                endian = "little"
                import struct
                fmt = "<" if data[5] == 1 else ">"
                e_shoff = struct.unpack(fmt + "Q", data[40:48])[0] if cls == 2 \
                    else struct.unpack(fmt + "I", data[32:36])[0]
                e_shentsize = struct.unpack(fmt + "H", data[58:60])[0] if cls == 2 \
                    else struct.unpack(fmt + "H", data[46:48])[0]
                e_shnum = struct.unpack(fmt + "H", data[60:62])[0] if cls == 2 \
                    else struct.unpack(fmt + "H", data[48:50])[0]
                if e_shoff and e_shoff + e_shentsize * e_shnum > len(data):
                    problems.append(
                        f"{info.filename}: tabla de secciones ELF fuera de rango "
                        f"(e_shoff={e_shoff}, shnum={e_shnum}, tamaño={len(data)}, "
                        f"endian={'LE' if endian == 'little' else 'BE'})")
    if problems:
        for p in problems[:20]:
            log(f"ERROR {p}")
        raise SystemExit(f"Verificacion del bootstrap parcheado ({arch}) FALLIDA")
    log(f"{arch}: verificacion OK (0 restos de {OLD_PKG}, ELF coherentes)")


def main():
    if len(OLD_PKG) != len(NEW_PKG):
        raise SystemExit(f"'{OLD_PKG}' y '{NEW_PKG}' deben medir lo mismo "
                         f"({len(OLD_PKG)} != {len(NEW_PKG)})")

    ap = argparse.ArgumentParser()
    ap.add_argument("--abi", help="parchear solo esta arquitectura")
    ap.add_argument("--variant", default=os.environ.get("PTYBOX_BOOTSTRAP_PACKAGE_VARIANT", "apt-android-7"))
    args = ap.parse_args()

    # Valores por defecto pensados para el repo: asi el script funciona igual
    # invocado por el task Gradle (que los exporta), desde la CLI y desde CI.
    #   <repo>/app                                -> modulo app
    #   <repo>/build/ptybox-bootstrap-cache       -> cache de los zips oficiales
    repo_root = os.path.dirname(HERE)
    out_dir = os.environ.get("PTYBOX_BOOTSTRAP_OUTPUT_DIR") or os.path.join(repo_root, "app")
    cache_dir = os.environ.get("PTYBOX_BOOTSTRAP_CACHE_DIR") or \
        os.path.join(repo_root, "build", "ptybox-bootstrap-cache")
    if not os.path.isdir(out_dir):
        raise SystemExit(f"PTYBOX_BOOTSTRAP_OUTPUT_DIR no es un directorio: {out_dir}")

    if args.variant not in VARIANTS:
        raise SystemExit(f"TERMUX_PACKAGE_VARIANT no soportado: {args.variant}")
    version, table = VARIANTS[args.variant]
    archs = [args.abi] if args.abi else list(table)
    for a in archs:
        if a not in table:
            raise SystemExit(f"Arquitectura no soportada: {a}")

    log(f"variante={args.variant} version={version} arquitecturas={archs}")
    log(f"{OLD_PKG} -> {NEW_PKG} ({len(OLD_PKG)} bytes, sustitucion 1:1)")

    for arch in archs:
        gradle_abi, expected_sha = table[arch]
        official = ensure_official_zip(arch, version, expected_sha, cache_dir)
        assets_dir = os.path.join(out_dir, "src", "main", gradle_abi, "assets")
        patched = os.path.join(assets_dir, f"bootstrap-{arch}.zip")
        os.makedirs(assets_dir, exist_ok=True)

        with tempfile.NamedTemporaryFile(dir=assets_dir, suffix=".zip", delete=False) as tmp:
            tmp_path = tmp.name
        try:
            patch_zip(official, tmp_path, arch)
            verify_patched(tmp_path, arch)
            os.replace(tmp_path, patched)
        finally:
            if os.path.exists(tmp_path):
                os.remove(tmp_path)

        size_mb = os.path.getsize(patched) / (1024 * 1024)
        log(f"{arch}: escrito {os.path.relpath(patched, ROOT)} ({size_mb:.1f} MiB, "
            f"sha256={sha256(patched)[:16]}...)")

    log("bootstrap parcheado correctamente")
    return 0


if __name__ == "__main__":
    sys.exit(main())