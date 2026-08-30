# HAPI binding generator

HEGo doesn't link against HAPI directly - it loads `libHAPIL` at runtime and resolves every
entry point by name. `generate_houdini_api.py` writes the boilerplate for that: it parses the
HAPI headers of a Houdini install and generates `src/hapi/houdini_api.h` and
`src/hapi/houdini_api.cpp` in place.

Run it when you want to build against a different Houdini version.

## Usage

Works on Windows, Linux and macOS with Python 3.8+, from any directory:

```bash
python hapi_generator/generate_houdini_api.py
```

With no arguments it uses the newest Houdini install it can find, and writes the two files
straight into `src/hapi` - no copying by hand.

To pick a specific install:

```bash
# Windows
python hapi_generator/generate_houdini_api.py --hfs "C:\Program Files\Side Effects Software\Houdini 21.0.631"

# Linux
python hapi_generator/generate_houdini_api.py --hfs /opt/hfs21.0.631

# macOS
python hapi_generator/generate_houdini_api.py --hfs "/Applications/Houdini/Houdini21.0.631/Frameworks/Houdini.framework/Versions/Current/Resources"
```

The install is resolved the same way the build resolves it, so generating and building stay in
step: `--hfs`, then the `HFS` environment variable, then `SConstruct`'s `default_hfs` for this
OS, and only then the newest install found on the machine.

## Options

| Option | What it does |
| --- | --- |
| `--hfs PATH` | Houdini install root to parse |
| `--list` | List the Houdini installs found on this machine and exit |
| `--check` | Write nothing, exit 1 if `src/hapi` is out of date (handy in CI) |
| `--output-dir DIR` | Write somewhere other than `src/hapi` |
| `HEADER ...` | Parse these header files instead of an install's |

## After regenerating

`git diff src/hapi` shows what changed between the two Houdini versions. Removed or renamed
HAPI functions show up as compile errors in the rest of `src/`, so build once before
committing. Also bump the Houdini version in the main README and in `SConstruct`'s
`default_hfs` if you're moving the project to a new version.

## Notes

- The generated files always use LF line endings, on every OS, so a run on Windows doesn't
  produce a whole-file diff.
- Four headers are parsed: `HAPI.h`, `HAPI_Common.h`, `HAPI_Helpers.h` and `HAPI_Version.h`,
  from `<HFS>/toolkit/include/HAPI`.
- Only a Houdini *install* is needed for this, not a license.
