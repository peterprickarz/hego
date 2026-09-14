#!/usr/bin/env bash
#
# Regenerates the class reference XML for HEGo's GDScript classes from their ## doc
# comments, into demo/addons/hego/doc_classes_gdscript.
#
# The XML is committed, exactly like the hand-written C++ XML next to it, because
# scripts/generate_docs.sh runs on Read the Docs where there is no Godot to run. Run this
# after changing a GDScript class's documentation comments and commit what it writes; the
# diff is the documentation change, which is worth reviewing.
#
# Set GODOT to pick the binary. Note that on some desktops `godot` on PATH is a wrapper
# that opens a terminal window, which never returns headless - point GODOT at the real
# executable if a run here hangs with no output.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/demo"
OUT_DIR="$ROOT_DIR/demo/addons/hego/doc_classes_gdscript"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

GODOT_BIN="${GODOT:-}"
if [[ -z "$GODOT_BIN" ]]; then
  for candidate in godot4 godot; do
    if command -v "$candidate" >/dev/null 2>&1; then
      GODOT_BIN="$(command -v "$candidate")"
      break
    fi
  done
fi

if [[ -z "$GODOT_BIN" ]]; then
  echo "Error: no Godot binary found. Set GODOT to the editor executable."
  exit 1
fi

echo "Generating GDScript class XML with $GODOT_BIN ..."
"$GODOT_BIN" --headless --path "$PROJECT_DIR" \
  --doctool "$TMP_DIR" --gdscript-docs "res://addons/hego" >/dev/null

echo "Cleaning and installing into $OUT_DIR ..."
python3 - "$TMP_DIR" "$OUT_DIR" <<'PY'
import os, re, shutil, sys
import xml.etree.ElementTree as ET

source_dir, out_dir = sys.argv[1], sys.argv[2]

# A script without a class_name is written out under its path, with slashes turned into
# double dashes. Those are the panel's own scripts, which are not API.
CLASS_FILE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\.xml$")

# Anything starting with an underscore is private by GDScript convention, including the
# lifecycle methods Godot calls. None of it belongs in a class reference.
PRIVATE_SECTIONS = ("methods", "members", "signals", "constants")

if os.path.isdir(out_dir):
    shutil.rmtree(out_dir)
os.makedirs(out_dir)

written = []
for name in sorted(os.listdir(source_dir)):
    if not CLASS_FILE.match(name):
        continue

    tree = ET.parse(os.path.join(source_dir, name))
    root = tree.getroot()
    for section_name in PRIVATE_SECTIONS:
        section = root.find(section_name)
        if section is None:
            continue
        for entry in list(section):
            if (entry.get("name") or "").startswith("_"):
                section.remove(entry)
        if len(section) == 0:
            root.remove(section)

    ET.indent(tree, "\t")
    tree.write(os.path.join(out_dir, name), encoding="unicode", xml_declaration=True)
    with open(os.path.join(out_dir, name), "a") as handle:
        handle.write("\n")
    written.append(name[:-4])

print("  " + "\n  ".join(written))
print(f"{len(written)} classes")
PY

echo "Done. Commit the changes under $OUT_DIR."
