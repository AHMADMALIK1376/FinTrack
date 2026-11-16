// Test setup: points the app at a separate test database (never your real one), and
// rebuilds that database from database/0*.sql before each test file runs.
// Settings come from backend/.env; the test database name is TEST_PGDATABASE (default fintrack_test).
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env'), quiet: true });
const { Client } = require('pg');
const { checkDatabaseSettings } = require('../src/check-env');

checkDatabaseSettings();

process.env.PGDATABASE = process.env.TEST_PGDATABASE || 'fintrack_test';
process.env.JWT_SECRET = process.env.JWT_SECRET || 'test-only-secret';

// Safety: the schema script drops every table, so refuse to run on a database not named *_test.
if (!process.env.PGDATABASE.endsWith('_test')) {
  throw new Error(`Tests only run on a database whose name ends in _test (got "${process.env.PGDATABASE}").`);
}

const DATABASE_DIR = path.join(__dirname, '..', '..', 'database');
const connection = (database) => ({
  host: process.env.PGHOST, port: Number(process.env.PGPORT) || 5432,
  user: process.env.PGUSER, password: process.env.PGPASSWORD, database,
});

/** Creates the test database if it does not exist yet. */
async function ensureDatabase() {
  const admin = new Client(connection('postgres'));
  await admin.connect();
  try {
    const { rowCount } = await admin.query('SELECT 1 FROM pg_database WHERE datname = $1', [process.env.PGDATABASE]);
    if (!rowCount) await admin.query(`CREATE DATABASE "${process.env.PGDATABASE}"`);
  } finally {
    await admin.end();
  }
}

/** Drops and rebuilds every table, trigger, view and function from database/01 – 03 (no sample data). */
async function resetDatabase() {
  await ensureDatabase();
  const client = new Client(connection(process.env.PGDATABASE));
  client.on('notice', () => {});
  await client.connect();
  try {
    for (const file of ['01_schema.sql', '02_triggers.sql', '03_views_functions.sql']) {
      await client.query(fs.readFileSync(path.join(DATABASE_DIR, file), 'utf8'));
    }
  } finally {
    await client.end();
  }
}

/**
 * Runs one SQL test file and returns the PASS lines it printed.
 * Throws with the failing rule's message if any check fails.
 */
async function runSqlFile(file) {
  const client = new Client(connection(process.env.PGDATABASE));
  const passes = [];
  client.on('notice', (msg) => { if (msg.message.startsWith('PASS')) passes.push(msg.message); });
  await client.connect();
  try {
    await client.query(fs.readFileSync(file, 'utf8'));
    return passes;
  }
  catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    throw new Error(err.message);
  }
  finally {
    await client.end();
  }
}

module.exports = { resetDatabase, runSqlFile, DATABASE_DIR };
