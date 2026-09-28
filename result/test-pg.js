const { Pool } = require('pg');
require('dotenv').config();

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.DATABASE_URL ? { rejectUnauthorized: false } : false,
});

(async () => {
  try {
    const r = await pool.query('SELECT version()');
    console.log('Connected:', r.rows[0].version);

    const t = await pool.query("SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname='public'");
    console.log('Tables:', t.rows.map(r => r.tablename));
  } catch (e) {
    console.error('connect error', e.message || e);
  } finally {
    await pool.end();
  }
})();
