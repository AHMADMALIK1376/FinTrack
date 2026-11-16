// API tests: every route, plus privacy checks where a second user tries to reach the first user's data.
// Rules: AUTH-01 – AUTH-04, SEC-01, SEC-02, ACC-01, ACC-04, TXN-01, TXN-02, BUD-01, BUD-03, GOAL-01, GOAL-02, RPT-01.
const { test, describe, before, after } = require('node:test');
const assert = require('node:assert');
const { resetDatabase } = require('./setup');
const app = require('../src/app');
const db = require('../src/db');

let server;
let baseUrl;

/** Calls the API and returns { status, body }. */
async function call(method, path, { token, body } = {}) {
  const res = await fetch(baseUrl + path, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null };
}

/** Registers a user and returns { token, user, accounts, categories }. */
async function newUser(name) {
  const email = `${name.toLowerCase().replace(/\W/g, '')}@test.pk`;
  const reg = await call('POST', '/api/auth/register', { body: { full_name: name, email, password: 'secret123' } });
  assert.strictEqual(reg.status, 201, JSON.stringify(reg.body));
  const token = reg.body.token;
  const accounts = (await call('GET', '/api/accounts', { token })).body;
  const categories = (await call('GET', '/api/categories', { token })).body;
  const cat = (n) => categories.find((c) => c.name === n).category_id;
  return { token, user: reg.body.user, email, cash: accounts[0].account_id, cat };
}

before(async () => {
  await resetDatabase();
  server = app.listen(0);
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  if (server) server.close();
  await db.pool.end();
});

describe('sign-up and log-in', () => {
  test('AUTH-01 register creates the user with a Cash account and starter categories', async () => {
    const u = await newUser('Ayesha Khan');
    const accounts = (await call('GET', '/api/accounts', { token: u.token })).body;
    const categories = (await call('GET', '/api/categories', { token: u.token })).body;
    assert.deepStrictEqual(accounts.map((a) => a.account_name), ['Cash']);
    assert.ok(categories.length >= 9);
    assert.ok(categories.some((c) => c.name === 'Salary' && c.type === 'income'));
    assert.ok(categories.some((c) => c.name === 'Food' && c.type === 'expense'));
  });

  test('AUTH-01 register refuses missing fields and short passwords', async () => {
    const r1 = await call('POST', '/api/auth/register', { body: { full_name: 'X', email: 'x@test.pk', password: '123' } });
    assert.strictEqual(r1.status, 400);
    const r2 = await call('POST', '/api/auth/register', { body: { email: 'y@test.pk', password: 'secret123' } });
    assert.strictEqual(r2.status, 400);
  });

  test('AUTH-02 the same e-mail cannot register twice, whatever its capitals', async () => {
    await newUser('Bilal Ahmed');
    const again = await call('POST', '/api/auth/register', { body: { full_name: 'B', email: 'BILALAHMED@Test.pk', password: 'secret123' } });
    assert.strictEqual(again.status, 409);
    assert.match(again.body.error, /already exists/);
  });

  test('AUTH-03 passwords are stored only as bcrypt hashes', async () => {
    const u = await newUser('Hash Check');
    const { rows } = await db.query('SELECT password_hash FROM users WHERE email = $1', [u.email]);
    assert.match(rows[0].password_hash, /^\$2[aby]\$10\$/);
    assert.ok(!rows[0].password_hash.includes('secret123'));
  });

  test('AUTH-04 log-in works with the right password and refuses a wrong one', async () => {
    const u = await newUser('Login Test');
    const ok = await call('POST', '/api/auth/login', { body: { email: u.email.toUpperCase(), password: 'secret123' } });
    assert.strictEqual(ok.status, 200);
    assert.ok(ok.body.token);
    const bad = await call('POST', '/api/auth/login', { body: { email: u.email, password: 'wrong-password' } });
    assert.strictEqual(bad.status, 401);
    const unknown = await call('POST', '/api/auth/login', { body: { email: 'nobody@test.pk', password: 'x' } });
    assert.strictEqual(unknown.status, 401);
    assert.strictEqual(bad.body.error, unknown.body.error, 'must not reveal whether the e-mail exists');
  });

  test('AUTH-04 every data route needs a valid token', async () => {
    for (const path of ['/api/accounts', '/api/categories', '/api/transactions', '/api/budgets', '/api/goals', '/api/reports/dashboard']) {
      assert.strictEqual((await call('GET', path)).status, 401, `${path} without a token`);
      assert.strictEqual((await call('GET', path, { token: 'not-a-real-token' })).status, 401, `${path} with a bad token`);
    }
  });
});

