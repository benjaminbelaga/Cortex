#!/usr/bin/env python3
"""Enrol API-key accounts listed in a notes file (RTF or plain text) into Cortex.

Each key goes through the canonical path — `Cortex --add-clipboard-account`,
which live-probes the key, refuses duplicates and stores it in the Keychain.
Keys are handled in memory only: never printed, never passed on argv. The
pasteboard is restored to its previous content afterwards.

File format (one section per provider, a label line before each key):
    Api cmd <label> <key>        -> commandcode
    Opencode ...                 -> opencode-go (then "<label>" / "<key>" lines)
    Ollama ...                   -> ollama
Sections Cortex cannot enrol (e.g. QWEN plan keys, which must never be polled)
are reported and skipped.

Usage: import-accounts-from-file.py <file> [--cortex /Applications/Cortex.app/Contents/MacOS/Cortex] [--dry-run] [--skip provider:label]
"""
import argparse
import re
import subprocess
import sys

KEY = re.compile(r"([A-Za-z0-9_\-.]{40,})")
SECTIONS = [("api cmd", "commandcode"), ("opencode", "opencode-go"), ("ollama", "ollama"), ("qwen", "qwen")]
ENROLLABLE = {"commandcode", "opencode-go", "ollama"}


def parse(path):
    text = open(path, errors="ignore").read()
    text = re.sub(r"\\[a-z]+-?\d* ?|[{}]", "", text)
    section, label, out = None, None, []
    for raw in text.splitlines():
        line = raw.strip().rstrip("\\").strip()
        if not line or line.strip(";*") == "" or line.endswith(";"):
            continue
        match = KEY.search(line)
        head = line[: match.start()].strip() if match else line
        low = head.lower()
        started = next((pid for prefix, pid in SECTIONS if low.startswith(prefix)), None)
        if started:
            section = started
            rest = head[len(next(p for p, pid in SECTIONS if pid == started)):].strip()
            label = rest if started == "commandcode" and rest else None
        elif not match:
            label = line
        if match and section:
            out.append((section, short_label(label, section), match.group(1)))
    return out


def short_label(label, section):
    if not label:
        return {"ollama": "Max", "qwen": "Token Plan"}.get(section, "Compte")
    low = label.lower()
    base = low.split("@")[1].split(".")[0] if "@" in low else low.split()[0]
    name = {"yoyaku": "Yoyaku", "kurtezy": "Kurtezy"}.get(base, base)
    if low.startswith("tech@"):
        name = "Tech"
    if "personal" in low or "perso" in low:
        name += " perso"
    return name


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--cortex", default="/Applications/Cortex.app/Contents/MacOS/Cortex")
    ap.add_argument("--dry-run", action="store_true")
    # OpenCode Go exposes no identity, so a second key of an already-enrolled
    # subscription cannot be detected: name it here to avoid re-adding a twin.
    ap.add_argument("--skip", action="append", default=[], help="provider:label to leave out")
    args = ap.parse_args()

    entries = parse(args.file)
    previous = subprocess.run(["pbpaste"], capture_output=True).stdout
    failures = 0
    try:
        for provider, label, key in entries:
            if f"{provider}:{label}" in args.skip:
                print(f"{provider:12} {label:16} SKIPPED (--skip)")
                continue
            if provider not in ENROLLABLE:
                print(f"{provider:12} {label:16} SKIPPED (not a Cortex-probed account)")
                continue
            if args.dry_run:
                print(f"{provider:12} {label:16} would enrol (len {len(key)})")
                continue
            subprocess.run(["pbcopy"], input=key.encode(), check=True)
            result = subprocess.run([args.cortex, "--add-clipboard-account", provider, label],
                                    capture_output=True, text=True, timeout=120)
            # Cortex output is secret-free by contract; still never echo stdout raw lines containing the key.
            detail = " ".join(l for l in result.stdout.splitlines() if key not in l and l.startswith("Account not added"))
            status = "OK" if result.returncode == 0 else (detail or f"exit {result.returncode}")
            if result.returncode != 0 and "déjà" not in status:
                failures += 1
            print(f"{provider:12} {label:16} {status}")
    finally:
        subprocess.run(["pbcopy"], input=previous, check=False)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
