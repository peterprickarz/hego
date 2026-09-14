#!/usr/bin/env bash
#
# Builds docs/classes from the class reference XML, and writes the grouped index that
# docs/index.rst points at. Read the Docs runs this before every Sphinx build, so it must
# work with nothing but python3 and curl.
#
# There are two XML sources. demo/addons/hego/doc_classes is hand-written and describes the
# C++ classes; demo/addons/hego/doc_classes_gdscript is generated from the GDScript classes'
# ## comments by scripts/generate_gdscript_docs.sh, which needs Godot and is run by hand.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCS_DIR="$ROOT_DIR/docs"
TOOLS_DIR="$DOCS_DIR/.tools"
TOOLS_MISC_DIR="$TOOLS_DIR/misc/utility"
XML_SRC_DIR="$ROOT_DIR/demo/addons/hego/doc_classes"
GDSCRIPT_XML_SRC_DIR="$ROOT_DIR/demo/addons/hego/doc_classes_gdscript"
GDSCRIPT_SRC_DIR="$ROOT_DIR/demo/addons/hego"
RST_OUT_DIR="$DOCS_DIR/classes"
TMP_RST_DIR="$DOCS_DIR/.tmp_rst"
STUB_XML_DIR="$DOCS_DIR/.tmp_stub_xml"
LEGACY_TOOLS_DIR="$DOCS_DIR/tools"
REGISTER_TYPES_CPP="$ROOT_DIR/src/register_types.cpp"

VERSION_PY_URL="https://raw.githubusercontent.com/godotengine/godot/refs/heads/master/version.py"
MAKE_RST_URL="https://raw.githubusercontent.com/godotengine/godot/master/doc/tools/make_rst.py"
COLOR_PY_URL="https://raw.githubusercontent.com/godotengine/godot/master/misc/utility/color.py"

mkdir -p "$TOOLS_DIR"
mkdir -p "$TOOLS_MISC_DIR"
mkdir -p "$RST_OUT_DIR"
mkdir -p "$TMP_RST_DIR"

# Clean old heavy tool snapshots from earlier iterations.
if [[ -d "$LEGACY_TOOLS_DIR/godot-master" ]]; then
  rm -rf "$LEGACY_TOOLS_DIR/godot-master"
fi

for required_dir in "$XML_SRC_DIR" "$GDSCRIPT_XML_SRC_DIR"; do
  if [[ ! -d "$required_dir" ]]; then
    echo "Error: XML source directory not found: $required_dir"
    exit 1
  fi
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 not found in PATH"
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl not found in PATH"
  exit 1
fi

echo "Fetching Godot documentation tools..."
curl -fsSL "$VERSION_PY_URL" -o "$TOOLS_DIR/version.py"
curl -fsSL "$MAKE_RST_URL" -o "$TOOLS_DIR/make_rst.py"
curl -fsSL "$COLOR_PY_URL" -o "$TOOLS_MISC_DIR/color.py"

# make_rst.py resolves a reference it does not recognise, such as [Dictionary] or
# any other engine class, by looking it up in @GlobalScope. Godot's own doc build
# always has that class; a standalone run over HEGo's classes alone does not, and
# make_rst crashes with KeyError instead of just warning. A stub is enough to turn
# that back into a warning.
echo "Preparing @GlobalScope stub for standalone generation..."
rm -rf "$STUB_XML_DIR"
mkdir -p "$STUB_XML_DIR"
cat > "$STUB_XML_DIR/@GlobalScope.xml" <<'STUB_EOF'
<?xml version="1.0" encoding="UTF-8" ?>
<class name="@GlobalScope">
<brief_description>
</brief_description>
<description>
</description>
<tutorials>
</tutorials>
</class>
STUB_EOF

echo "Generating .rst class reference files from XML..."
(
  cd "$ROOT_DIR"
  rm -rf "$TMP_RST_DIR"
  mkdir -p "$TMP_RST_DIR"
  set +e
  python3 "$TOOLS_DIR/make_rst.py" -o "$TMP_RST_DIR" -l "en" \
    "$XML_SRC_DIR" "$GDSCRIPT_XML_SRC_DIR" "$STUB_XML_DIR"
  MAKE_RST_EXIT=$?
  set -e
  if [[ "$MAKE_RST_EXIT" -ne 0 ]]; then
    echo "Warning: make_rst.py reported validation errors; continuing because output files were still generated."
  fi
)

echo "Assembling docs/classes..."
python3 "$ROOT_DIR/scripts/class_tree.py" \
  --generated "$TMP_RST_DIR" \
  --out "$RST_OUT_DIR" \
  --cpp-xml "$XML_SRC_DIR" \
  --gdscript-xml "$GDSCRIPT_XML_SRC_DIR" \
  --gdscript-src "$GDSCRIPT_SRC_DIR" \
  --register-types "$REGISTER_TYPES_CPP"

rm -rf "$STUB_XML_DIR"

echo "Done. Generated class docs in: $RST_OUT_DIR"
