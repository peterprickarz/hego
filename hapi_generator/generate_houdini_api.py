#!/usr/bin/env python3
"""Generate src/hapi/houdini_api.h and src/hapi/houdini_api.cpp from the HAPI headers.

The HAPI functions are not linked against directly - HEGo loads libHAPIL at
runtime and resolves every entry point by name. This script parses the HAPI
headers that ship with a Houdini install and emits the boilerplate for that:
a function pointer typedef, a static function pointer, and an empty stub for
every HAPI_DECL, plus the initialize/finalize bodies that swap the pointers
between the real exports and the stubs.

Usage (Windows, Linux and macOS):

    python generate_houdini_api.py                 # auto-detect newest Houdini
    python generate_houdini_api.py --hfs <path>    # use a specific install
    python generate_houdini_api.py --check         # is src/hapi up to date?
    python generate_houdini_api.py --list          # show detected installs

The generated files are written straight into src/hapi - no copying by hand.
"""

from __future__ import annotations

import argparse
import glob
import os
import platform
import re
import sys

# ───────────────────────────────────────────────
# Locations
# ───────────────────────────────────────────────

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)
DEFAULT_OUTPUT_DIR = os.path.join(REPO_ROOT, "src", "hapi")

# Relative to HFS. Same on all three platforms (on macOS HFS points at
# .../Houdini.framework/Versions/Current/Resources, which has toolkit/ inside).
HEADER_SUBDIR = os.path.join("toolkit", "include", "HAPI")

# Parsed in this order - the order decides the order of the generated code.
HAPI_HEADERS = ("HAPI.h", "HAPI_Common.h", "HAPI_Helpers.h", "HAPI_Version.h")


def default_install_globs():
    """Glob patterns for the stock Houdini install locations of this OS."""
    system = platform.system()

    if system == "Windows":
        roots = {
            os.environ.get("ProgramFiles", r"C:\Program Files"),
            os.environ.get("ProgramW6432", r"C:\Program Files"),
        }
        return [os.path.join(root, "Side Effects Software", "Houdini*") for root in sorted(roots)]

    if system == "Darwin":
        return [
            "/Applications/Houdini/Houdini*/Frameworks/Houdini.framework/Versions/Current/Resources",
            "/Applications/Houdini/Houdini*/Houdini.framework/Versions/Current/Resources",
        ]

    # Linux (and anything else unix-y): the SideFX installer defaults to /opt.
    return [
        "/opt/hfs*",
        os.path.expanduser("~/houdini*/hfs*"),
    ]


def header_dir(hfs):
    return os.path.join(hfs, HEADER_SUBDIR)


def is_houdini_install(hfs):
    """True if hfs looks like a Houdini root we can generate from."""
    return all(os.path.isfile(os.path.join(header_dir(hfs), name)) for name in HAPI_HEADERS)


def read_houdini_version(hfs):
    """Return the Houdini version of an install as a tuple, e.g. (21, 0, 631)."""
    version_header = os.path.join(header_dir(hfs), "HAPI_Version.h")
    try:
        with open(version_header, "r", encoding="utf-8", errors="replace") as file:
            content = file.read()
    except OSError:
        return (0, 0, 0)

    version = []
    for part in ("MAJOR", "MINOR", "BUILD"):
        match = re.search(r"#define\s+HAPI_VERSION_HOUDINI_%s\s+(\d+)" % part, content)
        version.append(int(match.group(1)) if match else 0)
    return tuple(version)


def format_version(version):
    return ".".join(str(part) for part in version)


def find_houdini_installs():
    """All Houdini installs in the stock locations, newest first."""
    seen = set()
    installs = []

    for pattern in default_install_globs():
        for candidate in glob.glob(pattern):
            # /opt/hfs21.0 is usually a symlink to /opt/hfs21.0.729 - keep one.
            resolved = os.path.realpath(candidate)
            if resolved in seen or not is_houdini_install(resolved):
                continue
            seen.add(resolved)
            installs.append((read_houdini_version(resolved), resolved))

    installs.sort(reverse=True)
    return installs


