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

/**
 * Runs one statement as the logged-in user (DB-09): inside a transaction that first sets
 * app.user_id, so the audit trigger records who made the change.
 * @param {number} userId the logged-in user's id
 * @param {string} text SQL with $1, $2 … parameters
 * @param {Array} params parameter values
 * @returns {Promise<import('pg').QueryResult>} the statement's result
 * @throws the database error; the transaction is rolled back
 */
async function asUser(userId, text, params) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT set_config('app.user_id', $1, true)", [String(userId)]);
    const result = await client.query(text, params);
    await client.query('COMMIT');
    return result;
  }
  catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    throw err;
  }
  finally {
    client.release();
  }
}

module.exports = {
  query: (text, params) => pool.query(text, params),
  asUser,
  pool,
};
