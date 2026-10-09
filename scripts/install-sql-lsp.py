"""Install the pinned offline SQL tooling used by lua/config/sql.lua."""
import hashlib
import io
import os
import platform
import subprocess
import tarfile
import urllib.request
from pathlib import Path

VERSION = "0.1.3"
targets = {
    ("Darwin", "arm64"): "aarch64-apple-darwin",
    ("Darwin", "x86_64"): "x86_64-apple-darwin",
    ("Linux", "x86_64"): "x86_64-unknown-linux-gnu",
}
target = targets.get((platform.system(), platform.machine()))
if not target:
    raise SystemExit("No pinned SQL LSP binary for this platform")
data = Path(subprocess.check_output(
    ["nvim", "--headless", "-u", "NONE", "-i", "NONE", "-l", "-"],
    input=b"io.stdout:write(vim.fn.stdpath('data'))", timeout=15,
).decode()) / "sql-schema"
data.mkdir(parents=True, exist_ok=True)
base = f"https://github.com/RainLib/lsp_sqls/releases/download/v{VERSION}/sql-lsp-{target}-v{VERSION}"


def download(url):
    with urllib.request.urlopen(url, timeout=30) as response:
        return response.read()


checksum = download(base + ".sha256").decode().split()[0]
with tarfile.open(fileobj=io.BytesIO(download(base + ".tar.gz")), mode="r:gz") as archive:
    binary = archive.extractfile("sql-lsp").read()
if hashlib.sha256(binary).hexdigest() != checksum:
    raise SystemExit("SQL LSP checksum mismatch")
pending = data / "sql-lsp.new"
pending.write_bytes(binary)
pending.chmod(0o755)
os.replace(pending, data / "sql-lsp")
subprocess.run(["python3", "-m", "venv", str(data / "venv")], check=True, timeout=60)
subprocess.run([str(data / "venv/bin/python"), "-m", "pip", "install", "sqlglot==28.0.0"],
               check=True, timeout=120)
print(f"Installed sql-lsp {VERSION} and SQLGlot 28.0.0 in {data}")