def scons_default_hfs():
    """The install SConstruct falls back to, so a plain run matches a plain build.

    Best effort - if SConstruct is restructured this just returns None and we
    fall back to picking the newest install on the machine.
    """
    try:
        with open(os.path.join(REPO_ROOT, "SConstruct"), "r", encoding="utf-8", errors="replace") as file:
            content = file.read()
    except OSError:
        return None

    block = re.search(r"default_hfs\s*=\s*\{(.*?)\}", content, re.DOTALL)
    if not block:
        return None

    entry = re.search(r'["\']%s["\']\s*:\s*r?["\'](.+?)["\']' % platform.system(), block.group(1))
    return entry.group(1) if entry else None


def resolve_hfs(explicit_hfs):
    """Pick the Houdini install to parse.

    In the same order the build resolves it: --hfs, then $HFS, then the
    SConstruct default, and only then the newest install found on the machine.
    """
    for hfs, source in ((explicit_hfs, "--hfs"), (os.environ.get("HFS"), "$HFS")):
        if not hfs:
            continue
        hfs = os.path.abspath(os.path.expanduser(hfs))
        if not is_houdini_install(hfs):
            sys.exit(
                "Error: %s points at '%s', which has no HAPI headers.\n"
                "Expected to find %s in %s" % (source, hfs, ", ".join(HAPI_HEADERS), header_dir(hfs))
            )
        return hfs, source

    scons_hfs = scons_default_hfs()
    if scons_hfs and is_houdini_install(scons_hfs):
        return os.path.realpath(scons_hfs), "SConstruct default_hfs"

    installs = find_houdini_installs()
    if not installs:
        patterns = "\n  ".join(default_install_globs())
        sys.exit(
            "Error: no Houdini install found. Searched:\n  %s\n\n"
            "Pass one explicitly with --hfs <path>, or set the HFS environment variable." % patterns
        )

    if len(installs) > 1:
        print("Note: %d Houdini installs found, using the newest - see --list, or pass --hfs" % len(installs))

    version, hfs = installs[0]
    return hfs, "auto-detected Houdini %s" % format_version(version)


# ───────────────────────────────────────────────
# Parsing
# ───────────────────────────────────────────────


def parse_file(file_path):
    """Extract every HAPI_DECL declaration from one header.

    Returns a list of {"type", "func", "args"} dicts, where func has the
    HAPI_ prefix stripped (HAPI_IsInitialized becomes IsInitialized).
    """
    with open(file_path, "r", encoding="utf-8", errors="replace") as file:
        content = file.read()

    # Declarations wrap over several lines, so collect from HAPI_DECL to the ';'.
    matched_substrings = []
    current_decl = ""
    inside_decl = False

    for line in content.splitlines():
        stripped_line = line.strip()
        if "HAPI_DECL" in stripped_line or "HAPI_DECL_RETURN" in stripped_line:
            inside_decl = True
            current_decl = stripped_line
            if ";" in stripped_line:
                matched_substrings.append(current_decl)
                current_decl = ""
                inside_decl = False
        elif inside_decl:
            current_decl += " " + stripped_line
            if ";" in stripped_line:
                matched_substrings.append(current_decl)
                current_decl = ""
                inside_decl = False

    # Collapse the line breaks and indentation into single spaces.
    cleaned_substrings = [" ".join(substring.split()) for substring in matched_substrings]

    parsed_entries = []
    for substring in cleaned_substrings:
        if "HAPI_DECL_DEPRECATED_REPLACE" in substring:
            continue
        elif "HAPI_DECL_RETURN" in substring:
            # HAPI_DECL_RETURN( <type> ) HAPI_<name>( <args> );
            type_start = substring.find("(") + 1
            type_end = substring.find(")", type_start)
            type_part = substring[type_start:type_end].strip()
            func_start = substring.find("HAPI_", type_end) + len("HAPI_")
        else:
            # HAPI_DECL HAPI_<name>( <args> );  - always returns HAPI_Result.
            type_part = "HAPI_Result"
            func_start = substring.find("HAPI_", substring.find("HAPI_DECL") + len("HAPI_DECL")) + len("HAPI_")

        func_end = substring.find("(", func_start)
        func_part = substring[func_start:func_end].strip()

        args_start = func_end + 1
        args_end = substring.find(")", args_start)
        args_part = substring[args_start:args_end].strip()

        parsed_entries.append({"type": type_part, "func": func_part, "args": args_part})

    return parsed_entries


