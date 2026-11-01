# Island showcase material sources

These are **real CC0 assets selected for the persistent island showcase catalog**,
separate from the reusable terrain addon's defaults. They are not temporary
substitutions or artificial stress-test fixtures.
The 32 stable material IDs refer to 32 distinct ambientCG material sets. They are
not aliases or UV variations of six textures.

ambientCG publishes these assets under [Creative Commons CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/).
They may be copied, modified, redistributed, and used commercially without
permission or required attribution. See the provider's
[license statement](https://docs.ambientcg.com/license/).

The source catalog is `../assets/ambientcg_sources.json`. Per-set source URLs,
archive SHA256 hashes, actual map dimensions, and generated texture hashes are
recorded in `../assets/material_manifest.json`. `material_registry.json` records
the stable ID, `material_<name>` channel, resource path, and source URL used by
the demo. `../assets/material_contact_sheet.jpg` shows the real Color maps.

Reproduce from the repository root with:

```sh
python3 scripts/prepare_island_materials.py --workers 4
```

Downloads are cached outside the repository under
`~/.cache/hego-terrain/ambientcg`. Four downloads run concurrently by default;
`--workers 8` explicitly permits up to eight, while honoring provider
`Retry-After` responses. Decoding and packing stay sequential. Interrupted ZIP
downloads resume with validated HTTP ranges. Color and OpenGL NormalGL JPEGs are
preserved as supplied. Lossless ORMH packs source AO, source Roughness, constant
nonmetallic zero, and source Displacement into RGBA. No source set is duplicated
to fill material slots.

Existing `.tres` material resources retain all artist tuning and UIDs byte for
byte on normal reruns, including `--resources-only`. Missing resources receive
catalog defaults. `--reset-resources` explicitly regenerates existing resources
and discards their tuning/UIDs. `--refresh` only refreshes downloaded archives;
it does not opt into resetting resources. Unchanged texture/import bytes are
not rewritten, avoiding unnecessary editor reimports.

Ecological names are demo placement hints, not scientific classifications.
For example, `grey_cliff` makes no granite claim, `short_grass` is green,
`thin_grass` is not a heather scan, and `clean_snow` is smooth snow.
`damp_soil` is fine damp sandy ground, not dark organic mud. `forest_loam` is a
stable channel name for bare forest earth; no scientific loam classification is
claimed. Their registry roles/descriptions reflect these limits.

New sources with a nonzero ambientCG physical width use that width for their
default UV repeat. Unknown-size sources use explicit artist estimates: 8 m for
cliff rock, 4 m for sand/snow, and 2 m for other ground/grass. The catalog records
which basis applies. The first six existing resources keep the user's authored
scales and all other controls even where provider dimensions are available.

The offline preparation safety regression is:

```sh
python3 -m unittest discover -s scripts/tests -p test_prepare_island_materials.py -v
```

The complete catalog was checked against its downloaded ZIPs: 32 unique source
IDs and Color hashes, exact source Color/NormalGL bytes, matching 2K map
dimensions (rectangular source maps remain rectangular), bit-exact AO/Roughness/
Displacement packing, and nonmetallic zero. The original six artist-edited
resources retained their captured SHA256 hashes after preparation.
