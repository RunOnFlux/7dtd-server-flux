#!/usr/bin/env python3
"""Unpacks one downloaded mod archive (.zip, .tar, .tar.gz ...) into the mods volume.

    flux-unpack.py <archive> <mods dir>

A 7 Days to Die mod is a folder with a ModInfo.xml in it. Archives are packed three ways, and all
three end up as <mods dir>/<ModName>/ModInfo.xml:

  - ModName/ModInfo.xml                  the folder is used as it is
  - Mods/ModName/ModInfo.xml             the Mods/ level is dropped
  - ModInfo.xml                          a folder is made, named after the mod's <Name>

A mod folder that is already on the volume is replaced. Entries that would land outside the
mods dir (absolute paths, ..) are refused, and so is an archive with no ModInfo.xml at all.
"""
import os
import re
import shutil
import sys
import tarfile
import tempfile
import zipfile


def extract(archive, into):
    root = os.path.realpath(into)
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as z:
            for name in z.namelist():
                target = os.path.realpath(os.path.join(root, name))
                if not target.startswith(root + os.sep) and target != root:
                    raise ValueError("unsafe path in archive: %s" % name)
            z.extractall(root)
    elif tarfile.is_tarfile(archive):
        with tarfile.open(archive) as t:
            for member in t.getmembers():
                target = os.path.realpath(os.path.join(root, member.name))
                if not target.startswith(root + os.sep) and target != root:
                    raise ValueError("unsafe path in archive: %s" % member.name)
                if member.issym() or member.islnk():
                    raise ValueError("links are not allowed in a mod archive: %s" % member.name)
            t.extractall(root)
    else:
        raise ValueError("not a zip or tar archive")


def mod_name(modinfo):
    try:
        with open(modinfo, encoding="utf-8-sig", errors="replace") as f:
            m = re.search(r'<Name\s+value="([^"]+)"', f.read())
    except OSError:
        m = None
    name = re.sub(r"[^A-Za-z0-9._-]", "_", m.group(1)) if m else ""
    return name or "mod"


def mods_in(tree):
    """The folders that hold a ModInfo.xml, shallowest first, none inside another."""
    found = []
    for dirpath, dirnames, filenames in os.walk(tree):
        dirnames.sort()
        if any(f.lower() == "modinfo.xml" for f in filenames):
            found.append(dirpath)
            dirnames[:] = []
    return found


def main(argv):
    if len(argv) != 3:
        sys.stderr.write(__doc__)
        return 64
    archive, mods = argv[1], argv[2]
    os.makedirs(mods, exist_ok=True)
    work = tempfile.mkdtemp()
    try:
        extract(archive, work)
        folders = mods_in(work)
        if not folders:
            raise ValueError("no ModInfo.xml in the archive")
        for folder in folders:
            if os.path.realpath(folder) == os.path.realpath(work):
                info = [f for f in os.listdir(folder) if f.lower() == "modinfo.xml"][0]
                name = mod_name(os.path.join(folder, info))
            else:
                name = os.path.basename(folder)
            dest = os.path.join(mods, name)
            if os.path.isdir(dest):
                shutil.rmtree(dest)
            shutil.copytree(folder, dest)
            print(name)
        return 0
    except (ValueError, OSError, zipfile.BadZipFile, tarfile.TarError) as e:
        sys.stderr.write("%s\n" % e)
        return 1
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
