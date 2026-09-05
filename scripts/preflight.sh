#!/usr/bin/env bash
# Check the things that only fail once you have paid for an apply.
#
#   ./scripts/preflight.sh
#
# 1. bootstrap.sh parses.
# 2. No heredoc writes a line starting "#" at column zero. Terraform strips
#    those on the way into user_data (see locals.bootstrap_script in main.tf),
#    so such a line would vanish from the generated file with no warning.
# 3. The script still parses AFTER that stripping.
# 4. The rendered user_data fits EC2's 16,384-byte cap.
#
# Exits non-zero on any failure. No AWS calls, no terraform commands.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/scripts/bootstrap.sh"
template="${repo_root}/terraform/cloud-init.yaml.tftpl"
CAP=16384

fail=0
note() { printf '  %s\n' "$*"; }
ok()   { printf 'ok    %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; fail=1; }

# 1. Does the script parse as written?
if bash -n "$script" 2>/dev/null; then
    ok "bootstrap.sh parses"
else
    bad "bootstrap.sh does not parse"
    bash -n "$script" || true
fi

# 2 + 3 + 4. Everything that needs to understand heredocs.
python3 - "$script" "$template" "$CAP" <<'PY' || fail=1
import base64, gzip, io, pathlib, re, subprocess, sys, tempfile

script_path, template_path, cap = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3])
lines = script_path.read_text().split("\n")

# Track heredoc bodies so we can tell generated content from the script itself.
here_open = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
delimiter, inside = None, set()
for i, line in enumerate(lines):
    if delimiter is None:
        match = here_open.search(line)
        if match:
            delimiter = match.group(2)
    elif line.strip() == delimiter:
        delimiter = None
    else:
        inside.add(i)

failed = False
if delimiter is not None:
    print(f"FAIL  heredoc '{delimiter}' is never terminated")
    failed = True

# 2. A column-zero comment inside a heredoc would be stripped out of the file
#    the bootstrap writes, silently.
offenders = [i for i in sorted(inside) if lines[i].startswith("#")]
if offenders:
    print(f"FAIL  {len(offenders)} heredoc line(s) start '#' at column zero; Terraform")
    print("      strips those out of user_data. Indent them.")
    for i in offenders[:5]:
        print(f"        bootstrap.sh:{i + 1}: {lines[i][:70]}")
    failed = True
else:
    print(f"ok    no heredoc line starts '#' at column zero ({len(inside)} heredoc lines)")

# 3. The stripped script has to be valid bash too -- that is what actually runs.
stripped = "\n".join(
    line for line in lines if not line.startswith("#") or line.startswith("#!")
)
with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as tmp:
    tmp.write(stripped)
    tmp_path = tmp.name
result = subprocess.run(["bash", "-n", tmp_path], capture_output=True, text=True)
pathlib.Path(tmp_path).unlink()
if result.returncode == 0:
    print("ok    bootstrap.sh still parses with comments stripped")
else:
    print("FAIL  stripped bootstrap.sh does not parse")
    print(result.stderr.rstrip())
    failed = True

# 4. Size. Worst case of the compression levels Go might pick.
def encoded(text: str) -> str:
    worst = ""
    for level in (6, 9):
        buffer = io.BytesIO()
        with gzip.GzipFile(fileobj=buffer, mode="wb", compresslevel=level, mtime=0) as f:
            f.write(text.encode())
        candidate = base64.b64encode(buffer.getvalue()).decode()
        if len(candidate) > len(worst):
            worst = candidate
    return worst

values = {
    "tracecat_version": "0.42.0",
    "superadmin_email": "a-long-enough-address@example.com",
    "app_host": "tracecat.adversaryemulation.ai",
    "oidc_issuer": "", "oidc_client_id": "", "oidc_client_secret": "", "oidc_scopes": "",
    "builtin_idp": "y",
    "mcp_idp_image": "ghcr.io/dexidp/dex:v2.45.1",
    "enable_tls": "y",
    "acme_email": "a-long-enough-address@example.com",
    "bootstrap_gz_b64": encoded(stripped),
}
rendered = re.sub(
    r"\$\{(\w+)\}",
    lambda m: values.get(m.group(1), m.group(0)),
    template_path.read_text(),
)
size = len(rendered.encode())
pct = size / cap * 100
if size <= cap:
    print(f"ok    user_data {size:,} of {cap:,} bytes ({pct:.1f}%), {cap - size:,} to spare")
    if pct > 90:
        print("      note: over 90% -- trim before adding to the bootstrap")
else:
    print(f"FAIL  user_data {size:,} exceeds the {cap:,}-byte cap by {size - cap:,}")
    failed = True

sys.exit(1 if failed else 0)
PY

if [[ $fail -ne 0 ]]; then
    printf '\npreflight failed\n'
    exit 1
fi
printf '\npreflight passed\n'
