# Redistributable Strata build environment. AlmaLinux 8 provides glibc 2.28,
# matching the floor used by official Godot Linux binaries. This image contains no
# Houdini SDK, HAPI libraries, or HEGo build dependencies.
FROM docker.io/library/almalinux:8

RUN dnf -y install gcc-toolset-13 python3.11 python3.11-pip \
    && dnf clean all \
    && python3.11 -m pip install --no-cache-dir "scons>=4.5"

ENV PATH=/opt/rh/gcc-toolset-13/root/usr/bin:/usr/local/bin:/usr/bin:/bin \
    LD_LIBRARY_PATH=/opt/rh/gcc-toolset-13/root/usr/lib64 \
    PYTHONPATH=/src/godot-cpp:/src/godot-cpp/tools
