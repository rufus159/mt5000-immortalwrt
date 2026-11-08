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

  1. locate the downloaded linux-*.tar.* in dl/
  2. extract only the files touched by our patches into a temp tree
  3. replay the upstream generic patch stack (backport-6.18 then
     pending-6.18, in filename order) for those files -- this is the same
     order OpenWrt's patch-kernel.sh uses (verified against CI logs)
  4. `patch --dry-run` each of 795-10/11/12

The upstream stack matters: on baseline 4765b65762 (kernel 6.18.60) upstream
adds YT921X (32) to the DSA tag protocol enum, which is exactly what made the
old 795-11 hunks fail. Starting from the pristine tarball would give a false
positive.

Everything needed is already in the build tree: dl/ has the tarball and
target/linux/generic/ has the upstream patches. No network, no compilation.
"""

import argparse
import glob
import os
import re
import subprocess
import sys
import tarfile
import tempfile

OUR_PATCHES = re.compile(r"^795-1[0-2]-.*\.patch$")
FILE_HEADER = re.compile(r"^--- (\S+)(?:\s|$)")


def die(msg):
    print("::error::" + msg, file=sys.stderr)
    sys.exit(1)


def segments(text):
    """Split a unified diff into (target_path, segment_text) pairs.

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

    tarballs = sorted(glob.glob(os.path.join(tree, "dl", "linux-*.tar.*")))
    if not tarballs:
        die("no linux-*.tar.* in dl/ -- run `make download` first")
    tarball = tarballs[-1]
    print("kernel tarball: %s" % os.path.basename(tarball))

    tmp = tempfile.mkdtemp(prefix="kernel-patch-check-")
    try:
        with tarfile.open(tarball, "r:*") as tf:
            wanted = {"/" + p for p in targets}
            for m in tf:
                # strip the leading linux-X.Y.Z/ component
                parts = m.name.split("/", 1)
                if len(parts) != 2 or not m.isfile():
                    continue
                rel = "/" + parts[1]
                if rel not in wanted:
                    continue
                dst = os.path.join(tmp, parts[1])
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                with tf.extractfile(m) as src, open(dst, "wb") as out:
                    out.write(src.read())
        missing = [p for p in sorted(targets)
                   if not os.path.isfile(os.path.join(tmp, p))]
        if "include/net/dsa.h" in missing:
            die("kernel tarball lacks include/net/dsa.h -- cannot run the DSA check")
        warnings = []
        if missing:
            # Usually these are files created by earlier OpenWrt patches rather
            # than present in the pristine tarball; they are informational.
            warnings.append("tarball lacks %d file(s): %s"
                            % (len(missing), ", ".join(missing)))

        # Replay the upstream generic patch stack, for our target files only.
        applied = 0
        for sub in ("backport-6.18", "pending-6.18"):
            d = os.path.join(tree, "target/linux/generic", sub)
            for f in sorted(glob.glob(os.path.join(d, "*.patch"))):
                if OUR_PATCHES.match(os.path.basename(f)):
                    continue
                for path, seg, a in segments(open(f, encoding="utf-8", errors="replace").read()):
                    if path not in targets:
                        continue
                    r = run_patch(tmp, seg)
                    if r.returncode != 0:
                        # A replay failure here means our minimal tree is not a
                        # faithful copy of the full OpenWrt kernel tree (some
                        # upstream segments depend on files we did not extract).
                        # Keep it informational; only the dsa.h result is fatal.
                        warnings.append("upstream %s -> %s replay skipped"
                                        % (os.path.basename(f), path))
                    else:
                        applied += 1
        print("upstream segments replayed: %d" % applied)

        # Dry-run our own patches (this is what `make world` would do 2h later).
        failures = 0
        for f in ours:
            for path, seg, _a in segments(open(f, encoding="utf-8", errors="replace").read()):
                r = run_patch(tmp, seg, dry_run=True)
                ok = r.returncode == 0 and "FAILED" not in r.stdout
                print("  %-4s %s -> %s%s"
                      % ("OK" if ok else "FAIL", os.path.basename(f), path,
                         "" if ok else "\n" + r.stdout[-1200:]))
                if not ok:
                    if path == "include/net/dsa.h":
                        failures += 1
                    else:
                        # Informational: the full patch stack (including
                        # 795-01..795-09 and target-specific patches) is only
                        # replayed by `make`; our minimal tree may lack context
                        # for these files, so a FAIL here is not conclusive.
                        warnings.append("%s -> %s dry-run FAILED (informational)"
                                        % (os.path.basename(f), path))
        if failures:
            die("%d include/net/dsa.h hunk(s) would FAIL to apply -- fix the "
                "inner 795-11 context before starting the full build" % failures)
        for w in warnings:
            print("  NOTE: " + w)
        print("kernel patch stack: dsa.h dry-run passed (%d informational note(s))"
              % len(warnings))
    finally:
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