def parse_headers(header_paths):
    """Parse every header and drop functions that show up more than once."""
    all_entries = []
    seen_funcs = set()

    for header_path in header_paths:
        for entry in parse_file(header_path):
            if entry["func"] in seen_funcs:
                continue
            seen_funcs.add(entry["func"])
            all_entries.append(entry)

    return all_entries


# ───────────────────────────────────────────────
# Code generation
# ───────────────────────────────────────────────


def format_function_pointers(entries):
    return ["typedef %s(*%sFuncPtr)(%s);" % (e["type"], e["func"], e["args"]) for e in entries]


def format_static_function_pointers(entries):
    return ["static %sFuncPtr %s;" % (e["func"], e["func"]) for e in entries]


def format_empty_stub_declarations(entries):
    return ["static %s %sEmptyStub(%s);" % (e["type"], e["func"], e["args"]) for e in entries]


def format_static_definitions(entries):
    """The file-scope definitions of the static pointers, pre-set to the stubs."""
    formatted_list = []
    for entry in entries:
        func_name = entry["func"]
        formatted_list.append("HoudiniApi::%sFuncPtr" % func_name)
        formatted_list.append("HoudiniApi::%s = &HoudiniApi::%sEmptyStub;" % (func_name, func_name))
        formatted_list.append("")
    return formatted_list


def format_initializations(entries):
    return [
        'HoudiniApi::%s = (%sFuncPtr)HEGoPlatform::get_dll_export(library_handle, "HAPI_%s");'
        % (e["func"], e["func"], e["func"])
        for e in entries
    ]


def format_stub_initializations(entries):
    return ["HoudiniApi::%s = &HoudiniApi::%sEmptyStub;" % (e["func"], e["func"]) for e in entries]


def format_stub_definitions(entries):
    """The bodies of the stubs - each returns a harmless failure/default value."""
    formatted_list = []
    for entry in entries:
        func_type = entry["type"]

        formatted_list.append(func_type)
        formatted_list.append("HoudiniApi::%sEmptyStub(%s)" % (entry["func"], entry["args"]))
        formatted_list.append("{")

        if func_type == "HAPI_Result":
            return_statement = " HAPI_RESULT_FAILURE;"
        elif func_type.startswith("HAPI_"):
            return_statement = " %s();" % func_type
        elif func_type == "int":
            return_statement = " -1;"
        else:
            return_statement = ";"

        formatted_list.append("    return%s" % return_statement)
        formatted_list.append("}")

    return formatted_list


def generate_header(entries):
    header = """
#pragma once
#include "HAPI/HAPI.h"


struct HoudiniApi
{
public:

    static void initialize_hapi(void* library_handle);
    static void finalize_hapi();
    static bool is_hapi_initialized();

public:

"""
    for line in format_function_pointers(entries):
        header += "   " + line + "\n"

    header += """

public:

"""
    for line in format_static_function_pointers(entries):
        header += "   " + line + "\n"

    header += """

public:

"""
    for line in format_empty_stub_declarations(entries):
        header += "   " + line + "\n"

    header += """
};
"""
    return header


