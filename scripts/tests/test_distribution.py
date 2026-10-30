"""Local integration checks: python3 scripts/tests/test_distribution.py."""
from pathlib import Path
import subprocess as sp
import tempfile
import os
repo=Path(__file__).resolve().parents[2]
env=os.environ | dict(GIT_AUTHOR_NAME="Test",GIT_AUTHOR_EMAIL="test@example.org",GIT_COMMITTER_NAME="Test",GIT_COMMITTER_EMAIL="test@example.org")
def run(*cmd,cwd=None,ok=True):
    p=sp.run(list(map(str,cmd)),cwd=cwd,env=env,text=True,capture_output=True)
    if ok and p.returncode: raise RuntimeError(f"{cmd}: {p.stderr} {p.stdout}")
    if not ok and not p.returncode: raise RuntimeError(f"Expected rejection: {cmd}")
    return p.stdout.strip()
def git(cwd,*args): return run("git",*args,cwd=cwd)
with tempfile.TemporaryDirectory(prefix="hego-distribution-") as d:
    base=Path(d)
    remote=base/"remote.git"; source=base/"source"; project=base/"consumer"/"game"
    run("git","init","--bare",remote)
    run("git","init",source)
    godot_cpp_source=base/"godot-cpp-source"; godot_cpp_remote=base/"godot-cpp.git"
    run("git","init",godot_cpp_source)
    (godot_cpp_source/"README.md").write_text("test godot-cpp revision")
    git(godot_cpp_source,"add","."); git(godot_cpp_source,"commit","-m","godot-cpp fixture")
    run("git","init","--bare",godot_cpp_remote)
    git(godot_cpp_source,"remote","add","origin",godot_cpp_remote)
    git(godot_cpp_source,"push","origin","HEAD")
    run("git","-c","protocol.file.allow=always","submodule","add",godot_cpp_remote,"godot-cpp",cwd=source)
    hego=source/"demo/addons/hego"; hego.mkdir(parents=True)
    terrain=source/"demo/addons/strata"; terrain.mkdir(parents=True)
    bridge=source/"demo/addons/hego_strata"; bridge.mkdir(parents=True)
    (bridge/"plugin.cfg").write_text("bridge plugin")
    for addon, extension, libs in (
        (hego, "hego", ("libhego.linux.template_debug.x86_64.so", "libhego.linux.template_release.x86_64.so")),
        (terrain, "strata", ("libstrata.linux.template_debug.x86_64.so", "libstrata.linux.template_release.x86_64.so")),
    ):
        binary_dir=addon/"bin"; binary_dir.mkdir()
        (addon/"plugin.cfg").write_text("plugin")
        (binary_dir/f"{extension}.gdextension").write_text("[libraries]\n" + "\n".join(
            f'linux.{"debug" if "debug" in lib else "release"}.x86_64 = "res://addons/{"hego" if extension == "hego" else "strata"}/bin/{lib}"'
            for lib in libs
        ) + "\n")
        for lib in libs:
            (binary_dir/lib).write_bytes(f"fresh-{extension}-{lib}".encode())
    (source/"SConstruct").write_text("hego build settings")
    (source/"SConstruct.terrain").write_text("terrain build settings")
    (source/"src").mkdir(); (source/"src/native.cpp").write_text("native")
    (source/"terrain/src").mkdir(parents=True); (source/"terrain/src/native.cpp").write_text("terrain native")
    scripts=source/"scripts"; scripts.mkdir()
    for name in ("build.sh", "build-terrain.sh"):
        (scripts/name).write_text(name)
    (scripts/"native_build_manifest.py").write_bytes((repo/"scripts/native_build_manifest.py").read_bytes())
    (source/"README.md").write_text("demo/addons/hego/assets/logo.png")
    (source/"LICENSE").write_text("license")
    for addon_name, libs in (
        ("hego", ("libhego.linux.template_debug.x86_64.so", "libhego.linux.template_release.x86_64.so")),
        ("strata", ("libstrata.linux.template_debug.x86_64.so", "libstrata.linux.template_release.x86_64.so")),
    ):
        args=["python3", scripts/"native_build_manifest.py", "record", "--addon", addon_name]
        for lib in libs:
            target="template_debug" if "debug" in lib else "template_release"
            args += ["--artifact", f"bin/{lib}", "--context", f"platform=linux,target={target},test=temporary-fixture"]
        run(*args)
    dirty_cpp=source/"godot-cpp/dirty.cpp"; dirty_cpp.write_text("uncommitted submodule source")
    run("python3",scripts/"native_build_manifest.py","record","--addon","hego","--artifact","bin/libhego.linux.template_debug.x86_64.so","--context","dirty-probe",cwd=source,ok=False)
    dirty_cpp.unlink()
    (source/"src/new_after_receipt.cpp").write_text("added after first native receipt")
    refresh=["python3",scripts/"native_build_manifest.py","record","--addon","hego"]
    for lib in ("libhego.linux.template_debug.x86_64.so", "libhego.linux.template_release.x86_64.so"):
        target="template_debug" if "debug" in lib else "template_release"
        refresh += ["--artifact",f"bin/{lib}","--context",f"platform=linux,target={target},test=refresh"]
    run(*refresh)
    (hego/".hidden").write_text("hidden")
    git(source,"add","."); git(source,"commit","-m","initial")
    run("python3",scripts/"native_build_manifest.py","validate","--addon","hego","--ref","HEAD",cwd=source)
    original_head=git(source,"rev-parse","HEAD")
    (source/"src/native.cpp").write_text("native changed after build")
    git(source,"add","src/native.cpp"); git(source,"commit","-m","stale native source")
    run(repo/"scripts/publish-next.sh","origin","HEAD","--dry-run",cwd=source,ok=False)
    run("python3",scripts/"native_build_manifest.py","validate","--addon","strata","--ref","HEAD",cwd=source)
    (source/"src/native.cpp").write_text("native")
    git(source,"add","src/native.cpp"); git(source,"commit","--amend","--no-edit","--allow-empty")
    assert git(source,"rev-parse","HEAD^{tree}")==git(source,"rev-parse",f"{original_head}^{{tree}}")
    binary=hego/"bin/libhego.linux.template_debug.x86_64.so"
    good_binary=binary.read_bytes()
    binary.write_bytes(b"replaced by stale native binary")
    git(source,"add",binary.relative_to(source)); git(source,"commit","-m","stale binary")
    run(repo/"scripts/publish-next.sh","origin","HEAD","--dry-run",cwd=source,ok=False)
    binary.write_bytes(good_binary)
    git(source,"add",binary.relative_to(source)); git(source,"commit","--amend","--no-edit","--allow-empty")
    assert git(source,"rev-parse","HEAD^{tree}")==git(source,"rev-parse",f"{original_head}^{{tree}}")
    git(source,"remote","add","origin",remote)
    def publish(mode=None):
        args=[repo/"scripts/publish-next.sh", "origin", "HEAD"]
        if mode: args.append(mode)
        return run(*args,cwd=source)
    dry=publish("--dry-run")
    assert "DRY RUN release-next" in dry and "DRY RUN strata-release-next" in dry and "DRY RUN hego-strata-release-next" in dry and "DRY RUN release-next-bundle" in dry
    assert not git(remote,"branch","--list")
    publish()
    first=git(remote,"rev-parse","release-next")
    assert git(remote,"show","release-next:.hidden")=="hidden"
    assert "no package dependencies" in git(remote,"show","release-next:README.md")
    assert git(remote,"show","release-next:SOURCE_COMMIT")==git(source,"rev-parse","HEAD")
    # Dependencies point one way: HEGo and Terrain stand alone, the bridge requires both.
    hego_package=__import__("json").loads(git(remote,"show","release-next:PACKAGE.json"))
    assert hego_package["requires"]==[]
    terrain_package=__import__("json").loads(git(remote,"show","strata-release-next:PACKAGE.json"))
    assert terrain_package["requires"]==[] and terrain_package["requires_hego"] is False
    bridge_package=__import__("json").loads(git(remote,"show","hego-strata-release-next:PACKAGE.json"))
    assert [(item["package"], item["branch"]) for item in bridge_package["requires"]]==[("hego","release-next"),("strata","strata-release-next")]
    assert all(item["source_commit"]==bridge_package["source_commit"]==hego_package["source_commit"] for item in bridge_package["requires"])
    assert git(remote,"show","hego-strata-release-next:plugin.cfg")=="bridge plugin"
    assert "`addons/hego`" in git(remote,"show","hego-strata-release-next:README.md") and "`addons/strata`" in git(remote,"show","hego-strata-release-next:README.md")
    for branch, root in (("release-next", ""), ("strata-release-next", ""), ("release-next-bundle", "hego/"), ("release-next-bundle", "strata/")):
        receipt=__import__("json").loads(git(remote,"show",f"{branch}:{root}native-build.json"))
        assert receipt["format_version"]==1 and receipt["source_fingerprint"]
        assert all("sha256" in item and "build_context" in item for item in receipt["artifacts"].values())
        addon_prefix="libhego." if root=="hego/" or branch=="release-next" else "libstrata."
        debug_context=receipt["artifacts"][f"bin/{addon_prefix}linux.template_debug.x86_64.so"]["build_context"]
        release_context=receipt["artifacts"][f"bin/{addon_prefix}linux.template_release.x86_64.so"]["build_context"]
        assert "target=template_debug" in debug_context and "target=template_release" in release_context
    assert git(remote,"show","release-next-bundle:hego/bin/hego.gdextension").startswith("[libraries]")
    assert git(remote,"show","release-next-bundle:strata/bin/strata.gdextension").startswith("[libraries]")
    assert git(remote,"show","release-next-bundle:hego_strata/plugin.cfg")=="bridge plugin"
    assert git(remote,"show","release-next-bundle:hego/bin/libhego.linux.template_debug.x86_64.so")=="fresh-hego-libhego.linux.template_debug.x86_64.so"
    assert git(remote,"show","release-next-bundle:strata/bin/libstrata.linux.template_debug.x86_64.so")=="fresh-strata-libstrata.linux.template_debug.x86_64.so"
    publish(); assert git(remote,"rev-parse","release-next")==first
    (hego/".hidden").unlink(); (hego/"plugin.cfg").write_text("new plugin")
    git(source,"add","."); git(source,"commit","-m","update")
    # Publishing does not disturb local staged or unstaged edits.
    (source/"README.md").write_text("local")
    git(source,"add","README.md")
    before=git(source,"status","--porcelain")
    publish()
    assert before==git(source,"status","--porcelain")
    assert git(remote,"rev-parse","release-next^")==first
    assert ".hidden" not in git(remote,"ls-tree","--name-only","release-next")
    print("PASS publisher: dry-run, one-way dependency manifests, standalone HEGo and Strata, bridge package, bundled consumer layout, receipts, history, untouched index")
    project.mkdir(parents=True); (project/"project.godot").touch()
    git(project.parent,"init")
    git(project.parent,"-c","protocol.file.allow=always","submodule","add","-b","release-next",str(remote),"game/addons/hego")
    git(project.parent,"add","."); git(project.parent,"commit","-m","pin")
    installed=project/"addons/hego"
    original=git(installed,"rev-parse","HEAD")
    def switch(mode,ok=True):
        args=["python3",repo/"scripts/hego-dev.py",mode,project]
        if mode=="enable": args+=["--checkout",source]
        return run(*args,ok=ok)
    (installed/"dirty").touch()
    switch("enable",False); assert not installed.is_symlink()
    (installed/"dirty").unlink()
    # Ignored files must survive both switches.
    exclude=Path(git(installed,"rev-parse","--absolute-git-dir"))/"info/exclude"
    exclude.parent.mkdir(exist_ok=True); exclude.write_text("cached\n")
    (installed/"cached").write_text("keep")
    switch("enable"); assert installed.is_symlink()
    switch("enable",False); switch("status")
    (installed/"plugin.cfg").write_text("live edit")
    assert (hego/"plugin.cfg").read_text()=="live edit"
    switch("disable"); assert not installed.is_symlink()
    assert git(installed,"rev-parse","HEAD")==original
    assert (installed/"cached").read_text()=="keep"
    assert not git(project.parent,"status","--porcelain")
    switch("disable",False)
    # A modified pin must not silently restore a different dependency.
    switch("enable")
    git(project.parent,"update-index","--cacheinfo",f"160000,{first},game/addons/hego")
    switch("disable",False); assert installed.is_symlink()
    git(project.parent,"update-index","--cacheinfo",f"160000,{original},game/addons/hego")
    switch("disable")
    print("PASS switch: dirty rejection, live edits, double-switch guards, pin-change rejection, exact restore, ignored files preserved")
