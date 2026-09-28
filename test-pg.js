// test-pg.js
import { Pool } from 'pg';
import dotenv from 'dotenv';
dotenv.config();
const pool = new Pool({ connectionString: process.env.DATABASE_URL, ssl: { rejectUnauthorized: false } });
(async () => {
  try {
    const r = await pool.query('SELECT version()');
    console.log(r.rows);
  } catch (e) {
    console.error('connect error', e);
  } finally {
    await pool.end();
  }
})();