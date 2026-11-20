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
    assert d["discovery"] == ["velbus"]
    assert d["hassio_api"] is False and d["homeassistant_api"] is False
    assert d["ingress_entry"] == "velbus-ui/index.html", "Ingress entry must be relative to avoid doubled slashes"
    assert d["boot"] == "manual" and d["stage"] == "experimental"
    assert d["host_network"] is False and d["full_access"] is False
    assert d["usb"] is False and d["uart"] is False
    assert d["ports"] == {}
    assert d["schema"]["serial_devices"] == ["device(subsystem=tty)"]
runtime = (ROOT / "runtime" / "launch.sh").read_text()
dockerfile = (ROOT / "release" / "Dockerfile").read_text()
assert "chown -R app:app /data/velbus" in runtime
assert 'exec gosu app "$0" "$@"' in runtime
assert "trap shutdown_gracefully INT TERM" in runtime
assert "trap 'exit 143'" not in runtime
smoke = (ROOT / "scripts" / "smoke_runtime.sh").read_text()
assert 'docker stop --time 20 "$container"' in smoke
assert "stopped_code" in smoke and "final_code" in smoke
assert "dotnet /app/Velbus.Signum.Release.dll" in runtime
assert 'nginx -c "$nginx_config"' in runtime
assert 'id -u app' in runtime
assert '$http_referer' not in (ROOT / "runtime" / "nginx.conf").read_text()
assert 'log_format ha_private' in (ROOT / "runtime" / "nginx.conf").read_text()
assert "/dev/stderr" not in (ROOT / "runtime" / "nginx.conf").read_text()
assert "/dev/stdout" not in (ROOT / "runtime" / "nginx.conf").read_text()
assert "tail -n +1 -F /tmp/velbus-nginx-error.log" in runtime
assert "USER root" in dockerfile and "gosu" in dockerfile
assert "EXPOSE 8098 8099" in dockerfile
assert "jq" in dockerfile
assert "COPY runtime/discovery.sh" in dockerfile
nginx = (ROOT / "runtime" / "nginx.conf").read_text()
assert "listen 8098;" in nginx and "listen 8099;" in nginx
assert 'if ($http_authorization != "Bearer __VELBUS_API_BEARER__")' in nginx
assert 'proxy_set_header Authorization "";' in nginx
assert 'location / { return 404; }' in nginx
assert (ROOT / "runtime" / "discovery.sh").exists()
assert "http://supervisor/discovery" in (ROOT / "runtime" / "discovery.sh").read_text()
assert "register_supervisor_discovery" in runtime
assert "unregister_supervisor_discovery" in runtime
assert "http://127.0.0.1:8098/velbus/api/v2/ws" in smoke
smoke = (ROOT / "scripts" / "smoke_runtime.sh").read_text()
assert "/velbus/api/v2/gateways" in smoke
assert "/velbus/api/v2/ws" in smoke
assert 'ingress_entry: "velbus-ui/index.html"' in (ROOT / ".github/app-config.template.yaml").read_text()
assert 'discovery:\n  - velbus' in (ROOT / ".github/app-config.template.yaml").read_text()
print("PASS public catalog structure, source isolation and app metadata")
