const fs = require("fs");
const path = "/app/src/core/store/pg-store.ts";
let s = fs.readFileSync(path, "utf8");

let fixes = 0;

// Fix queryL0ForL1: convert timestamp from string (bigint) to number
// The return statement is: return r.rows as L0QueryRow[];
// Change to map rows and convert timestamp to Number
const old1 = "return r.rows as L0QueryRow[];";
const new1 = "return r.rows.map((row: any) => ({ ...row, timestamp: Number(row.timestamp) })) as L0QueryRow[];";
if (s.includes(old1)) {
  s = s.replace(old1, new1);
  console.log("Fix 1: queryL0ForL1 - convert timestamp to Number");
  fixes++;
} else {
  console.log("Fix 1: NOT FOUND - queryL0ForL1 return statement");
}

// Fix queryL0Paginated: also returns rows with timestamp
// Look for the return pattern in queryL0Paginated
const old2 = "return { items: dr.rows.map((row: any) => ({";
if (s.includes(old2)) {
  // This is more complex - need to add timestamp conversion in the map
  console.log("Fix 2: queryL0Paginated found, checking if timestamp conversion needed...");
} else {
  console.log("Fix 2: queryL0Paginated pattern not found (may not need fix)");
}

// Fix searchL0Fts: the returned rows also have timestamp field
// Check if searchL0Fts returns timestamp
const ftsMatch = s.match(/searchL0Fts[\s\S]*?return r\.rows/);
if (ftsMatch) {
  console.log("Fix 3: searchL0Fts found, checking timestamp...");
}

// Also fix queryL1Paginated and other methods that return rows with timestamp
// For L1 records, the timestamp fields are timestamp_str, timestamp_start, timestamp_end (all text)
// So they should be fine. But let's check for any numeric timestamp fields.

// Fix all pool.query results that return timestamp column
// The most reliable fix: convert timestamp to number in queryL0ForL1
// and also in the L0 search results

// Fix searchL0Fts return - add timestamp conversion
const old3 = "return r.rows.filter((row: any) => rowMatchesIsolation(row, filter)).slice(0, limit).map((row: any) => ({ record_id: row.record_id, session_key: row.session_key, session_id: row.session_id, team_id: row.team_id, task_id: row.task_id, user_id: row.user_id, agent_id: row.agent_id, role: row.role, message_text: row.message_text, recorded_at: row.recorded_at, timestamp: row.timestamp,";
const new3 = "return r.rows.filter((row: any) => rowMatchesIsolation(row, filter)).slice(0, limit).map((row: any) => ({ record_id: row.record_id, session_key: row.session_key, session_id: row.session_id, team_id: row.team_id, task_id: row.task_id, user_id: row.user_id, agent_id: row.agent_id, role: row.role, message_text: row.message_text, recorded_at: row.recorded_at, timestamp: Number(row.timestamp),";
if (s.includes(old3)) {
  s = s.replace(old3, new3);
  console.log("Fix 3: searchL0Fts - convert timestamp to Number");
  fixes++;
} else {
  console.log("Fix 3: NOT FOUND - searchL0Fts return");
}

// Also fix queryL0Paginated return - check for timestamp in the mapping
const old4 = "timestamp: row.timestamp,";
const new4 = "timestamp: Number(row.timestamp),";
// Count occurrences
const count4 = (s.match(/timestamp: row\.timestamp,/g) || []).length;
s = s.replaceAll("timestamp: row.timestamp,", "timestamp: Number(row.timestamp),");
if (count4 > 0) {
  console.log(`Fix 4: Replaced ${count4} remaining 'timestamp: row.timestamp' -> 'timestamp: Number(row.timestamp)'`);
  fixes += count4;
}

// Also fix the searchL0Vector which fetches rows individually
const old5 = "const mr = await this.pool.query(\"SELECT record_id, session_key, session_id, team_id, task_id, user_id, agent_id, role, message_text, recorded_at, timestamp FROM l0_conversations WHERE record_id = $1\", [row.record_id]);";
const new5 = "const mr = await this.pool.query(\"SELECT record_id, session_key, session_id, team_id, task_id, user_id, agent_id, role, message_text, recorded_at, timestamp FROM l0_conversations WHERE record_id = $1\", [row.record_id]);\n        if (mr.rows.length === 0) continue;\n        const m = mr.rows[0];\n        m.timestamp = Number(m.timestamp);";
// This might already exist, so let's just check
if (s.includes(old5) && !s.includes("m.timestamp = Number(m.timestamp)")) {
  // This is complex, skip for now
  console.log("Fix 5: searchL0Vector needs manual check");
}

fs.writeFileSync(path, s);
console.log(`\nTotal fixes: ${fixes}`);
