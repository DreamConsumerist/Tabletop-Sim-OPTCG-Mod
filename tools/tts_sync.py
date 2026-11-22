#!/usr/bin/env python3
"""
Sync pipeline between this repo and the live Tabletop Simulator save file
for the One Piece TCG table ("1 - One Piece TCG attempt" / TS_Save_1.json).

TTS objects carry their Lua source inline in the save's JSON. This tool
extracts that source into individual tracked files (one per object, keyed
by GUID) and can push edited files back into a save JSON to load in-game.

Commands:
  status            Show what differs between the save and the repo.
  pull [--force]    Create files for any object script not yet tracked.
                     With --force, also overwrite already-tracked files
                     with the save's current content.
  push [--out PATH] Write repo file contents back into a save JSON.
                     Defaults to overwriting the source save (a .bak of
                     the original is kept next to it).
  watch [--interval SECONDS]
                     Poll the save file for changes and auto-pull new
                     objects as they appear. Never overwrites existing
                     tracked files (equivalent to a repeated plain pull).

Special, hand-maintained files are never overwritten by a plain pull/watch
(use --force to pull them deliberately):
  Global.lua       <- the save's top-level "LuaScript"
  CardImporter.lua <- the object with GUID 2bfaa2 (Custom_Tile, "OPEN IMPORTER")

The module chip (GUID b93b40) intentionally carries no script of its own --
Global.lua drives it entirely by GUID lookup (GetModuleChip()).

NOTE: the original CardImporter object (GUID c055f4, a plain Notecard) is
abandoned in the live save with stale pre-rewrite code still on it -- it was
superseded by 2bfaa2 when the in-game script editor stopped letting edits
land on it. It still physically exists on the table; delete it in-game when
convenient. Nothing in this tool references it anymore.
"""
import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OBJECTS_DIR = os.path.join(REPO_ROOT, "scripts", "objects")
MANIFEST_PATH = os.path.join(REPO_ROOT, "scripts", "manifest.json")
GLOBAL_FILE = os.path.join(REPO_ROOT, "Global.lua")

SPECIAL_FILES = {
    "2bfaa2": os.path.join(REPO_ROOT, "CardImporter.lua"),  # "Custom_Tile" (OPEN IMPORTER)
}

DEFAULT_SAVE = os.path.join(
    os.environ.get("USERPROFILE", ""),
    "Documents", "My Games", "Tabletop Simulator", "Saves", "TS_Save_1.json",
)


def load_save(path):
    with open(path, "r", encoding="utf-8-sig") as f:
        return json.load(f)


def write_save(data, path):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)


def sanitize(name):
    safe = "".join(c if c.isalnum() or c in "._- " else "_" for c in name).strip()
    return safe[:60] or "Unnamed"


def iter_object_entries(node):
    """Yield (guid, nickname, container_dict) for every object with a LuaScript."""
    if isinstance(node, dict):
        if "LuaScript" in node and node.get("LuaScript", "").strip():
            guid = node.get("GUID", "")
            nickname = node.get("Nickname") or node.get("Name") or "Unnamed"
            yield guid, nickname, node
        for v in node.values():
            if isinstance(v, (dict, list)):
                yield from iter_object_entries(v)
    elif isinstance(node, list):
        for item in node:
            yield from iter_object_entries(item)


def collect_objects(data):
    """Dedupe by GUID (TTS saves sometimes reuse a GUID across clones of the
    same prefab object; they carry identical script content in practice)."""
    by_guid = {}
    for guid, nickname, node in iter_object_entries(data.get("ObjectStates", [])):
        if not guid:
            continue
        by_guid.setdefault(guid, {"nickname": nickname, "script": node["LuaScript"], "count": 0})
        by_guid[guid]["count"] += 1
    return by_guid


