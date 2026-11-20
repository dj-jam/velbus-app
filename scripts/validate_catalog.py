"""Fail closed on an invalid or source-leaking public Home Assistant catalog."""
from pathlib import Path
import re
import yaml

ROOT = Path(__file__).resolve().parents[1]
repo = yaml.safe_load((ROOT / "repository.yaml").read_text())
assert repo["name"] == "Velbus APP"
assert repo["url"] == "https://github.com/dj-jam/velbus-app"
assert (ROOT / "README.md").exists()
assert not any(ROOT.rglob("*.cs"))
assert not any(ROOT.rglob("*.pdb"))
assert not any(ROOT.rglob("*.dll"))
assert not (ROOT / "src").exists()
manifest = ROOT / "velbus_manager_2_beta" / "config.yaml"
if manifest.exists():
    d = yaml.safe_load(manifest.read_text())
    assert d["image"] == "ghcr.io/dj-jam/velbus-manager2-ha"
    assert re.fullmatch(r"0\.\d+\.\d+-beta\.\d+", d["version"])
    assert d["slug"] == "velbus_manager_2_beta"
    assert d["arch"] == ["amd64", "aarch64"]
    assert d["ingress"] and d["panel_admin"]
    assert d["boot"] == "manual" and d["stage"] == "experimental"
    assert d["host_network"] is False and d["full_access"] is False
    assert d["usb"] is False and d["uart"] is False
    assert d["ports"] == {}
    assert d["schema"]["serial_devices"] == ["device(subsystem=tty)"]
print("PASS public catalog structure, source isolation and app metadata")
