import pg from 'pg';

const client = new pg.Client({
  host: '127.0.0.1',
  port: 5432,
  user: 'postgres',
  password: 'postgres',
  database: 'postgres',
});

await client.connect();
await client.query(
  "INSERT INTO votes (voter_id, vote) VALUES ($1, $2) ON CONFLICT (voter_id) DO UPDATE SET vote = EXCLUDED.vote",
  ['smoke-test-voter', 'a']
);
const res = await client.query('SELECT vote, COUNT(id) AS count FROM votes GROUP BY vote');
console.log('rows:', res.rows);
await client.end();
