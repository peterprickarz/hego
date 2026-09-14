import os
import sys

project = "HEGo"
author = "HEGo Contributors"
copyright = "2026, HEGo Contributors"

extensions = [
    "sphinx_rtd_theme",
    "sphinxcontrib.youtube",
]

templates_path = ["_templates"]
exclude_patterns = [
    "_build",
    "Thumbs.db",
    ".DS_Store",
    ".tmp_rst/**",
    "tools/**",
]

html_theme = "sphinx_rtd_theme"
html_theme_options = {
    "collapse_navigation": False,
    "navigation_depth": 3,
    "titles_only": True,
}
html_static_path = ["_static"]

master_doc = "index"
language = "en"

# Pygments has no VEX lexer, and its GDScript one predates annotations, so snippets
# using @tool or s@attr fall back to relaxed lexing. They still render; the warning
# is noise, and silencing just this class keeps -W useful for real problems.
suppress_warnings = ["misc.highlighting_failure"]

# Keep class reference output from make_rst discoverable.
sys.path.insert(0, os.path.abspath("."))


def setup(app):
    """Teach Sphinx the one directive make_rst.py emits that is Godot's own.

    Godot's documentation site styles classref_note differently from a plain note; here
    there is nothing to style it against, and what it says is a note either way.
    """
    from docutils import nodes
    from docutils.parsers.rst.directives.admonitions import BaseAdmonition

    class ClassrefNote(BaseAdmonition):
        node_class = nodes.note

    app.add_directive("classref_note", ClassrefNote)