describe('accounts, transactions and transfers', () => {
  test('ACC-01 add, rename and delete accounts; duplicate names refused', async () => {
    const u = await newUser('Account Owner');
    const add = await call('POST', '/api/accounts', { token: u.token, body: { account_name: 'HBL', account_type: 'bank' } });
    assert.strictEqual(add.status, 201);
    const dup = await call('POST', '/api/accounts', { token: u.token, body: { account_name: 'HBL', account_type: 'bank' } });
    assert.strictEqual(dup.status, 400);
    const bad = await call('POST', '/api/accounts', { token: u.token, body: { account_name: 'Gold', account_type: 'crypto' } });
    assert.strictEqual(bad.status, 400);
    const rename = await call('PUT', `/api/accounts/${add.body.account_id}`, { token: u.token, body: { account_name: 'HBL Bank', account_type: 'bank' } });
    assert.strictEqual(rename.body.account_name, 'HBL Bank');
    assert.strictEqual((await call('DELETE', `/api/accounts/${add.body.account_id}`, { token: u.token })).status, 204);
  });

  test('DB-02 a category that has transactions cannot be deleted, with a plain message', async () => {
    const u = await newUser('Category Keeper');
    await call('POST', '/api/transactions', { token: u.token, body: { account_id: u.cash, category_id: u.cat('Food'), amount: 50 } });
    const r = await call('DELETE', `/api/categories/${u.cat('Food')}`, { token: u.token });
    assert.strictEqual(r.status, 400);
    assert.match(r.body.error, /linked to other records/);
    const unused = await call('DELETE', `/api/categories/${u.cat('Health')}`, { token: u.token });
    assert.strictEqual(unused.status, 204);
  });

  test('TXN-01 add, edit and delete transactions; balances follow (DB-05)', async () => {
    const u = await newUser('Txn Owner');
    const balance = async () => Number((await call('GET', '/api/accounts', { token: u.token })).body[0].balance);

    const income = await call('POST', '/api/transactions', { token: u.token, body: { account_id: u.cash, category_id: u.cat('Salary'), amount: 50000, description: 'Salary' } });
    assert.strictEqual(income.status, 201);
    const food = await call('POST', '/api/transactions', { token: u.token, body: { account_id: u.cash, category_id: u.cat('Food'), amount: 1500, txn_date: '2026-11-10', description: 'Groceries' } });
    assert.strictEqual(food.body.txn_date, '2026-11-10', 'dates come back exactly as saved');
    assert.strictEqual(await balance(), 48500);

    const edit = await call('PUT', `/api/transactions/${food.body.transaction_id}`, { token: u.token, body: { account_id: u.cash, category_id: u.cat('Food'), amount: 2000, txn_date: '2026-11-10', description: 'Groceries' } });
    assert.strictEqual(edit.status, 200);
    assert.strictEqual(await balance(), 48000);

    assert.strictEqual((await call('DELETE', `/api/transactions/${food.body.transaction_id}`, { token: u.token })).status, 204);
    assert.strictEqual(await balance(), 50000);
  });

  test('DB-03 negative and zero amounts get a friendly message, nothing saved', async () => {
    const u = await newUser('Bad Amount');
    for (const amount of [-10, 0]) {
      const r = await call('POST', '/api/transactions', { token: u.token, body: { account_id: u.cash, category_id: u.cat('Food'), amount } });
      assert.strictEqual(r.status, 400);
      assert.match(r.body.error, /greater than zero/);
    }
    assert.strictEqual((await call('GET', '/api/transactions', { token: u.token })).body.length, 0);
  });

  test('UI-03 incomplete or broken requests get a plain message, never a server error', async () => {
    const u = await newUser('Sloppy Client');
    const missing = await call('POST', '/api/transactions', { token: u.token, body: { account_id: u.cash, category_id: u.cat('Food') } });
    assert.strictEqual(missing.status, 400);
    const badDate = await call('POST', '/api/transactions', { token: u.token, body: { account_id: u.cash, category_id: u.cat('Food'), amount: 5, txn_date: '2026-02-31' } });
    assert.strictEqual(badDate.status, 400);
    const badNumber = await call('POST', '/api/transactions', { token: u.token, body: { account_id: u.cash, category_id: u.cat('Food'), amount: 'lots' } });
    assert.strictEqual(badNumber.status, 400);
    const res = await fetch(`${baseUrl}/api/transactions`, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${u.token}` }, body: '{broken json' });
    assert.strictEqual(res.status, 400);
    assert.ok((await res.json()).error);
  });

  test('TXN-02 filter by month, type, category and search text', async () => {
    const u = await newUser('Filter User');
    const add = (category, amount, txn_date, description) => call('POST', '/api/transactions',
      { token: u.token, body: { account_id: u.cash, category_id: u.cat(category), amount, txn_date, description } });
    await add('Salary', 90000, '2026-10-01', 'October salary');
    await add('Food', 700, '2026-10-05', 'Pizza night');
    await add('Rent', 30000, '2026-11-01', 'November rent');
    await add('Food', 400, '2026-11-03', 'Chai and samosa');

    const get = async (q) => (await call('GET', `/api/transactions?${q}`, { token: u.token })).body.map((t) => t.description).sort();
    assert.deepStrictEqual(await get('month=2026-11'), ['Chai and samosa', 'November rent']);
    assert.deepStrictEqual(await get('type=income'), ['October salary']);
    assert.deepStrictEqual(await get(`category_id=${u.cat('Food')}`), ['Chai and samosa', 'Pizza night']);
    assert.deepStrictEqual(await get('search=PIZZA'), ['Pizza night']);
  });

  test('SEC-02 search text is treated as text, never as SQL', async () => {
    const u = await newUser('Injection Test');
    await call('POST', '/api/transactions', { token: u.token, body: { account_id: u.cash, category_id: u.cat('Salary'), amount: 10 } });
    const r = await call('GET', `/api/transactions?search=${encodeURIComponent("' OR 1=1 --")}`, { token: u.token });
    assert.strictEqual(r.status, 200);
    assert.strictEqual(r.body.length, 0);
  });

  test('ACC-04 transfer moves money atomically and refuses more than the balance', async () => {
    const u = await newUser('Transfer User');
    const bank = (await call('POST', '/api/accounts', { token: u.token, body: { account_name: 'Bank', account_type: 'bank' } })).body.account_id;
    await call('POST', '/api/transactions', { token: u.token, body: { account_id: bank, category_id: u.cat('Salary'), amount: 10000 } });

    const ok = await call('POST', '/api/accounts/transfer', { token: u.token, body: { from_account: bank, to_account: u.cash, amount: 2500 } });
    assert.strictEqual(ok.status, 200);
    const balances = Object.fromEntries((await call('GET', '/api/accounts', { token: u.token })).body.map((a) => [a.account_name, Number(a.balance)]));
    assert.deepStrictEqual(balances, { Cash: 2500, Bank: 7500 });

    const tooMuch = await call('POST', '/api/accounts/transfer', { token: u.token, body: { from_account: bank, to_account: u.cash, amount: 999999 } });
    assert.strictEqual(tooMuch.status, 400);
    assert.match(tooMuch.body.error, /Not enough balance/);
  });
});

describe('budgets, goals and the dashboard', () => {
  test('BUD-01 BUD-03 RPT-01 budget warning and dashboard totals', async () => {
    const u = await newUser('Budget User');
    const month = new Date().toISOString().slice(0, 7);
    const add = (category, amount) => call('POST', '/api/transactions',
      { token: u.token, body: { account_id: u.cash, category_id: u.cat(category), amount, txn_date: `${month}-02` } });
    await add('Salary', 100000);
    await add('Food', 12000);
    await add('Transport', 3000);

    assert.strictEqual((await call('POST', '/api/budgets', { token: u.token, body: { category_id: u.cat('Food'), limit_amount: 10000, month } })).status, 201);
    await call('POST', '/api/budgets', { token: u.token, body: { category_id: u.cat('Transport'), limit_amount: 5000, month } });
    const budgets = (await call('GET', `/api/budgets?month=${month}`, { token: u.token })).body;
    assert.strictEqual(Number(budgets.find((b) => b.category === 'Food').spent), 12000);

    const d = (await call('GET', `/api/reports/dashboard?month=${month}`, { token: u.token })).body;
    assert.strictEqual(Number(d.total_income), 100000);
    assert.strictEqual(Number(d.total_expense), 15000);
    assert.strictEqual(Number(d.net_saving), 85000);
    assert.strictEqual(Number(d.total_balance), 85000);
    assert.deepStrictEqual(d.budget_warnings.map((w) => w.category), ['Food']);
    assert.strictEqual(Number(d.budget_warnings[0].over_by), 2000);
  });

  test('BUD-01 a budget can only be set on your own expense category, for a valid month', async () => {
    const u = await newUser('Budget Rules');
    const month = '2026-11';
    const income = await call('POST', '/api/budgets', { token: u.token, body: { category_id: u.cat('Salary'), limit_amount: 100, month } });
    assert.strictEqual(income.status, 400);
    const noMonth = await call('POST', '/api/budgets', { token: u.token, body: { category_id: u.cat('Food'), limit_amount: 100 } });
    assert.strictEqual(noMonth.status, 400);
    const badMonth = await call('POST', '/api/budgets', { token: u.token, body: { category_id: u.cat('Food'), limit_amount: 100, month: '2026-13' } });
    assert.strictEqual(badMonth.status, 400);
  });

  test('GOAL-01 GOAL-02 create a goal, add savings, refuse going past the target', async () => {
    const u = await newUser('Goal User');
    const goal = await call('POST', '/api/goals', { token: u.token, body: { goal_name: 'Laptop', target_amount: 100000, deadline: '2027-06-30' } });
    assert.strictEqual(goal.status, 201);
    assert.strictEqual(goal.body.deadline, '2027-06-30');
    const add = await call('PATCH', `/api/goals/${goal.body.goal_id}/add`, { token: u.token, body: { amount: 40000 } });
    assert.strictEqual(Number(add.body.saved_amount), 40000);
    const tooMuch = await call('PATCH', `/api/goals/${goal.body.goal_id}/add`, { token: u.token, body: { amount: 70000 } });
    assert.strictEqual(tooMuch.status, 400);
  });
});

describe('privacy: a user can never reach another user\'s data', () => {
  let owner;
  let intruder;
  let ids;

  before(async () => {
    owner = await newUser('Data Owner');
    intruder = await newUser('Intruder');
    const month = '2026-11';
    const bank = (await call('POST', '/api/accounts', { token: owner.token, body: { account_name: 'Secret Bank', account_type: 'bank' } })).body.account_id;
    const txn = (await call('POST', '/api/transactions', { token: owner.token, body: { account_id: bank, category_id: owner.cat('Salary'), amount: 77777, description: 'Secret salary' } })).body.transaction_id;
    const budget = (await call('POST', '/api/budgets', { token: owner.token, body: { category_id: owner.cat('Food'), limit_amount: 5000, month } })).body.budget_id;
    const goal = (await call('POST', '/api/goals', { token: owner.token, body: { goal_name: 'Secret goal', target_amount: 1000 } })).body.goal_id;
    ids = { bank, txn, budget, goal, food: owner.cat('Food'), month };
  });

  test('SEC-01 lists only show the user\'s own rows', async () => {
    const t = intruder.token;
    assert.ok(!(await call('GET', '/api/accounts', { token: t })).body.some((a) => a.account_id === ids.bank));
    assert.ok(!(await call('GET', '/api/categories', { token: t })).body.some((c) => c.category_id === ids.food));
    assert.strictEqual((await call('GET', '/api/transactions', { token: t })).body.length, 0);
    assert.strictEqual((await call('GET', `/api/budgets?month=${ids.month}`, { token: t })).body.length, 0);
    assert.strictEqual((await call('GET', '/api/goals', { token: t })).body.length, 0);
    assert.strictEqual(Number((await call('GET', '/api/reports/dashboard', { token: t })).body.total_balance), 0);
  });

  test('SEC-01 changing or deleting another user\'s rows returns "not found" and changes nothing', async () => {
    const t = intruder.token;
    const attempts = [
      ['PUT', `/api/accounts/${ids.bank}`, { account_name: 'Hacked', account_type: 'bank' }],
      ['DELETE', `/api/accounts/${ids.bank}`],
      ['DELETE', `/api/categories/${ids.food}`],
      ['PUT', `/api/transactions/${ids.txn}`, { account_id: intruder.cash, category_id: intruder.cat('Salary'), amount: 1, txn_date: '2026-11-01' }],
      ['DELETE', `/api/transactions/${ids.txn}`],
      ['DELETE', `/api/budgets/${ids.budget}`],
      ['PATCH', `/api/goals/${ids.goal}/add`, { amount: 1 }],
      ['DELETE', `/api/goals/${ids.goal}`],
    ];
    for (const [method, path, body] of attempts) {
      const r = await call(method, path, { token: t, body });
      assert.strictEqual(r.status, 404, `${method} ${path} returned ${r.status}`);
    }
    const ownerTxns = (await call('GET', '/api/transactions', { token: owner.token })).body;
    assert.strictEqual(ownerTxns.length, 1);
    assert.strictEqual(Number(ownerTxns[0].amount), 77777);
  });

  test('SEC-01 using another user\'s account, category or transfer target is refused', async () => {
    const t = intruder.token;
    const intoTheirAccount = await call('POST', '/api/transactions', { token: t, body: { account_id: ids.bank, category_id: intruder.cat('Food'), amount: 1 } });
    assert.strictEqual(intoTheirAccount.status, 404);
    const theirCategory = await call('POST', '/api/transactions', { token: t, body: { account_id: intruder.cash, category_id: ids.food, amount: 1 } });
    assert.strictEqual(theirCategory.status, 404);
    const theirBudgetCategory = await call('POST', '/api/budgets', { token: t, body: { category_id: ids.food, limit_amount: 1, month: ids.month } });
    assert.strictEqual(theirBudgetCategory.status, 404);
    const stealTransfer = await call('POST', '/api/accounts/transfer', { token: t, body: { from_account: ids.bank, to_account: intruder.cash, amount: 1 } });
    assert.strictEqual(stealTransfer.status, 404);
    const ownerBank = (await call('GET', '/api/accounts', { token: owner.token })).body.find((a) => a.account_id === ids.bank);
    assert.strictEqual(Number(ownerBank.balance), 77777);
  });
});
