#!/usr/bin/env python
import os
import sys

HFS = 'C:/Program Files/Side Effects Software/Houdini 20.5.487'
HB = f'{HFS}/bin'

# Define environment variables
env = SConscript("godot-cpp/SConstruct")
env['ENV']['HFS'] = HFS
env['ENV']['HB'] = HB
env['ENV']['H'] = HFS
env['ENV']['HH'] = f'{HFS}/houdini'
env['ENV']['HHC'] = f'{HFS}/houdini/config'
env['ENV']['HHP'] = f'{HFS}/houdini/python3.11libs'
env['ENV']['HT'] = f'{HFS}/toolkit'

# Print original PATH for debugging purposes in a readable format
original_path = env['ENV']['PATH'].split(';')
print("Original PATH:")
for p in original_path:
    print(f"  {p}")

# Append HB to PATH instead of overriding
env.PrependENVPath('PATH', f'{HB}')
env.PrependENVPath('PATH', f'{os.environ["PATH"]}')
env.PrependENVPath('PATH', f'{HFS}')

# Print modified PATH for debugging purposes in a readable format
modified_path = env['ENV']['PATH'].split(';')
print("\nModified PATH:")
for p in modified_path:
    print(f"  {p}")

# Houdini version information
env['ENV']['HOUDINI_MAJOR_RELEASE'] = '20'
env['ENV']['HOUDINI_MINOR_RELEASE'] = '5'
env['ENV']['HOUDINI_BUILD_VERSION'] = '487'
env['ENV']['HOUDINI_VERSION'] = f'{env["ENV"]["HOUDINI_MAJOR_RELEASE"]}.{env["ENV"]["HOUDINI_MINOR_RELEASE"]}.{env["ENV"]["HOUDINI_BUILD_VERSION"]}'

# Build machine information
env['ENV']['HOUDINI_BUILD_KERNEL'] = '10.0.19045'
env['ENV']['HOUDINI_BUILD_PLATFORM'] = 'Windows'
env['ENV']['HOUDINI_BUILD_COMPILER'] = '19.35.32217.1'


# For reference:
# - CCFLAGS are compilation flags shared between C and C++
# - CFLAGS are for C-specific compilation flags
# - CXXFLAGS are for C++-specific compilation flags
# - CPPFLAGS are for pre-processor flags
# - CPPDEFINES are for pre-processor defines
# - LINKFLAGS are for linking flags

# tweak this if you want to use different folders, or more folders, to store your source code in.
"""
if 'HFS' not in os.environ:
    raise EnvironmentError("The HFS environment variable must be set to your Houdini installation directory to build the HoudiniEngineSample.")
"""

# Platform-specific settings
if env['PLATFORM'] == 'posix':
    if env['HOST_OS'] == 'linux':
        houdini_hapi_headers = os.path.join(os.environ['HFS'], 'toolkit/include')
        env.Append(RPATH=[os.path.join(os.environ['HFS'], 'dsolib')])
        env.Append(LIBS=['dl'])

    elif env['HOST_OS'] == 'darwin':
        houdini_hapi_headers = os.path.join(os.environ['HFS'], 'toolkit/include')
        env.Append(CCFLAGS=['-std=c++17'])
        env.Append(RPATH=[os.path.join(os.environ['HFS'], '../Libraries')])

else:
    houdini_hapi_headers = os.path.join(env['ENV']['HFS'], 'toolkit/include')
    env.Append(CCFLAGS=['/std:c++17'])

env.Append(CPPPATH=[houdini_hapi_headers])

# Define the source and build directories
src_dir = "src"
build_dir = "build"

# Use VariantDir to map the source directory to the build directory
VariantDir(build_dir, src_dir, duplicate=0)

# Collect the source files from the build directory
sources = Glob(f"{build_dir}/*.cpp")
sources.append(Glob(f"{build_dir}/hapi/*.cpp", strings=True))
sources.append(Glob(f"{build_dir}/hego_nodes/*.cpp", strings=True))
sources.append(Glob(f"{build_dir}/util/**/*.cpp", strings=True))
sources.append(Glob(f"{build_dir}/util/*.cpp", strings=True))

# Append the source directory to the include path
env.Append(CPPPATH=[src_dir])

if env["platform"] == "macos":
    library = env.SharedLibrary(
        "demo/bin/hego.{}.{}.framework/hego.{}.{}".format(
            env["platform"], env["target"], env["platform"], env["target"]
        ),
        source=sources,
    )
else:
    library = env.SharedLibrary(
        "demo/bin/hego{}{}".format(env["suffix"], env["SHLIBSUFFIX"]),
        source=sources,
    )

Default(library)