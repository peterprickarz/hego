#!/usr/bin/env python
import os
import sys
import platform

# ───────────────────────────────────────────────
# Determine Houdini root (HFS) with sensible defaults
# ───────────────────────────────────────────────
default_hfs = {
    "Windows": r"C:\Program Files\Side Effects Software\Houdini 21.0.631",
    "Linux":   "/opt/hfs21.0",                    # ← adjusted to match your actual path
    "Darwin":  "/Applications/Houdini/Houdini21.0.631/Houdini.framework/Versions/Current/Resources"
}

sys_name = platform.system()
HFS = os.environ.get("HFS", default_hfs.get(sys_name, ""))

if not HFS or not os.path.isdir(HFS):
    print("Error: HFS not found and no valid default for this OS.")
    print("Please set environment variable HFS to your Houdini installation folder.")
    print(f"Typical locations:\n  Windows → {default_hfs['Windows']}\n  Linux   → {default_hfs['Linux']}")
    sys.exit(1)

print(f"Using HFS = {HFS}")

HB = os.path.join(HFS, "bin")

# ───────────────────────────────────────────────
# Load godot-cpp environment
# ───────────────────────────────────────────────
env = SConscript("godot-cpp/SConstruct")
# Remove static C++ runtime flags (they break Houdini / USD)
env["LINKFLAGS"] = [f for f in env.get("LINKFLAGS", []) if f not in ["-static-libstdc++", "-static-libgcc"]]

# ───────────────────────────────────────────────
# Common Houdini-related environment variables
# ───────────────────────────────────────────────
houdini_vars = {
    "HFS": HFS,
    "HB":  HB,
    "H":   HFS,
    "HH":  os.path.join(HFS, "houdini"),
    "HHC": os.path.join(HFS, "houdini", "config"),
    "HHP": os.path.join(HFS, "houdini", "python3.11libs"),  # adjust python version if needed
    "HT":  os.path.join(HFS, "toolkit"),
    "HDSO": os.path.join(HFS, "dsolib"),
    "HSB": os.path.join(HFS, "houdini", "sbin"),
}

for k, v in houdini_vars.items():
    env["ENV"][k] = v

# ───────────────────────────────────────────────
# PATH handling – only PREPEND Houdini paths (safest for Linux)
# ───────────────────────────────────────────────
env.PrependENVPath('PATH', HB)                      # Houdini bin first

# Optional – sometimes helps find Houdini .so files earlier
# env.PrependENVPath('PATH', os.path.join(HFS, 'dsolib'))
# env.PrependENVPath('PATH', HFS)

# Debug: show what PATH looks like now
print("\nModified PATH (first 10 entries shown):")
path_entries = env["ENV"]["PATH"].split(os.pathsep)
for i, p in enumerate(path_entries[:10]):
    if p.strip():
        print(f"  {i+1:2d}. {p}")
if len(path_entries) > 10:
    print(f"  ... ({len(path_entries)-10} more entries)")

# ───────────────────────────────────────────────
# Platform-specific compiler / linker flags
# ───────────────────────────────────────────────
houdini_include = os.path.join(HFS, "toolkit", "include")
env.Append(CPPPATH=[houdini_include])

if env["platform"] == "windows":
    # Ensure Windows DLL names stay as hego.*.dll even when cross-compiling from Linux.
    env["SHLIBPREFIX"] = ""
    env["IMPLIBPREFIX"] = ""

    if env.get("use_mingw", False):
        # MinGW/GCC path (Linux cross-compile, or MinGW on Windows)
        # Usually no extra flags needed here.
        # Optional:
        # env.Append(CCFLAGS=["-std=c++17"])
        pass
    else:
        # MSVC path
        env.Append(CCFLAGS=["/std:c++17", "/EHsc"])

elif env["platform"] == "linux":
    env["CC"] = "gcc-11"
    env["CXX"] = "g++-11"
    env.Append(CCFLAGS=["-std=c++17", "-fPIC"])

    # Ensure dynamic linking of C++ runtime
    env["LINKFLAGS"] = [f for f in env.get("LINKFLAGS", []) if f not in ["-static-libstdc++", "-static-libgcc"]]

    env.Append(LINKFLAGS=[
        f"-Wl,-rpath,{os.path.join(HFS, 'dsolib')}",
        "-shared"
    ])

    env.Append(LIBS=["dl", "pthread"])
    env.Append(LIBPATH=[os.path.join(HFS, "dsolib")])

elif env["platform"] == "macos" or sys_name == "Darwin":
    env.Append(CCFLAGS=["-std=c++17"])
    env.Append(LINKFLAGS=["-Wl,-rpath,@loader_path/../Frameworks/Houdini.framework/Versions/Current/Resources/dsolib"])

# Build machine info (optional, but matches setup script)
if env["platform"] == "linux":
    env["ENV"]["HOUDINI_BUILD_PLATFORM"] = "Linux"
    env["ENV"]["HOUDINI_BUILD_COMPILER"] = "11.2.1"  # from your setup script
    env["ENV"]["HOUDINI_BUILD_LIBC"] = "glibc 2.28"



# ───────────────────────────────────────────────
# Source collection
# ───────────────────────────────────────────────
src_dir = "src"
build_dir = "build"

VariantDir(build_dir, src_dir, duplicate=0)

cpp_sources = (
    Glob(f"{build_dir}/*.cpp") +
    Glob(f"{build_dir}/hapi/*.cpp") +
    Glob(f"{build_dir}/hego_nodes/*.cpp") +
    Glob(f"{build_dir}/util/**/*.cpp") +
    Glob(f"{build_dir}/util/*.cpp")
)

# Include class reference docs in editor/debug builds so they are available from the extension binary.
if env["target"] in ["editor", "template_debug"]:
    doc_xml = Glob("demo/addons/hego/doc_classes/*.xml")
    if doc_xml:
        doc_data = env.GodotCPPDocData(f"{build_dir}/gen/doc_data.gen.cpp", source=doc_xml)
        cpp_sources.append(doc_data)

env.Append(CPPPATH=[src_dir])

# ───────────────────────────────────────────────
# Output library
# ───────────────────────────────────────────────
if env["platform"] == "macos":
    library = env.SharedLibrary(
        f"demo/addons/hego/bin/hego.{env['platform']}.{env['target']}.framework/hego.{env['platform']}.{env['target']}",
        source=cpp_sources,
    )
else:
    library = env.SharedLibrary(
        f"demo/addons/hego/bin/hego{env['suffix']}{env['SHLIBSUFFIX']}",
        source=cpp_sources,
    )

Default(library)