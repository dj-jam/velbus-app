"""Validate public multi-arch manifest: HA amd64 and aarch64."""
import json
from pathlib import Path
import sys
m = json.loads(Path(sys.argv[1]).read_text())
assert m.get("mediaType") in (
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
)
platforms = {((v.get("platform") or {}).get("os"), (v.get("platform") or {}).get("architecture")) for v in m["manifests"]}
assert ("linux", "amd64") in platforms and ("linux", "arm64") in platforms
print("PASS anonymous AMD64 and ARM64 image manifest")
