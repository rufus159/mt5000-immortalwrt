#!/usr/bin/env python3
"""Early gate for the self-built kernel patches (795-10 / 795-11 / 795-12).

Why this exists
---------------
`git apply --check` in the "Apply MT5000 device patch" step only proves that
our *outer* patches can be written into the ImmortalWrt tree. It says nothing
about whether the *inner* kernel patches (the files we drop into
target/linux/generic/pending-6.18/) can be applied to the real Linux source
tree. That only happens deep inside `make world`, at the
toolchain/kernel-headers stage -- in CI run 42396108778 it took 2h10m to get
there before 795-11 died on include/net/dsa.h.

This script reproduces the kernel patch stack cheaply and does a dry-run of
our three patches against it, so the same failure surfaces in seconds:

  1. take the pristine files touched by our patches from a kernel tarball in
     dl/ (if `make download` already fetched one), or -- since OpenWrt only
     downloads the kernel tarball later, during target/linux/prepare --
     fetch include/net/dsa.h from the matching upstream stable tag
  2. replay the upstream generic patch stack (backport-6.18 then
     pending-6.18, in filename order) UP TO 795-11 ONLY -- patches named
     967-* sort after our 795-* files and are applied by make *after* 795-11
  3. `patch --dry-run` each of 795-10/11/12

The upstream stack matters: on baseline 4765b65762 (kernel 6.18.60) upstream
adds YT921X (32) to the DSA tag protocol enum, which is exactly what made the
old 795-11 hunks fail. Starting from the pristine tarball would give a false
positive. The version is read from target/linux/generic/kernel-6.18, so the
same gate works for both the 6.18.52 (2026-09-18) and 6.18.60 baselines.

Only `include/net/dsa.h` is fatal. Other files may be created by earlier
OpenWrt patches or need context we do not reconstruct here; their dry-run
results are informational and the real `make` run remains authoritative.

If neither the tarball nor the upstream file can be obtained, the gate prints
a warning and exits 0 rather than killing the build (CI run 42433695951 was
aborted after 8 minutes because an earlier version of this script mistook
`linux-firmware-20261019.tar.xz` for the kernel tarball).

CI run 42435518902: an earlier version replayed the WHOLE stack, including
967-27 / 967-40 (YT922x) which sort after 795-* and are applied by make only
after 795-11. That produced a final-state dsa.h with YT922X 33/34 and made an
already-correct 795-11 look broken. The replay is therefore cut at 795-11.
"""

import argparse
import base64
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

OUR_PATCHES = re.compile(r"^795-1[0-2]-.*\.patch$")
KERNEL_TARBALL = re.compile(
    r"^linux-(\d+\.\d+(?:\.\d+)?)\.tar\.(?:xz|gz|zst|bz2|lzma)$")
DSA_PATH = "include/net/dsa.h"


def die(msg):
    print("::error::" + msg, file=sys.stderr)
    sys.exit(1)


def warn(msg):
    print("::warning::" + msg, file=sys.stderr)


def segments(text):
    """Split a unified diff into (target_path, segment_text, source_path).

    Handles both git-style (`diff --git` + `--- a/x` / `+++ b/x`) and
    mail-style (bare `--- a/x` / `+++ b/x`) patches.
    """
    lines = text.splitlines(keepends=True)
    out = []
    i, n = 0, len(lines)
    while i < n:
        if lines[i].startswith("--- ") and i + 1 < n and lines[i + 1].startswith("+++ "):
            a = lines[i][4:].strip().split("\t")[0]
            b = lines[i + 1][4:].strip().split("\t")[0]
            b = b[2:] if b.startswith("b/") else b
            j = i + 2
            while j < n:
                if lines[j].startswith("diff --git "):
                    break
                if (lines[j].startswith("--- ") and j + 1 < n
                        and lines[j + 1].startswith("+++ ")):
                    break
                j += 1
            seg = "".join(lines[i:j])
            if "@@ " in seg:  # skip pure rename/mode-only blocks
                out.append((b, seg, a))
            i = j
        else:
            i += 1
    return out


