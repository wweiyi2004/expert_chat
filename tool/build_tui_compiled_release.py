"""Build a fresh TUI+GUI release with compilation only, per user preference.

Does not run tests, scan live providers, or overwrite an existing release.
"""
import datetime
import json
import shutil
import zipfile
from pathlib import Path
import build_tui_release as base

ROOT=base.ROOT
OUT=ROOT/'output/tui-refine/build'
OUT.mkdir(parents=True,exist_ok=True)
base.OUT=OUT

def main():
    manifest=base.snapshot()
    rel='tool/build_tui_compiled_release.py'
    manifest[rel]={'sha256':base.digest(ROOT/rel),'bytes':(ROOT/rel).stat().st_size}
    base.write('sources.json',manifest)
    base.write('build-mode.json',{'mode':'compile-only','tests_run':False,'source_sha256':base.digest(OUT/'sources.json')})
    assert base.STAGE.resolve()==Path('E:/wweiyi/tmp/expert-chat-ui-redesign-build-20261025-022630').resolve()
    previous_file=OUT/'staged-sources.json'
    if not previous_file.exists():previous_file=ROOT/'output/tui-build/staged-sources.json'
    previous=json.loads(previous_file.read_text(encoding='utf-8')) if previous_file.exists() else {}
    for stale in set(previous)-set(manifest):
        target=(base.STAGE/stale).resolve()
        assert target.is_relative_to(base.STAGE.resolve())
        if target.is_file():target.unlink()
    for rel,info in manifest.items():
        target=base.STAGE/rel
        assert target.resolve().is_relative_to(base.STAGE.resolve())
        if target.is_file() and base.digest(target)==info['sha256']:continue
        target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(ROOT/rel,target)
    base.write('staged-sources.json',manifest)
    base.run('windows-pub',base.FLUTTER+['pub','get','--offline','--enforce-lockfile'],base.STAGE)
    base.run('windows-build',base.FLUTTER+['build','windows','--release','--target','lib/main.dart'],base.STAGE)
    base.run('tui-release-build',['cargo','build','--manifest-path','next/Cargo.toml','--release','--locked','-p','expert-tui'])
    for rel,info in manifest.items():
        assert base.digest(ROOT/rel)==info['sha256'],f'Source changed during compilation: {rel}'
    release=ROOT/'output/releases'/('tui-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    assert not release.exists()
    package=release/'ExpertChat-TUI'
    shutil.copytree(base.STAGE/'build/windows/x64/runner/Release',package)
    shutil.copy2(ROOT/'next/target/release/expert-tui.exe',package/'expert-tui.exe')
    for name in ['expert.cmd','expert.ps1']:shutil.copy2(ROOT/'scripts'/name,package/name)
    archive=release/'ExpertChat-TUI-windows.zip'
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for file in sorted(package.rglob('*')):
            if file.is_file():z.write(file,file.relative_to(release))
    result={'directory':str(release),'package':str(package),'gui':str(package/'expert_chat.exe'),
            'tui':str(package/'expert-tui.exe'),'zip':str(archive),'zip_sha256':base.digest(archive),
            'sources_sha256':base.digest(OUT/'sources.json'),'mode':'compile-only','tests_run':False}
    base.write('release.json',result)
    (release/'release-manifest.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    shutil.copy2(OUT/'sources.json',release/'source-manifest.json')
    print(json.dumps(result,indent=2),flush=True)

if __name__=='__main__':main()
