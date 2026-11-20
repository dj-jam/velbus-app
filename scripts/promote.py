"""Create/update public HA app manifest after verified image publication."""
from pathlib import Path
import re
import sys

assert len(sys.argv) == 2
version = sys.argv[1]
assert re.fullmatch(r"0\.\d+\.\d+-beta\.\d+", version), version
root = Path(__file__).resolve().parents[1]
app = root / "velbus_manager_2_beta"
manifest = app / "config.yaml"
if manifest.exists():
    original = manifest.read_text()
    found = re.search(r'^version: "(.*?)"$', original, re.M)
    assert found, "Unrecognized version format"
    previous = found.group(1)
    if previous == version:
        print("Already current: " + version)
        sys.exit(0)
    def v_parts(v):
        m = re.fullmatch(r"0\.(\d+)\.(\d+)-beta\.(\d+)", v)
        assert m
        return tuple(map(int, m.groups()))
    assert v_parts(version) > v_parts(previous), "Refusing release downgrade"
    new = original.replace('version: "' + previous + '"', 'version: "' + version + '"', 1)
else:
    template = (root / ".github" / "app-config.template.yaml").read_text()
    new = template.replace("__VERSION__", version)
assert 'version: "' + version + '"' in new
manifest.write_text(new)
changelog = app / "CHANGELOG.md"
old = changelog.read_text()
changelog.write_text(f"# Changelog\n\n## {version}\n\n- Approved compiled Manager beta image for Home Assistant Apps.\n- Ingress-only admin UI; no published host port.\n- USB device selection limited to explicitly mapped serial devices.\n\n" + old.removeprefix("# Changelog\n").lstrip())
print("Prepared HA app catalogue release", version)
