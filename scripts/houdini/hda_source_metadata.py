"""Compare saved HDA metadata across the demo directory migration.

The HDA graphs and embedded contracts and builder provenance remain byte-for-byte untouched.
Only the retired terrain_demo filesystem spelling in provenance is accepted as
an equivalent to the new demo location; contract, algorithm or graph changes still fail.
"""


def _current_paths(source: str) -> str:
    for previous, replacement in (("terrain_demo/", "demo/"),
                                  ('"terrain_demo",', '"demo",'),
                                  ("'terrain_demo',", "'demo',")):
        source = source.replace(previous, replacement)
    return source


def builder_source_matches(embedded: str | None, current: str) -> bool:
    return embedded is not None and _current_paths(embedded) == _current_paths(current)


def contract_metadata_matches(embedded: str | None, current: str) -> bool:
    """Retain exact contract comparison except for the directory move."""
    return embedded is not None and _current_paths(embedded) == _current_paths(current)
