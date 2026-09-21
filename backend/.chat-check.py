#!/usr/bin/env python3
import json, os, re, subprocess
from pathlib import Path

ROOT = Path("/Users/mrack/Downloads/sub2api-ranxi")
DATA = ROOT / "deploy/data/config.yaml"
LOG = ROOT / "deploy/data/backend.launchd.log"
OUT = ROOT / "backend/.chat-check.out"
PSQL = "/opt/homebrew/opt/postgresql@16/bin/psql"
PREFIX = "codex_turn_ticket:"

def yaml_db():
    vals, section = {}, None
    for line in DATA.read_text().splitlines():
        if line.endswith(":") and not line.startswith(" "):
            section = line[:-1]; continue
        if section != "database" or ":" not in line:
            continue
        k, v = line.strip().split(":", 1)
        vals[k.strip()] = v.strip().strip('"')
    return vals

db = yaml_db()
env = os.environ.copy()
env["PGPASSWORD"] = db.get("password", "")
env["PGHOST"] = db.get("host", "127.0.0.1")
env["PGPORT"] = db.get("port", "5432")
env["PGUSER"] = db.get("user", "sub2api")
env["PGDATABASE"] = db.get("dbname", "sub2api")

sql = """
SELECT id, name, extra->>'codex_skip_harvest', extra::text
FROM accounts WHERE id IN (2,3) ORDER BY id;
"""
proc = subprocess.run([PSQL, "-At", "-F", "\t", "-c", sql], env=env, capture_output=True, text=True, timeout=15)
rows = []
if proc.returncode != 0:
    rows = [{"error": (proc.stderr or "")[:200].replace(db.get("password",""), "***")}]
else:
    for line in proc.stdout.splitlines():
        if not line.strip():
            continue
        acc_id, name, skip, extra_text = line.split("\t", 3)
        extra = json.loads(extra_text)
        tickets = []
        for k, v in extra.items():
            if not str(k).startswith(PREFIX) or not isinstance(v, dict):
                continue
            if not v.get("model"):
                continue
            state = v.get("state") or ""
            tickets.append({
                "model": v.get("model"),
                "length": v.get("length") or len(state),
                "revoked": bool(v.get("revoked")),
                "captured_at": v.get("captured_at"),
                "expires_at": v.get("expires_at"),
                "has_session": bool(v.get("harvest_session_id")),
                "node": v.get("harvest_node_name") or "",
                "has_standby": bool(v.get("standby")),
            })
        rows.append({"id": int(acc_id), "name": name, "skip_harvest": skip, "tickets": tickets})

events = []
if LOG.exists():
    data = LOG.read_text(errors="replace").splitlines()[-400:]
    for line in data:
        if any(s in line for s in ("manual-harvest", "harvester", "probe_miss", "response_mismatch", "ticket_reject", "/v1/responses", "codex_ticket")):
            s = re.sub(r"gAAAAA[A-Za-z0-9_\-]{8,}", "STATE", line)
            s = re.sub(r"Bearer [A-Za-z0-9._\-]+", "Bearer TOKEN", s)
            s = re.sub(r"eyJ[A-Za-z0-9._\-]{20,}", "JWT", s)
            events.append(s[:360])

OUT.write_text(json.dumps({"accounts": rows, "log_tail": events[-25:]}, ensure_ascii=False, indent=2) + "\n")
print("wrote")