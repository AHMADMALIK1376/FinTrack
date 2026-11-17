// Test setup: points the app at a separate test database (never your real one), and
// rebuilds that database from database/0*.sql before each test file runs.
// Settings come from backend/.env; the test database name is TEST_PGDATABASE (default fintrack_test).
// Two accounts: the app connects as PGUSER (fintrack_app); rebuilding the database needs the
// admin account PGADMIN_USER / PGADMIN_PASSWORD (postgres). Without PGADMIN_*, PGUSER is used for both.
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env'), quiet: true });
const { spawn } = require('child_process');
const net = require('net');
const { Client } = require('pg');
const { checkDatabaseSettings } = require('./check-env');

checkDatabaseSettings({ admin: true });

process.env.PGDATABASE = process.env.TEST_PGDATABASE || 'fintrack_test';
process.env.JWT_SECRET = process.env.JWT_SECRET || 'test-only-secret';

// Safety: the schema script drops every table, so refuse to run on a database not named *_test.
if (!process.env.PGDATABASE.endsWith('_test')) {
  throw new Error(`Tests only run on a database whose name ends in _test (got "${process.env.PGDATABASE}").`);
}

const DATABASE_DIR = path.join(__dirname, '..', '..', 'database');
const connection = (database) => ({
  host: process.env.PGHOST, port: Number(process.env.PGPORT) || 5432,
  user: process.env.PGADMIN_USER || process.env.PGUSER,
  password: process.env.PGADMIN_PASSWORD ?? process.env.PGPASSWORD,
  database,
});

// Every numbered script except the sample data, in order: 01_schema … 06_roles
const SCRIPTS = fs.readdirSync(DATABASE_DIR).filter((f) => /^\d\d_.*\.sql$/.test(f) && f !== '04_seed.sql').sort();

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

/** Drops and rebuilds every table, trigger, view, function, audit log and role grant (no sample data). */
async function resetDatabase() {
  await ensureDatabase();
  const client = new Client(connection(process.env.PGDATABASE));
  client.on('notice', () => {});
  await client.connect();
  try {
    for (const file of SCRIPTS) {
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

/** Runs one SQL statement as the admin user (for checks the API doesn't expose). */
async function adminQuery(text, params) {
  const client = new Client(connection(process.env.PGDATABASE));
  await client.connect();
  try {
    return await client.query(text, params);
  }
  finally {
    await client.end();
  }
}

/** Finds a free TCP port. */
function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
    server.on('error', reject);
  });
}

/**
 * Starts the PHP backend (php -S … router.php) on a free port, connected to the test database,
 * and waits until /api/health answers. Returns { baseUrl, stop }.
 */
async function startPhpServer() {
  const port = await freePort();
  const backendDir = path.join(__dirname, '..');
  const php = spawn(process.env.PHP_BINARY || 'php',
    ['-S', `127.0.0.1:${port}`, '-t', path.join(backendDir, '..', 'frontend'), path.join(backendDir, 'router.php')],
    { cwd: backendDir, env: process.env, stdio: ['ignore', 'ignore', 'pipe'] });
  let log = '';
  php.stderr.on('data', (chunk) => { log += chunk; });
  const baseUrl = `http://127.0.0.1:${port}`;
  for (let i = 0; i < 100; i++) {
    try {
      const res = await fetch(`${baseUrl}/api/health`);
      if (res.ok) return { baseUrl, stop: () => php.kill(), log: () => log };
    }
    catch {
      // not listening yet
    }
    if (php.exitCode !== null) break;
    await new Promise((r) => setTimeout(r, 100));
  }
  php.kill();
  throw new Error(`The PHP server did not start. Is PHP installed with pdo_pgsql? Output:\n${log}`);
}

module.exports = { resetDatabase, runSqlFile, adminQuery, startPhpServer, DATABASE_DIR };
