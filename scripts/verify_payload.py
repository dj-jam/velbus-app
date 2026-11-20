"""Verify that uploaded archive is runtime-only and safe to unpack."""
import argparse
from pathlib import PurePosixPath
import tarfile

p = argparse.ArgumentParser()
p.add_argument("archive")
a = p.parse_args()
with tarfile.open(a.archive, "r:gz") as tar:
    names = set()
    size = 0
    for entry in tar:
        path = PurePosixPath(entry.name)
        assert not path.is_absolute() and ".." not in path.parts
        assert entry.isfile() or entry.isdir(), entry.name
        if entry.isdir():
            continue
        size += entry.size
        assert size <= 600 * 1024 * 1024
        normalized = str(path).removeprefix("./")
        assert normalized not in names
        names.add(normalized)
        assert not any(normalized.endswith(e) for e in (".cs", ".ts", ".pdb", ".env", ".map", ".sln", ".csproj"))
        assert not any(part in (".git", ".ssh", "secret", "src", "node_modules") for part in path.parts)
    assert "Velbus.Signum.Release.dll" in names
    assert "wwwroot/velbus-ui/index.html" in names
    assert any(name.endswith(".deps.json") for name in names)
print(f"PASS compiled-only archive: {len(names)} files, {size} bytes")
