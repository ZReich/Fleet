"""Canonical junction-proof deletion of orphaned directory trees (Windows).

Why this exists (LESSONS 2026-07-22): robocopy /PURGE and /MIR traverse directory
junctions, and a Get-ChildItem reparse re-scan-to-zero gate misses junctions under
long paths (silent enumeration failure). That combination deleted 1,899 tracked
files from the main Harken-v2 checkout.

CRITICAL (caught by this file's own self-test): os.walk(followlinks=False) is NOT
junction-safe on Windows — junctions are not symlinks, so walk descends into them.
Safety here comes from manual recursion that checks the reparse attribute BEFORE
descending. Never "simplify" this back to os.walk. Run --self-test after any edit.

Usage:
    python purge_orphan_tree.py <dir> [<dir> ...]
    python purge_orphan_tree.py --self-test

Prefer `git worktree remove` while a tree is still registered (git does not follow
junctions). This script is for trees that are already unregistered/orphaned.
"""
import os
import stat
import sys
import tempfile
import subprocess


def is_reparse(path):
    try:
        return bool(os.lstat(path).st_file_attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT)
    except OSError as exc:
        raise RuntimeError("lstat inspection failed; refusing subtree: {}: {}".format(path, exc))


def _purge_dir(path, counter):
    """Manual recursion: reparse check happens BEFORE any descent."""
    for entry in os.scandir(path):
        if is_reparse(entry.path):
            counter[0] += 1
            if entry.is_dir(follow_symlinks=False):
                os.rmdir(entry.path)  # unlink junction/dir-symlink; target untouched
            else:
                os.remove(entry.path)  # file symlink
        elif entry.is_dir(follow_symlinks=False):
            _purge_dir(entry.path, counter)
        else:
            try:
                os.chmod(entry.path, stat.S_IWRITE)
            except OSError:
                pass
            os.remove(entry.path)
    os.rmdir(path)


def purge(root):
    """Delete root bottom-up. Junctions/symlinks are unlinked, never entered."""
    root = "\\\\?\\" + os.path.abspath(root)
    if not os.path.exists(root) and not os.path.lexists(root):
        return "already gone", 0
    if is_reparse(root):
        # Root itself is a link: unlink only, never touch the target.
        os.rmdir(root)
        return "unlinked root junction", 1
    counter = [0]
    _purge_dir(root, counter)
    return "deleted", counter[0]


def self_test():
    base = tempfile.mkdtemp(prefix="purge-selftest-")
    canary_home = os.path.join(base, "canary-target")
    victim = os.path.join(base, "victim")
    os.makedirs(os.path.join(victim, "nested", "deep"))
    os.makedirs(canary_home)
    canary_file = os.path.join(canary_home, "must-survive.txt")
    with open(canary_file, "w") as fh:
        fh.write("alive")
    with open(os.path.join(victim, "nested", "junk.txt"), "w") as fh:
        fh.write("junk")
    ro = os.path.join(victim, "readonly.txt")
    with open(ro, "w") as fh:
        fh.write("ro")
    os.chmod(ro, stat.S_IREAD)
    # junction inside victim pointing OUT at the canary home
    link = os.path.join(victim, "nested", "escape-junction")
    subprocess.check_call(
        ["cmd", "/c", "mklink", "/J", link, canary_home],
        stdout=subprocess.DEVNULL,
    )
    status, junctions = purge(victim)
    assert status == "deleted", "victim not deleted: %s" % status
    assert junctions == 1, "expected 1 junction unlinked, got %d" % junctions
    assert not os.path.lexists(victim), "victim path still exists"
    assert os.path.exists(canary_file), "CANARY DELETED - junction was traversed!"
    with open(canary_file) as fh:
        assert fh.read() == "alive"
    # cleanup harness leftovers
    purge(canary_home)
    os.rmdir(base)
    print("self-test PASS: tree deleted, junction unlinked, canary survived")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    if sys.argv[1] == "--self-test":
        self_test()
    else:
        for target in sys.argv[1:]:
            status, junctions = purge(target)
            print("%s -> %s (junctions unlinked: %d)" % (target, status, junctions))