def load_manifest():
    if os.path.exists(MANIFEST_PATH):
        with open(MANIFEST_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    return {"save_source": None, "last_sync": None, "objects": {}}


def save_manifest(manifest):
    os.makedirs(os.path.dirname(MANIFEST_PATH), exist_ok=True)
    with open(MANIFEST_PATH, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False)


def file_path_for(guid, nickname, manifest):
    if guid in SPECIAL_FILES:
        return SPECIAL_FILES[guid]
    existing = manifest["objects"].get(guid)
    if existing:
        return os.path.join(REPO_ROOT, existing["file"])
    fname = f"{sanitize(nickname)}_{guid}.lua"
    return os.path.join(OBJECTS_DIR, fname)


def read_file(path):
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8", newline="") as f:
        return f.read()


def write_file(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(content)


def cmd_status(args):
    data = load_save(args.save)
    manifest = load_manifest()
    objects = collect_objects(data)

    new, changed, same = [], [], []

    global_content = data.get("LuaScript", "")
    on_disk = read_file(GLOBAL_FILE)
    if on_disk is None:
        new.append(("Global.lua", "Global.lua"))
    elif on_disk != global_content:
        changed.append(("Global.lua", "Global.lua"))
    else:
        same.append("Global.lua")

    for guid, info in objects.items():
        path = file_path_for(guid, info["nickname"], manifest)
        rel = os.path.relpath(path, REPO_ROOT)
        on_disk = read_file(path)
        if on_disk is None:
            new.append((rel, info["nickname"]))
        elif on_disk != info["script"]:
            changed.append((rel, info["nickname"]))
        else:
            same.append(rel)

    print(f"Save: {args.save}")
    print(f"  {len(same)} file(s) match the save")
    print(f"  {len(new)} new (not yet tracked):")
    for rel, nick in new:
        print(f"    + {rel}  ({nick})")
    print(f"  {len(changed)} diverged (save and repo differ):")
    protected_names = {os.path.basename(p) for p in SPECIAL_FILES.values()} | {"Global.lua"}
    for rel, nick in changed:
        tag = " [special, needs --force]" if os.path.basename(rel) in protected_names else ""
        print(f"    ~ {rel}  ({nick}){tag}")


def cmd_pull(args):
    data = load_save(args.save)
    manifest = load_manifest()
    objects = collect_objects(data)

    created, updated, skipped = [], [], []

    global_content = data.get("LuaScript", "")
    on_disk = read_file(GLOBAL_FILE)
    if on_disk is None:
        write_file(GLOBAL_FILE, global_content)
        created.append("Global.lua")
    elif on_disk != global_content:
        if args.force:
            write_file(GLOBAL_FILE, global_content)
            updated.append("Global.lua")
        else:
            skipped.append("Global.lua")

    for guid, info in objects.items():
        path = file_path_for(guid, info["nickname"], manifest)
        rel = os.path.relpath(path, REPO_ROOT)
        on_disk = read_file(path)
        if on_disk is None:
            write_file(path, info["script"])
            manifest["objects"][guid] = {"file": rel.replace("\\", "/"), "nickname": info["nickname"]}
            created.append(rel)
        elif on_disk != info["script"]:
            if args.force:
                write_file(path, info["script"])
                updated.append(rel)
            else:
                skipped.append(rel)
        manifest["objects"].setdefault(guid, {"file": rel.replace("\\", "/"), "nickname": info["nickname"]})

    manifest["save_source"] = args.save
    manifest["last_sync"] = datetime.now(timezone.utc).isoformat()
    save_manifest(manifest)

    print(f"Created {len(created)}, updated {len(updated)}, skipped {len(skipped)} (diverged, needs --force).")
    for rel in created:
        print(f"  + {rel}")
    for rel in updated:
        print(f"  ~ {rel}")
    if skipped and not args.force:
        print("Skipped (pass --force to overwrite with the save's version):")
        for rel in skipped:
            print(f"    {rel}")


def set_script_by_guid(node, guid, script, counter):
    if isinstance(node, dict):
        if node.get("GUID") == guid and "LuaScript" in node:
            node["LuaScript"] = script
            counter[0] += 1
        for v in node.values():
            if isinstance(v, (dict, list)):
                set_script_by_guid(v, guid, script, counter)
    elif isinstance(node, list):
        for item in node:
            set_script_by_guid(item, guid, script, counter)


def cmd_push(args):
    manifest = load_manifest()
    if not manifest.get("save_source"):
        print("No manifest found — run `pull` at least once before `push`.", file=sys.stderr)
        sys.exit(1)

    data = load_save(args.save)

    global_content = read_file(GLOBAL_FILE)
    if global_content is not None:
        data["LuaScript"] = global_content

    for guid, path in SPECIAL_FILES.items():
        content = read_file(path)
        if content is not None:
            counter = [0]
            set_script_by_guid(data.get("ObjectStates", []), guid, content, counter)

    for guid, info in manifest["objects"].items():
        path = os.path.join(REPO_ROOT, info["file"])
        content = read_file(path)
        if content is None:
            continue
        counter = [0]
        set_script_by_guid(data.get("ObjectStates", []), guid, content, counter)

    out_path = args.out or args.save
    if out_path == args.save and not args.no_backup:
        bak_path = args.save + ".bak"
        with open(args.save, "rb") as src, open(bak_path, "wb") as dst:
            dst.write(src.read())
        print(f"Backed up original save to {bak_path}")

    write_save(data, out_path)
    print(f"Wrote {out_path}")


def cmd_watch(args):
    print(f"Watching {args.save} (Ctrl+C to stop)...")
    last_mtime = None
    while True:
        try:
            mtime = os.path.getmtime(args.save)
        except OSError:
            mtime = None
        if mtime is not None and mtime != last_mtime:
            if last_mtime is not None:
                print(f"\n[{datetime.now().isoformat(timespec='seconds')}] Save changed, pulling new objects...")
                cmd_pull(args)
            last_mtime = mtime
        time.sleep(args.interval)


def main():
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--save", default=DEFAULT_SAVE, help="Path to the TTS save JSON")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("status", help="Show what differs between the save and the repo")

    p_pull = sub.add_parser("pull", help="Pull object scripts from the save into tracked files")
    p_pull.add_argument("--force", action="store_true", help="Overwrite already-tracked files that diverged")

    p_push = sub.add_parser("push", help="Push tracked files back into a save JSON")
    p_push.add_argument("--out", default=None, help="Output path (default: overwrite --save in place)")
    p_push.add_argument("--no-backup", action="store_true", help="Skip writing a .bak of the original save")

    p_watch = sub.add_parser("watch", help="Poll the save file and auto-pull new objects as they appear")
    p_watch.add_argument("--interval", type=float, default=5.0, help="Poll interval in seconds")
    p_watch.add_argument("--force", action="store_true", help="Also overwrite diverged tracked files on each pull")

    args = parser.parse_args()
    {"status": cmd_status, "pull": cmd_pull, "push": cmd_push, "watch": cmd_watch}[args.command](args)


if __name__ == "__main__":
    main()
