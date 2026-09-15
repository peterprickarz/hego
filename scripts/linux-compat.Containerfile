# Build environment for the redistributable Linux binaries.
#
# RHEL 8 is glibc 2.28, the same floor the official Godot binaries target, so a
# binary built here loads on anything Godot itself loads on. gcc-toolset supplies a
# compiler new enough for godot-cpp's C++17 without dragging the newer glibc along,
# and the C++ runtime is linked statically so no GLIBCXX version is required either.
#
# Built and driven by scripts/build.sh; see "linux-compat" there.
FROM docker.io/library/almalinux:8

RUN dnf -y install gcc-toolset-13 python3.11 python3.11-pip \
    && dnf clean all \
    && python3.11 -m pip install --no-cache-dir "scons>=4.5"

ENV PATH=/opt/rh/gcc-toolset-13/root/usr/bin:/usr/local/bin:/usr/bin:/bin \
    LD_LIBRARY_PATH=/opt/rh/gcc-toolset-13/root/usr/lib64
