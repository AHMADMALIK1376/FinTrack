// Checks that the database settings from backend/.env were loaded, and explains how to fix it if not.
// Used by server.js and by the tests, so a missing or misnamed .env gives a clear message
// instead of a confusing database error ("client password must be a string").
const fs = require('fs');
const path = require('path');

/** Throws an Error with plain instructions when PGPASSWORD (or the .env file) is missing. */
function checkDatabaseSettings() {
  if (typeof process.env.PGPASSWORD === 'string') return;
  const backendDir = path.join(__dirname, '..');
  const hasEnv = fs.existsSync(path.join(backendDir, '.env'));
  const hasEnvTxt = fs.existsSync(path.join(backendDir, '.env.txt'));
  let hint;
  if (hasEnvTxt && !hasEnv) {
    hint = 'Found backend/.env.txt: Windows saved it with the wrong name. Rename it to .env (PowerShell: Rename-Item .env.txt .env).';
  }
  else if (!hasEnv) {
    hint = 'There is no backend/.env file. Copy backend/.env.example to backend/.env and fill in your settings.';
  }
  else {
    hint = 'backend/.env has no PGPASSWORD line. Add PGPASSWORD=<your postgres password> (no # in front).';
  }
  throw new Error(`Database password not set. ${hint}`);
}

module.exports = { checkDatabaseSettings };
