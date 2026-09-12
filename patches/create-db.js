// 创建 tdai_memory 数据库 + pgvector / pg_trgm 扩展。
// 用法：PG_CONNECTION_STRING="postgres://<user>:<password>@<pg-host>:5432/postgres" node create-db.js
const { Pool } = require("pg");

const base = process.env.PG_CONNECTION_STRING;
if (!base) {
  console.error("请先设置 PG_CONNECTION_STRING（指向 postgres 维护库，如 postgres://user:pass@host:5432/postgres）");
  process.exit(1);
}
const target = base.replace(/\/postgres$/, "/tdai_memory");

const p = new Pool({ connectionString: base });

async function main() {
  try {
    await p.query("CREATE DATABASE tdai_memory");
    console.log("Database tdai_memory created");
  } catch (e) {
    if (e.code === "42P04") {
      console.log("Database tdai_memory already exists");
    } else {
      throw e;
    }
  }

  // Connect to the new database and create extensions
  const p2 = new Pool({ connectionString: target });
  try {
    await p2.query("CREATE EXTENSION IF NOT EXISTS vector");
    await p2.query("CREATE EXTENSION IF NOT EXISTS pg_trgm");
    console.log("Extensions created in tdai_memory");
  } catch (e) {
    console.log("Extension error:", e.message);
  }
  await p2.end();
  await p.end();
}
main();
