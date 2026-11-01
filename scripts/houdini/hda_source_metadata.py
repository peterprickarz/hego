"""Compare saved HDA metadata across the repository's directory migrations.

The HDA graphs and embedded contracts and builder provenance remain byte-for-byte untouched.
Only retired filesystem spellings in provenance are accepted as equivalent to the current
locations: the terrain_demo checkout layout that became demo/, and the demo/island/hda
folder the HDA files lived in before moving to otls/. Contract, algorithm or graph changes
still fail.
"""
import re


def _current_paths(source: str) -> str:
    for previous, replacement in (("terrain_demo/", "demo/"),
                                  ('"terrain_demo",', '"demo",'),
                                  ("'terrain_demo',", "'demo',")):
        source = source.replace(previous, replacement)
    source = re.sub(r"demo/island/hda/([A-Za-z0-9_]+\.hda)", r"otls/\1", source)
    source = source.replace('"demo", "island", "hda", "', '"otls", "')
    return source


def builder_source_matches(embedded: str | None, current: str) -> bool:
    return embedded is not None and _current_paths(embedded) == _current_paths(current)


def contract_metadata_matches(embedded: str | None, current: str) -> bool:
    """Retain exact contract comparison except for the directory move."""
    return embedded is not None and _current_paths(embedded) == _current_paths(current)
