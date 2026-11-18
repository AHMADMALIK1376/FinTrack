// DB-13: two transfers at the same moment cannot overdraw an account.
// Two real database sessions (as the website's account, fintrack_app) call transfer_money()
// at once. transfer_money() locks both account rows with SELECT ... FOR UPDATE, so the second
// session waits for the first to commit, then sees the new balance and is refused.
// The same story, step by step for pgAdmin, is in database/demo/two_sessions_transfer.sql.
const { describe, test, before, after } = require('node:test');
const assert = require('node:assert');
const { resetDatabase, adminQuery, appClient } = require('./setup');

let bank, cash, a, b;
const balance = async (id) => Number((await adminQuery('SELECT balance FROM accounts WHERE account_id = $1', [id])).rows[0].balance);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Starts a query and remembers whether it has finished yet. */
function track(promise) {
  const t = { done: false, promise: promise.finally(() => { t.done = true; }) };
  t.promise.catch(() => {});
  return t;
}
/** Is this session waiting for a row lock right now? */
async function waitingForLock(client) {
  const { rows } = await adminQuery('SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1', [client.processID]);
  return rows[0]?.wait_event_type === 'Lock';
}

before(async () => {
  await resetDatabase();
  const user = (await adminQuery("INSERT INTO users (full_name, email, password_hash) VALUES ('Lock Test', 'locks@test.pk', 'x') RETURNING user_id")).rows[0].user_id;
  bank = (await adminQuery("INSERT INTO accounts (user_id, account_name, account_type) VALUES ($1, 'Bank', 'bank') RETURNING account_id", [user])).rows[0].account_id;
  cash = (await adminQuery("INSERT INTO accounts (user_id, account_name, account_type) VALUES ($1, 'Cash', 'cash') RETURNING account_id", [user])).rows[0].account_id;
  const salary = (await adminQuery("INSERT INTO categories (user_id, name, type) VALUES ($1, 'Salary', 'income') RETURNING category_id", [user])).rows[0].category_id;
  await adminQuery('INSERT INTO transactions (account_id, category_id, amount) VALUES ($1, $2, 10000)', [bank, salary]);
  [a, b] = await Promise.all([appClient(), appClient()]);
});

after(async () => {
  await Promise.all([a, b].map((c) => c && c.end()));
});

describe('two sessions transferring at the same time (DB-13)', () => {
  test('DB-13 the second transfer waits for the first, then is refused instead of overdrawing', async () => {
    assert.strictEqual(await balance(bank), 10000);
    await a.query('BEGIN');
    await a.query('CALL transfer_money($1, $2, 7000)', [bank, cash]);   // session A: Rs 7,000 out, not committed yet

    const second = track(b.query('CALL transfer_money($1, $2, 7000)', [bank, cash]));   // session B: another Rs 7,000
    await sleep(400);
    assert.strictEqual(second.done, false, 'session B must wait while session A holds the lock');
    assert.ok(await waitingForLock(b), 'session B must be waiting for a row lock');

    await a.query('COMMIT');
    await assert.rejects(second.promise, /Not enough balance for this transfer/, 'after A commits, B must see Rs 3,000 left and be refused');
    assert.strictEqual(await balance(bank), 3000, 'only one Rs 7,000 transfer went through');
    assert.strictEqual(await balance(cash), 7000);
  });

  test('DB-13 two transfers in opposite directions at once do not deadlock', async () => {
    await a.query('BEGIN');
    await a.query('CALL transfer_money($1, $2, 100)', [bank, cash]);
    const opposite = track(b.query('CALL transfer_money($1, $2, 100)', [cash, bank]));
    await sleep(300);
    assert.strictEqual(opposite.done, false, 'the opposite transfer waits for the first one');
    await a.query('COMMIT');
    await opposite.promise;   // finishes normally: rows are always locked in the same order, so no deadlock
    assert.strictEqual(await balance(bank), 3000);
    assert.strictEqual(await balance(cash), 7000);
  });

});
