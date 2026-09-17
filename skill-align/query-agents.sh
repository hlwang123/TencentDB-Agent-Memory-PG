#!/bin/bash
# query-agents.sh — 列出 PG public 表，并抽样 agent/entity/asset 相关表
set -uo pipefail
: "${PG_CONNECTION_STRING:?export PG_CONNECTION_STRING=postgres://user:pass@host:5432/tdai_memory}"
TMPQ=$(mktemp /tmp/q-XXXX.js)
cat > "$TMPQ" <<EOF
const { Pool } = require("pg");
(async () => {
  const pool = new Pool({ connectionString: process.argv[1] });
  const t = await pool.query("SELECT table_name FROM information_schema.tables WHERE table_schema='public' ORDER BY table_name");
  console.log("== public tables ==");
  t.rows.forEach(x => console.log("  " + x.table_name));
  for (const cand of t.rows.map(r => r.table_name)) {
    if (/agent|entity|asset/.test(cand)) {
      try {
        const r = await pool.query("SELECT * FROM \"" + cand + "\" ORDER BY 1 DESC LIMIT 6");
        console.log("== " + cand + " (" + r.rows.length + " rows shown) ==");
        r.rows.forEach(x => console.log("  " + JSON.stringify(x).slice(0, 300)));
      } catch (e) { console.log("== " + cand + " == (query failed: " + e.message + ")"); }
    }
  }
  await pool.end();
})().catch(e => { console.error(e.message); process.exit(1); });
EOF
docker cp "$TMPQ" tdai-memory-core:/tmp/q.js
docker exec tdai-memory-core node /tmp/q.js "$PG_CONNECTION_STRING"
rm -f "$TMPQ"