def run_patch(cwd, seg, dry_run=False):
    cmd = ["patch", "-p1", "-f", "--no-backup-if-mismatch"]
    if dry_run:
        cmd.append("--dry-run")
    return subprocess.run(cmd, cwd=cwd, input=seg, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def kernel_version(tree):
    """Read e.g. `LINUX_VERSION-6.18 = .60` -> 6.18.60 from the target tree."""
    for f in sorted(glob.glob(os.path.join(tree, "target/linux/generic/kernel-*"))):
        if not os.path.isfile(f) or f.endswith((".mk", ".patch")):
            continue
        try:
            txt = open(f, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        m = re.search(r"^LINUX_VERSION-(\d+\.\d+)\s*[:?]?=\s*\.(\d+)\s*$",
                      txt, re.M)
        if m:
            return "%s.%s" % (m.group(1), m.group(2))
    return None


def fetch_upstream_dsa(version):
    """Fetch include/net/dsa.h from the matching stable tag (no auth needed)."""
    sources = [
        ("raw", "https://raw.githubusercontent.com/gregkh/linux/v%s/include/net/dsa.h"
         % version),
        ("api", "https://api.github.com/repos/gregkh/linux/contents/include/net/dsa.h?ref=v%s"
         % version),
    ]
    errors = []
    for kind, url in sources:
        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": "mt5000-kernel-patch-gate",
                              "Accept": "application/vnd.github+json"})
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = resp.read()
            if kind == "api":
                payload = json.loads(data.decode("utf-8"))
                return base64.b64decode(payload["content"]).decode("utf-8")
            return data.decode("utf-8")
        except Exception as e:  # noqa: BLE001 - network fallbacks are expected
            errors.append("%s: %s" % (kind, str(e)[:120]))
    print("  upstream dsa.h fetch errors: " + "; ".join(errors))
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--tree", default="immortalwrt",
                    help="path to the ImmortalWrt source tree")
    args = ap.parse_args()
    tree = os.path.abspath(args.tree)

    pending = os.path.join(tree, "target/linux/generic/pending-6.18")
    ours = sorted(f for f in glob.glob(os.path.join(pending, "*.patch"))
                  if OUR_PATCHES.match(os.path.basename(f)))
    if len(ours) != 3:
        die("expected exactly 3 self-built patches (795-10/11/12) in %s, found %d: %s"
            % (pending, len(ours), [os.path.basename(f) for f in ours]))
    print("self-built kernel patches: %s"
          % ", ".join(os.path.basename(f) for f in ours))

    # Which pristine kernel files do we need?
    targets = set()
    for f in ours:
        for path, _seg, a in segments(open(f, encoding="utf-8", errors="replace").read()):
            if a != "/dev/null":
                targets.add(path)
    print("pristine kernel files involved: %d" % len(targets))

    version = kernel_version(tree)
    print("kernel version from target tree: %s" % (version or "unknown"))

    tmp = tempfile.mkdtemp(prefix="kernel-patch-check-")
    try:
        # 1. Prefer the real kernel tarball. Only accept `linux-X.Y[.Z].tar.*`;
        #    `linux-firmware-*.tar.xz` and friends are NOT kernel sources.
        candidates = []
        for p in sorted(glob.glob(os.path.join(tree, "dl", "linux-*.tar.*"))):
            m = KERNEL_TARBALL.match(os.path.basename(p))
            if m and (version is None or m.group(1) == version):
                candidates.append(p)
        if candidates:
            tarball = candidates[-1]
            print("kernel tarball: %s" % os.path.basename(tarball))
            with tarfile.open(tarball, "r:*") as tf:
                wanted = {"/" + p for p in targets}
                for m in tf:
                    # strip the leading linux-X.Y.Z/ component
                    parts = m.name.split("/", 1)
                    if len(parts) != 2 or not m.isfile():
                        continue
                    if "/" + parts[1] not in wanted:
                        continue
                    dst = os.path.join(tmp, parts[1])
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    with tf.extractfile(m) as src, open(dst, "wb") as out:
                        out.write(src.read())
        else:
            print("no kernel source tarball in dl/ yet (OpenWrt fetches it in "
                  "target/linux/prepare)")

        # 2. make download does not fetch the kernel tarball, so fall back to
        #    the pristine dsa.h from the matching upstream stable tag.
        if not os.path.isfile(os.path.join(tmp, DSA_PATH)):
            if not version:
                warn("cannot determine kernel version; DSA dry-run skipped")
                return
            text = fetch_upstream_dsa(version)
            if text is None:
                warn("could not obtain pristine include/net/dsa.h (offline?); "
                     "DSA dry-run skipped -- the real make run will still verify it")
                return
            dst = os.path.join(tmp, DSA_PATH)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(dst, "w", encoding="utf-8", newline="\n") as out:
                out.write(text)
            print("pristine dsa.h: fetched from gregkh/linux v%s" % version)
        else:
            print("pristine dsa.h: extracted from tarball")

        have = {p for p in targets if os.path.isfile(os.path.join(tmp, p))}
        missing = sorted(targets - have)
        if missing:
            print("  NOTE: no pristine copy for %d file(s): %s"
                  % (len(missing), ", ".join(missing)))

        # 3. Replay the upstream stack, but ONLY the patches patch-kernel.sh
        #    applies BEFORE 795-11. Within each directory patches are sorted by
        #    filename, so 967-* (YT922x) come AFTER our 795-* files. Replaying
        #    the whole stack builds a final-state dsa.h with YT922X 33/34 that
        #    795-11 never sees -- CI run 42435518902 failed here for exactly
        #    this reason while 795-11 itself was already correct.
        ordered = []
        for sub in ("backport-6.18", "pending-6.18"):
            d = os.path.join(tree, "target/linux/generic", sub)
            ordered += sorted(glob.glob(os.path.join(d, "*.patch")),
                              key=os.path.basename)
        cut = next((i for i, f in enumerate(ordered)
                    if os.path.basename(f).startswith("795-11")), None)
        if cut is None:
            warn("795-11 missing from patch order; replaying the whole stack")
        else:
            ordered = ordered[:cut]
        print("upstream patches replayed up to 795-11: %d" % len(ordered))
        applied, replay_warnings = 0, []
        for f in ordered:
            if OUR_PATCHES.match(os.path.basename(f)):
                continue
            for path, seg, _a in segments(open(f, encoding="utf-8", errors="replace").read()):
                if path not in have:
                    continue
                r = run_patch(tmp, seg)
                if r.returncode != 0:
                    replay_warnings.append("upstream %s -> %s replay skipped"
                                           % (os.path.basename(f), path))
                else:
                    applied += 1
        print("upstream segments replayed: %d" % applied)

        # 4. Dry-run our own patches (this is what `make world` would do 2h later).
        failures, notes = 0, list(replay_warnings)
        for f in ours:
            for path, seg, _a in segments(open(f, encoding="utf-8", errors="replace").read()):
                if path not in have:
                    notes.append("%s -> %s not checked (pristine file unavailable)"
                                 % (os.path.basename(f), path))
                    continue
                r = run_patch(tmp, seg, dry_run=True)
                ok = r.returncode == 0 and "FAILED" not in r.stdout
                print("  %-4s %s -> %s%s"
                      % ("OK" if ok else "FAIL", os.path.basename(f), path,
                         "" if ok else "\n" + r.stdout[-1200:]))
                if not ok:
                    if path == DSA_PATH:
                        failures += 1
                    else:
                        notes.append("%s -> %s dry-run FAILED (informational)"
                                     % (os.path.basename(f), path))
        if failures:
            die("%d include/net/dsa.h hunk(s) would FAIL to apply -- fix the "
                "inner 795-11 context before starting the full build" % failures)
        for w in notes:
            print("  NOTE: " + w)
        print("kernel patch stack: dsa.h dry-run passed (%d informational note(s))"
              % len(notes))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
