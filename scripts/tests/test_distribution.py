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
    addon=source/"demo/addons/hego"; addon.mkdir(parents=True)
    (addon/"plugin.cfg").write_text("plugin")
    (addon/".hidden").write_text("hidden")
    (source/"README.md").write_text("demo/addons/hego/assets/logo.png")
    (source/"LICENSE").write_text("license")
    git(source,"add","."); git(source,"commit","-m","initial")
    git(source,"remote","add","origin",remote)
    def publish(): return run(repo/"scripts/publish-next.sh",cwd=source)
    publish()
    first=git(remote,"rev-parse","release-next")
    assert git(remote,"show","release-next:.hidden")=="hidden"
    assert git(remote,"show","release-next:README.md")=="assets/logo.png"
    assert git(remote,"show","release-next:SOURCE_COMMIT")==git(source,"rev-parse","HEAD")
    publish(); assert git(remote,"rev-parse","release-next")==first
    (addon/".hidden").unlink(); (addon/"plugin.cfg").write_text("new plugin")
    git(source,"add","."); git(source,"commit","-m","update")
    # Publishing does not disturb local staged or unstaged edits.
    (source/"README.md").write_text("local")
    git(source,"add","README.md")
    before=git(source,"status","--porcelain")
    publish()
    assert before==git(source,"status","--porcelain")
    assert git(remote,"rev-parse","release-next^")==first
    assert ".hidden" not in git(remote,"ls-tree","--name-only","release-next")
    print("PASS publisher: initial root, dotfiles, provenance, repeat, deletion, parent history, untouched index")
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
    assert (addon/"plugin.cfg").read_text()=="live edit"
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
