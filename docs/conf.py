import os
import sys

project = "HEGo"
author = "HEGo Contributors"
copyright = "2026, HEGo Contributors"

extensions = [
    "sphinx_rtd_theme",
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
html_sidebars = {
    "**": ["globaltoc.html", "searchbox.html"],
}

master_doc = "index"
language = "en"

# Keep class reference output from make_rst discoverable.
sys.path.insert(0, os.path.abspath("."))