def generate_cpp(entries):
    cpp = """

#include "houdini_api.h"
#include "hego_platform.h"

"""
    for line in format_static_definitions(entries):
        cpp += "  " + line + "\n"

    cpp += """

void
HoudiniApi::initialize_hapi(void* library_handle)
{
	if(!library_handle) return;

"""
    for line in format_initializations(entries):
        cpp += "  " + line + "\n"

    cpp += """

}


void
HoudiniApi::finalize_hapi()
{

"""
    for line in format_stub_initializations(entries):
        cpp += "  " + line + "\n"

    cpp += """
}


bool
HoudiniApi::is_hapi_initialized()
{
	return ( HoudiniApi::IsInitialized != &HoudiniApi::IsInitializedEmptyStub );
}




"""
    for line in format_stub_definitions(entries):
        cpp += line + "\n"

    return cpp


# ───────────────────────────────────────────────
# Output
# ───────────────────────────────────────────────


def read_existing(path):
    try:
        with open(path, "r", encoding="utf-8", newline="") as file:
            return file.read()
    except OSError:
        return None


def write_generated(path, content):
    """Write with LF endings on every OS so Windows runs don't churn the diff."""
    with open(path, "w", encoding="utf-8", newline="\n") as file:
        file.write(content)


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Without --hfs or $HFS the newest Houdini install on this machine is used.",
    )
    parser.add_argument(
        "--hfs",
        metavar="PATH",
        help="Houdini install root to parse (default: $HFS, else auto-detected)",
    )
    parser.add_argument(
        "--output-dir",
        metavar="DIR",
        default=DEFAULT_OUTPUT_DIR,
        help="where to write houdini_api.h/.cpp (default: %s)" % os.path.join("src", "hapi"),
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="don't write anything; exit 1 if the files on disk are out of date",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="list the Houdini installs found on this machine and exit",
    )
    parser.add_argument(
        "headers",
        nargs="*",
        metavar="HEADER",
        help="parse these HAPI headers instead of the ones from a Houdini install",
    )
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)

    if args.list:
        installs = find_houdini_installs()
        if not installs:
            print("No Houdini install found in:")
            for pattern in default_install_globs():
                print("  %s" % pattern)
            return 1
        print("Houdini installs found (newest first):")
        for version, hfs in installs:
            print("  %-10s %s" % (format_version(version), hfs))
        return 0

    if args.headers:
        header_paths = [os.path.abspath(os.path.expanduser(path)) for path in args.headers]
        missing = [path for path in header_paths if not os.path.isfile(path)]
        if missing:
            sys.exit("Error: header not found:\n  %s" % "\n  ".join(missing))
        source_label = "%d header(s) given on the command line" % len(header_paths)
    else:
        hfs, source = resolve_hfs(args.hfs)
        header_paths = [os.path.join(header_dir(hfs), name) for name in HAPI_HEADERS]
        source_label = "%s (Houdini %s, via %s)" % (hfs, format_version(read_houdini_version(hfs)), source)

    print("Parsing: %s" % source_label)
    entries = parse_headers(header_paths)
    if not entries:
        sys.exit("Error: no HAPI_DECL declarations found - are these really HAPI headers?")
    print("Found %d HAPI functions" % len(entries))

    outputs = (
        (os.path.join(args.output_dir, "houdini_api.h"), generate_header(entries)),
        (os.path.join(args.output_dir, "houdini_api.cpp"), generate_cpp(entries)),
    )

    if args.check:
        stale = [path for path, content in outputs if read_existing(path) != content]
        for path, _ in outputs:
            print("  %-12s %s" % ("OUT OF DATE" if path in stale else "up to date", path))
        if stale:
            print("\nRun this script without --check to regenerate.")
            return 1
        return 0

    if not os.path.isdir(args.output_dir):
        os.makedirs(args.output_dir)

    for path, content in outputs:
        unchanged = read_existing(path) == content
        write_generated(path, content)
        print("  %-9s %s" % ("unchanged" if unchanged else "written", path))

    return 0


if __name__ == "__main__":
    sys.exit(main())
