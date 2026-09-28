import { PGlite } from '@electric-sql/pglite';
import { PGLiteSocketServer } from '@electric-sql/pglite-socket';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Real Postgres (WASM build) exposed over the real wire protocol on localhost:5432,
// standing in for a native Postgres server that can't be installed on this machine.
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const dataDir = path.join(__dirname, 'pgdata');

const db = new PGlite(dataDir);
await db.waitReady;

await db.exec(`
  CREATE TABLE IF NOT EXISTS votes (
    id SERIAL PRIMARY KEY,
    voter_id VARCHAR(255) NOT NULL UNIQUE,
    vote VARCHAR(255) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
  );
`);

const server = new PGLiteSocketServer({
  db,
  port: 5432,
  host: '127.0.0.1',
  maxConnections: 10,
});
await server.start();

console.log(`Postgres stub (PGlite) listening on 127.0.0.1:5432, data dir: ${dataDir}`);
