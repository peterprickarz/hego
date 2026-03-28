#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCS_DIR="$ROOT_DIR/docs"
TOOLS_DIR="$DOCS_DIR/.tools"
TOOLS_MISC_DIR="$TOOLS_DIR/misc/utility"
XML_SRC_DIR="$ROOT_DIR/demo/addons/hego/doc_classes"
RST_OUT_DIR="$DOCS_DIR/classes"
TMP_RST_DIR="$DOCS_DIR/.tmp_rst"
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

if [[ ! -d "$XML_SRC_DIR" ]]; then
  echo "Error: XML source directory not found: $XML_SRC_DIR"
  exit 1
fi

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

echo "Generating .rst class reference files from XML..."
(
  cd "$ROOT_DIR"
  rm -rf "$TMP_RST_DIR"
  mkdir -p "$TMP_RST_DIR"
  set +e
  python3 "$TOOLS_DIR/make_rst.py" -o "$TMP_RST_DIR" -l "en" "$XML_SRC_DIR"
  MAKE_RST_EXIT=$?
  set -e
  if [[ "$MAKE_RST_EXIT" -ne 0 ]]; then
    echo "Warning: make_rst.py reported validation errors; continuing because output files were still generated."
  fi
)

echo "Copying HEGo class pages into docs/classes..."
rm -rf "$RST_OUT_DIR"
mkdir -p "$RST_OUT_DIR"
find "$TMP_RST_DIR" -maxdepth 1 -type f -name "*hego*.rst" -exec cp {} "$RST_OUT_DIR" \;

if [[ ! -f "$REGISTER_TYPES_CPP" ]]; then
  echo "Error: register types file not found: $REGISTER_TYPES_CPP"
  exit 1
fi

class_symbol_to_name() {
  local symbol="$1"
  symbol="${symbol// /}"
  echo "${symbol##*::}"
}

class_name_to_page() {
  local class_name="$1"
  local lower
  lower="$(echo "$class_name" | tr '[:upper:]' '[:lower:]')"
  echo "class_${lower}"
}

declare -A ABSTRACT_CLASS_BY_NAME=()
declare -A VIRTUAL_CLASS_BY_NAME=()
declare -A CONCRETE_CLASS_BY_NAME=()
declare -A CLASS_KIND_BY_PAGE=()

while IFS= read -r symbol; do
  symbol="${symbol// /}"
  [[ -z "$symbol" ]] && continue
  class_name="$(class_symbol_to_name "$symbol")"
  ABSTRACT_CLASS_BY_NAME["$class_name"]=1
