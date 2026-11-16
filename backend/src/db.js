// PostgreSQL connection pool. Settings come from the .env file.
const { Pool, types } = require('pg');

// Return DATE columns as plain 'YYYY-MM-DD' strings (no time-zone shifting)
types.setTypeParser(1082, (value) => value);

const pool = new Pool({
  host: process.env.PGHOST,
  port: Number(process.env.PGPORT) || 5432,
  database: process.env.PGDATABASE,
  user: process.env.PGUSER,
  password: process.env.PGPASSWORD,
});

module.exports = {
  query: (text, params) => pool.query(text, params),
  pool,
};
