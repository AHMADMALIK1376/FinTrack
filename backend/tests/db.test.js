// Runs every database test in database/tests/ (rules DB-01 – DB-07, AUTH-02, ACC-01, ACC-04, BUD-01, BUD-03, GOAL-02, RPT-01).
// Also checks DB-08: the scripts can be run twice in a row without errors.
const { test, before } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const { resetDatabase, runSqlFile, DATABASE_DIR } = require('./setup');

before(async () => {
  await resetDatabase();
});

test('DB-08 database scripts can be run again on an existing database', async () => {
  await resetDatabase();
});

const testDir = path.join(DATABASE_DIR, 'tests');
for (const file of fs.readdirSync(testDir).filter((f) => f.endsWith('.sql')).sort()) {
  test(`database/tests/${file}`, async (t) => {
    const passes = await runSqlFile(path.join(testDir, file));
    assert.ok(passes.length > 0, 'the file printed no PASS lines');
    for (const line of passes) t.diagnostic(line);
  });
}
