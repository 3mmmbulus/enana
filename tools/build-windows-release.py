"""Build a Windows ZIP from the same reviewed, state-free release stage."""
import hashlib
import json
import pathlib
import subprocess
import sys
import zipfile
from datetime import datetime, timezone

out, stage = map(pathlib.Path, sys.argv[1:])
repo = pathlib.Path(__file__).resolve().parent.parent
# Only a committed tree may be published (N1): the package must be exactly the reviewed commit.
if subprocess.run(["git", "-C", str(repo), "status", "--porcelain", "--untracked-files=no"],
                  capture_output=True, text=True, check=True).stdout.strip():
    raise SystemExit("Refusing to build: uncommitted changes in tracked files. Commit them first.")
commit = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"],
                        capture_output=True, text=True, check=True).stdout.strip()
version = (stage / "VERSION").read_text().strip()
archive = out / f"enana-{version}-windows.zip"
with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for file in sorted(stage.rglob("*")):
        if file.is_symlink():
            raise RuntimeError(f"Release must not contain symlinks: {file}")
        if file.is_file():
            z.write(file, f"{stage.name}/{file.relative_to(stage).as_posix()}")
manifest = dict(platform="windows", channel="preview", version=version,
                sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                size=archive.stat().st_size, url=f"/dl/{archive.name}",
                # seq: monotonically increasing release sequence (build time); expires: 30 days. Both are signed.
                seq=int(datetime.now(timezone.utc).timestamp()), expires=int(datetime.now(timezone.utc).timestamp()) + 30 * 86400,
                commit=commit, released=datetime.now(timezone.utc).isoformat())
(out / "windows-manifest.json").write_text(json.dumps(manifest, separators=(",", ":")) + "\n")
(out / "get.ps1").write_bytes((stage / "get.ps1").read_bytes())
(out / "windows-CHANGELOG.md").write_bytes((stage / "CHANGELOG.md").read_bytes())
print(f"Built {archive.name}, SHA-256 {manifest['sha256']}")
