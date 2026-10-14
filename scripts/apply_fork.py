#!/usr/bin/env python3
"""
PtyBox - apply_fork.py
Renombrado masivo de com.termux -> com.ptybox en los arboles de fuentes.

Es idempotente: si ya no encuentra "com.termux" que renombrar, no hace nada.

Excepcion critica: la libreria externa `com.termux:termux-am-library` (paquete
java `com.termux.am`) NO es nuestra y NO se renombra, o la compilacion falla.
"""
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, "src")

OLD_PKG = "com.termux"
NEW_PKG = "com.ptybox"

# Sustituyentes internos: se protegen antes de renombrar y se restauran despues.
GUARDS = {
    "com.termux:termux-am-library": "\x00GUARD_AM_COORD\x00",
    "com.termux.am": "\x00GUARD_AM_PKG\x00",
}

# Ficheros donde tiene sentido renombrar. .md se excluye a proposito: la
# documentacion upstream debe seguir citando com.termux como upstream.
EXTS = {".java", ".xml", ".gradle", ".pro", ".cpp", ".c", ".h", ".yml",
        ".yaml", ".properties", ".json", ".kt", ".gradle.kts"}

SKIP_DIR_PARTS = {".git", "build", ".gradle", ".idea", "site", "fastlane",
                  "docs", "vendor"}

stats = {"files_touched": 0, "replacements": 0, "dirs_moved": 0}


def should_process(path: str) -> bool:
    parts = set(path.split(os.sep))
    if parts & SKIP_DIR_PARTS:
        return False
    base = os.path.basename(path)
    if not base:
        return False
    return any(base.endswith(e) for e in EXTS) or base == "Android.mk"


def rename_text(text: str) -> str:
    n = 0
    for old, guard in GUARDS.items():
        n += text.count(old)
        text = text.replace(old, guard)
    n += text.count(OLD_PKG)
    text = text.replace(OLD_PKG, NEW_PKG)
    for old, guard in GUARDS.items():
        text = text.replace(guard, old)
    return text, n


def move_java_dirs(root: str):
    """Mueve <srcroot>/java/com/termux -> <srcroot>/java/com/ptybox."""
    for dirpath, dirnames, _ in os.walk(root):
        if "java" not in os.path.basename(dirpath):
            continue
        old = os.path.join(dirpath, OLD_PKG.replace(".", os.sep))
        if not os.path.isdir(old):
            continue
        new = os.path.join(dirpath, NEW_PKG.replace(".", os.sep))
        if os.path.isdir(new):
            print(f"  aviso: {new} ya existe, fusionando en {old}")
            for item in os.listdir(old):
                shutil.move(os.path.join(old, item), os.path.join(new, item))
            os.rmdir(old)
        else:
            shutil.move(old, new)
        stats["dirs_moved"] += 1
        print(f"  movido: {old} -> {new}")
        dirnames[:] = [d for d in dirnames if d != OLD_PKG]


def main() -> int:
    if len(OLD_PKG) != len(NEW_PKG):
        print(f"ERROR: '{OLD_PKG}' ({len(OLD_PKG)}) y '{NEW_PKG}' ({len(NEW_PKG)}) "
              f"deben medir lo mismo o el parcheo de prefijo es imposible.")
        return 1

    for repo in sorted(os.listdir(SRC)):
        repo_path = os.path.join(SRC, repo)
        if not os.path.isdir(repo_path):
            continue
        print(f"\n[{repo}]")
        move_java_dirs(repo_path)

        for dirpath, dirnames, filenames in os.walk(repo_path):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIR_PARTS]
            for fn in filenames:
                path = os.path.join(dirpath, fn)
                if not should_process(path):
                    continue
                try:
                    with open(path, encoding="utf-8") as f:
                        text = f.read()
                except (UnicodeDecodeError, OSError):
                    continue
                if OLD_PKG not in text:
                    continue
                new_text, n = rename_text(text)
                if n and new_text != text:
                    with open(path, "w", encoding="utf-8") as f:
                        f.write(new_text)
                    stats["files_touched"] += 1
                    stats["replacements"] += n
                    print(f"  {n:3d}x  {os.path.relpath(path, ROOT)}")

    print(f"\nFicheros tocados : {stats['files_touched']}")
    print(f"Reemplazos       : {stats['replacements']}")
    print(f"Directorios java : {stats['dirs_moved']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())