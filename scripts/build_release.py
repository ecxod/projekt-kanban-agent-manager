#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VERSION_FILE = ROOT / "VERSION"
DIST = ROOT / "dist"


def read_version() -> str:
    version = VERSION_FILE.read_text(encoding="ascii").strip()
    parts = version.split(".")
    if len(parts) != 4 or not all(part.isdigit() for part in parts):
        raise SystemExit(f"Invalid VERSION file: {version!r}")
    return version


def add_file(archive: zipfile.ZipFile, source: Path, name: str) -> None:
    info = zipfile.ZipInfo(name)
    info.date_time = (2026, 9, 8, 0, 0, 0)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = (0o100644 & 0xFFFF) << 16
    archive.writestr(info, source.read_bytes())


def main() -> None:
    version = read_version()
    package = DIST / f"projekt-kanban-agent-manager-{version}-windows-wsl.zip"
    relay = ROOT / "native-host-windows-wsl" / "projekt-kanban-agent-wsl.exe"
    files = {
        "VERSION": VERSION_FILE,
        "README.md": ROOT / "README.md",
        "start-agent-manager.cmd": ROOT / "start-agent-manager.cmd",
        "native-host/kanban_agent_host.py": ROOT / "native-host" / "kanban_agent_host.py",
        "native-host/feedback-schema.json": ROOT / "native-host" / "feedback-schema.json",
        "native-host/agent-manager.sh": ROOT / "native-host" / "agent-manager.sh",
        "native-host/install-linux.sh": ROOT / "native-host" / "install-linux.sh",
        "native-host/uninstall-linux.sh": ROOT / "native-host" / "uninstall-linux.sh",
        "native-host-windows-wsl/agent-manager.ps1": ROOT / "native-host-windows-wsl" / "agent-manager.ps1",
        "native-host-windows-wsl/install.ps1": ROOT / "native-host-windows-wsl" / "install.ps1",
        "native-host-windows-wsl/start-agent-manager.cmd": ROOT / "native-host-windows-wsl" / "start-agent-manager.cmd",
        "native-host-windows-wsl/uninstall.ps1": ROOT / "native-host-windows-wsl" / "uninstall.ps1",
        "native-host-windows-wsl/wsl-relay.c": ROOT / "native-host-windows-wsl" / "wsl-relay.c",
        "native-host-windows-wsl/projekt-kanban-agent-wsl.exe": relay,
    }
    missing = [name for name, path in files.items() if not path.is_file()]
    if missing:
        raise SystemExit("Missing release files: " + ", ".join(missing))

    DIST.mkdir(exist_ok=True)
    with zipfile.ZipFile(package, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, source in sorted(files.items()):
            add_file(archive, source, name)

    digest = hashlib.sha256(package.read_bytes()).hexdigest()
    (DIST / "SHA256SUMS").write_text(f"{digest}  {package.name}\n", encoding="ascii")
    print(package.relative_to(ROOT))
    print((DIST / "SHA256SUMS").relative_to(ROOT))


if __name__ == "__main__":
    main()