done < <(awk '
  {
    print
  }
' "$REGISTER_TYPES_CPP" | grep -v '^[[:space:]]*//' | sed -n 's/.*GDREGISTER_ABSTRACT_CLASS(\([^)]*\)).*/\1/p')

while IFS= read -r symbol; do
  symbol="${symbol// /}"
  [[ -z "$symbol" ]] && continue
  class_name="$(class_symbol_to_name "$symbol")"
  VIRTUAL_CLASS_BY_NAME["$class_name"]=1
done < <(awk '
  {
    print
  }
' "$REGISTER_TYPES_CPP" | grep -v '^[[:space:]]*//' | sed -n 's/.*GDREGISTER_VIRTUAL_CLASS(\([^)]*\)).*/\1/p')

while IFS= read -r symbol; do
  symbol="${symbol// /}"
  [[ -z "$symbol" ]] && continue

  # Keep only top-level HEGo API classes in sidebar (exclude util internals).
  if [[ "$symbol" != HEGo::* ]] || [[ "$symbol" == HEGo::Util::* ]]; then
    continue
  fi

  class_name="$(class_symbol_to_name "$symbol")"
  CONCRETE_CLASS_BY_NAME["$class_name"]=1
done < <(awk '
  {
    print
  }
' "$REGISTER_TYPES_CPP" | grep -v '^[[:space:]]*//' | sed -n 's/.*ClassDB::register_class<\([^>]*\)>.*/\1/p')

PUBLIC_CLASS_PAGES=()
for class_name in "${!CONCRETE_CLASS_BY_NAME[@]}"; do
  page="$(class_name_to_page "$class_name")"
  if [[ -f "$RST_OUT_DIR/$page.rst" ]]; then
    PUBLIC_CLASS_PAGES+=("$page")
  fi
done

if [[ "${#PUBLIC_CLASS_PAGES[@]}" -eq 0 ]]; then
  echo "Error: no public class pages found from register_types.cpp"
  exit 1
fi

IFS=$'\n' PUBLIC_CLASS_PAGES=( $(printf '%s\n' "${PUBLIC_CLASS_PAGES[@]}" | sort) )
unset IFS

for class_name in "${!ABSTRACT_CLASS_BY_NAME[@]}"; do
  page="$(class_name_to_page "$class_name")"
  CLASS_KIND_BY_PAGE["$page"]="Abstract"
done

for class_name in "${!VIRTUAL_CLASS_BY_NAME[@]}"; do
  page="$(class_name_to_page "$class_name")"
  CLASS_KIND_BY_PAGE["$page"]="Virtual"
done

for class_name in "${!CONCRETE_CLASS_BY_NAME[@]}"; do
  page="$(class_name_to_page "$class_name")"
  CLASS_KIND_BY_PAGE["$page"]="Concrete"
done

# Build a curated class index (left tree) with public classes only.
{
  echo "HEGo Class Reference"
  echo "===================="
  echo
  echo ".. toctree::"
  echo "   :maxdepth: 1"
  echo
  for page in "${PUBLIC_CLASS_PAGES[@]}"; do
    if [[ -f "$RST_OUT_DIR/$page.rst" ]]; then
      echo "   $page"
    fi
  done
} > "$RST_OUT_DIR/index.rst"

is_public_class_page() {
  local page="$1"
  for public in "${PUBLIC_CLASS_PAGES[@]}"; do
    if [[ "$page" == "$public" ]]; then
      return 0
    fi
  done
  return 1
}

# Keep internal class pages linkable without showing them in navigation.
for page_file in "$RST_OUT_DIR"/class_hego*.rst; do
  page_name="$(basename "$page_file" .rst)"
  if ! is_public_class_page "$page_name"; then
    tmp_file="$(mktemp)"
    {
      echo ":orphan:"
      echo
      cat "$page_file"
    } > "$tmp_file"
    mv "$tmp_file" "$page_file"
  fi
done

append_class_registration_hint() {
  local page_file="$1"
  local kind="$2"
  if [[ ! -f "$page_file" ]] || [[ -z "$kind" ]]; then
    return 0
  fi

  {
    echo
    echo ".. rst-class:: classref-section-separator"
    echo
    echo "----"
    echo
    echo ".. rst-class:: classref-descriptions-group"
    echo
    echo "Class Registration"
    echo "------------------"
    echo
    echo "- Kind: ${kind}"
  } >> "$page_file"
}

for page_file in "$RST_OUT_DIR"/class_hego*.rst; do
  page_name="$(basename "$page_file" .rst)"
  append_class_registration_hint "$page_file" "${CLASS_KIND_BY_PAGE[$page_name]:-}"
done

append_inherited_methods_section() {
  local page_file="$1"
  if [[ ! -f "$page_file" ]]; then
    return 0
  fi

  {
    echo
    echo ".. rst-class:: classref-section-separator"
    echo
    echo "----"
    echo
    cat
  } >> "$page_file"
}

append_inherited_methods_section "$RST_OUT_DIR/class_hegoassetnode.rst" <<'EOF'
.. rst-class:: classref-descriptions-group

Inherited Methods
-----------------

- :ref:`set_transform()<class_HEGoTransformableNode_method_set_transform>` from :ref:`HEGoTransformableNode<class_HEGoTransformableNode>`.
- :ref:`connect_input()<class_HEGoTransformableInputReceiverNode_method_connect_input>` from :ref:`HEGoTransformableInputReceiverNode<class_HEGoTransformableInputReceiverNode>`.
- :ref:`get_id()<class_HEGoBaseNode_method_get_id>`, :ref:`instantiate()<class_HEGoBaseNode_method_instantiate>`, :ref:`reset_node_id()<class_HEGoBaseNode_method_reset_node_id>` from :ref:`HEGoBaseNode<class_HEGoBaseNode>`.
EOF

append_inherited_methods_section "$RST_OUT_DIR/class_hegocurveinputnode.rst" <<'EOF'
.. rst-class:: classref-descriptions-group

Inherited Methods
-----------------

- :ref:`set_prim_attr()<class_HEGoBaseInputNode_method_set_prim_attr>` from :ref:`HEGoBaseInputNode<class_HEGoBaseInputNode>`.
- :ref:`set_transform()<class_HEGoTransformableNode_method_set_transform>` from :ref:`HEGoTransformableNode<class_HEGoTransformableNode>`.
- :ref:`get_id()<class_HEGoBaseNode_method_get_id>`, :ref:`instantiate()<class_HEGoBaseNode_method_instantiate>`, :ref:`reset_node_id()<class_HEGoBaseNode_method_reset_node_id>` from :ref:`HEGoBaseNode<class_HEGoBaseNode>`.
EOF

append_inherited_methods_section "$RST_OUT_DIR/class_hegoheightfieldinputnode.rst" <<'EOF'
.. rst-class:: classref-descriptions-group

Inherited Methods
-----------------

- :ref:`set_prim_attr()<class_HEGoBaseInputNode_method_set_prim_attr>` from :ref:`HEGoBaseInputNode<class_HEGoBaseInputNode>`.
- :ref:`set_transform()<class_HEGoTransformableNode_method_set_transform>` from :ref:`HEGoTransformableNode<class_HEGoTransformableNode>`.
- :ref:`get_id()<class_HEGoBaseNode_method_get_id>`, :ref:`instantiate()<class_HEGoBaseNode_method_instantiate>`, :ref:`reset_node_id()<class_HEGoBaseNode_method_reset_node_id>` from :ref:`HEGoBaseNode<class_HEGoBaseNode>`.
EOF

append_inherited_methods_section "$RST_OUT_DIR/class_hegoinputnode.rst" <<'EOF'
.. rst-class:: classref-descriptions-group

Inherited Methods
-----------------

- :ref:`set_prim_attr()<class_HEGoBaseInputNode_method_set_prim_attr>` from :ref:`HEGoBaseInputNode<class_HEGoBaseInputNode>`.
- :ref:`set_transform()<class_HEGoTransformableNode_method_set_transform>` from :ref:`HEGoTransformableNode<class_HEGoTransformableNode>`.
- :ref:`get_id()<class_HEGoBaseNode_method_get_id>`, :ref:`instantiate()<class_HEGoBaseNode_method_instantiate>`, :ref:`reset_node_id()<class_HEGoBaseNode_method_reset_node_id>` from :ref:`HEGoBaseNode<class_HEGoBaseNode>`.
EOF

append_inherited_methods_section "$RST_OUT_DIR/class_hegomergenode.rst" <<'EOF'
.. rst-class:: classref-descriptions-group

Inherited Methods
-----------------

- :ref:`connect_input()<class_HEGoInputReceiverNode_method_connect_input>` from :ref:`HEGoInputReceiverNode<class_HEGoInputReceiverNode>`.
- :ref:`get_id()<class_HEGoBaseNode_method_get_id>`, :ref:`instantiate()<class_HEGoBaseNode_method_instantiate>`, :ref:`reset_node_id()<class_HEGoBaseNode_method_reset_node_id>` from :ref:`HEGoBaseNode<class_HEGoBaseNode>`.
EOF

if [[ -z "$(find "$RST_OUT_DIR" -maxdepth 1 -type f -name "*.rst" -print -quit)" ]]; then
  echo "Error: no HEGo .rst files were generated"
  exit 1
fi

echo "Done. Generated class docs in: $RST_OUT_DIR"
