// API tests: every route of the PHP backend, tested over HTTP, plus privacy checks where a second
// user tries to reach the first user's data. The tests start `php -S … router.php` themselves.
// Rules: AUTH-01 – AUTH-04, SEC-01, SEC-02, DB-09, DB-10, ACC-01, ACC-04, TXN-01, TXN-02, BUD-01, BUD-03, GOAL-01, GOAL-02, RPT-01.
const { test, describe, before, after } = require('node:test');
const assert = require('node:assert');
const { resetDatabase, adminQuery, startPhpServer } = require('./setup');

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
  server = await startPhpServer();
  baseUrl = server.baseUrl;
});

after(() => {
  if (server) server.stop();
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
    const { rows } = await adminQuery('SELECT password_hash FROM users WHERE email = $1', [u.email]);
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
    assert.strictEqual(bad.body.error, 'Choose an account type: bank, cash, wallet or card.', 'DB-11 the enum error gets a plain message');
    const rename = await call('PUT', `/api/accounts/${add.body.account_id}`, { token: u.token, body: { account_name: 'HBL Bank', account_type: 'bank' } });
    assert.strictEqual(rename.body.account_name, 'HBL Bank');
    assert.strictEqual((await call('DELETE', `/api/accounts/${add.body.account_id}`, { token: u.token })).status, 204);
  });

  test('ACC-01 rename a category; duplicates and the Transfer category are refused', async () => {
    const u = await newUser('rename');
    const food = u.cat('Food');
    const renamed = await call('PUT', `/api/categories/${food}`, { token: u.token, body: { name: 'Groceries' } });
    assert.strictEqual(renamed.status, 200);
    assert.strictEqual(renamed.body.name, 'Groceries');
    assert.strictEqual(renamed.body.type, 'expense', 'the type does not change');
    const dup = await call('PUT', `/api/categories/${food}`, { token: u.token, body: { name: 'Rent' } });
    assert.strictEqual(dup.status, 400);
    assert.match(dup.body.error, /already have a category called "Rent"/);
    const reserved = await call('PUT', `/api/categories/${food}`, { token: u.token, body: { name: 'transfer' } });
    assert.strictEqual(reserved.status, 400);
    const empty = await call('PUT', `/api/categories/${food}`, { token: u.token, body: { name: '  ' } });
    assert.strictEqual(empty.status, 400);
    const other = await newUser('rename-other');
    const stranger = await call('PUT', `/api/categories/${food}`, { token: other.token, body: { name: 'Mine now' } });
    assert.strictEqual(stranger.status, 404, 'SEC-01 another user cannot rename it');
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

describe('activity log and database role', () => {
  test('DB-10 the API connects to the database as fintrack_app, never as an admin', async () => {
    const health = await call('GET', '/api/health');
    assert.strictEqual(health.body.database_role, 'fintrack_app',
      'set PGUSER=fintrack_app and PGPASSWORD=fintrack_app_local in backend/.env (and run database/06_roles.sql)');
    const { rows } = await adminQuery('SELECT rolsuper FROM pg_roles WHERE rolname = $1', [health.body.database_role]);
    assert.strictEqual(rows[0].rolsuper, false);
  });

  test('DB-09 activity shows the user\'s own changes as plain sentences, newest first', async () => {
    const u = await newUser('Activity User');
    const t = (await call('POST', '/api/transactions', { token: u.token, body: { account_id: u.cash, category_id: u.cat('Food'), amount: 8000, description: 'Groceries' } })).body;
    await call('PUT', `/api/transactions/${t.transaction_id}`, { token: u.token, body: { account_id: u.cash, category_id: u.cat('Food'), amount: 8500, txn_date: t.txn_date, description: 'Groceries' } });
    await call('PUT', `/api/accounts/${u.cash}`, { token: u.token, body: { account_name: 'Wallet', account_type: 'cash' } });
    await call('POST', '/api/budgets', { token: u.token, body: { category_id: u.cat('Food'), limit_amount: 10000, month: '2026-11' } });
    await call('DELETE', `/api/transactions/${t.transaction_id}`, { token: u.token });
    await call('POST', '/api/transactions', { token: u.token, body: { account_id: u.cash, category_id: u.cat('Salary'), amount: 120000, description: 'Salary' } });

    const activity = await call('GET', '/api/activity', { token: u.token });
    assert.strictEqual(activity.status, 200);
    assert.deepStrictEqual(activity.body.map((a) => a.summary), [
      'Added "Salary": +Rs 120,000 to Wallet',
      'Deleted "Groceries" (−Rs 8,500 from Wallet)',
      'Set a Rs 10,000 budget for Food',
      'Changed the account "Cash": name "Cash" → "Wallet"',
      'Changed "Groceries": amount Rs 8,000 → Rs 8,500',
      'Added "Groceries": −Rs 8,000 from Wallet',
      'Added the account "Cash"',
    ]);
    assert.ok(activity.body.every((a) => a.who === 'you'));
  });

  test('SEC-01 activity never shows another user\'s log', async () => {
    const owner = await newUser('Private Spender');
    await call('POST', '/api/transactions', { token: owner.token, body: { account_id: owner.cash, category_id: owner.cat('Food'), amount: 999, description: 'Secret dinner' } });
    const other = await newUser('Nosy Neighbour');
    const activity = (await call('GET', '/api/activity?limit=100', { token: other.token })).body;
    assert.ok(!activity.some((a) => a.summary.includes('Secret dinner')));
    assert.deepStrictEqual(activity.map((a) => a.summary), ['Added the account "Cash"']);
  });
});

describe('paging and recurring transactions (TXN-05, TXN-07)', () => {
  const today = () => new Date().toISOString().slice(0, 10);
  const daysAgo = (n) => { const d = new Date(); d.setUTCDate(d.getUTCDate() - n); return d.toISOString().slice(0, 10); };

  test('TXN-05 keyset paging returns 50 at a time, newest first, with no gaps or repeats', async () => {
    const u = await newUser('pager');
    // 120 expenses spread over 30 days (several per day, so ties on the date are tested too)
    await adminQuery(`INSERT INTO transactions (account_id, category_id, amount, txn_date, description)
                      SELECT $1, $2, 10 + i, CURRENT_DATE - (i % 30), 'Item ' || i FROM generate_series(1, 120) i`, [u.cash, u.cat('Food')]);
    const seen = [];
    let page = await call('GET', '/api/transactions?limit=50', { token: u.token });
    assert.strictEqual(page.body.length, 50);
    while (page.body.length) {
      seen.push(...page.body);
      const last = page.body[page.body.length - 1];
      page = await call('GET', `/api/transactions?limit=50&before_date=${last.txn_date.slice(0, 10)}&before_id=${last.transaction_id}`, { token: u.token });
    }
    assert.strictEqual(seen.length, 120, 'every row exactly once');
    assert.strictEqual(new Set(seen.map((t) => t.transaction_id)).size, 120, 'no repeats');
    const order = seen.map((t) => `${t.txn_date.slice(0, 10)} ${String(t.transaction_id).padStart(8, '0')}`);
    assert.deepStrictEqual(order, [...order].sort().reverse(), 'newest first, then highest id first');
    const filtered = await call('GET', '/api/transactions?limit=5&search=Item%2011', { token: u.token });
    assert.ok(filtered.body.length >= 1 && filtered.body.every((t) => t.description.startsWith('Item 11')), 'filters still apply with paging');
  });

  test('TXN-07 a monthly rule starting today posts one transaction at once and moves to next month', async () => {
    const u = await newUser('repeat');
    const made = await call('POST', '/api/recurring', { token: u.token, body: {
      account_id: u.cash, category_id: u.cat('Rent'), amount: 4000, description: 'Room rent', frequency: 'monthly', start_date: today() } });
    assert.strictEqual(made.status, 201, JSON.stringify(made.body));
    assert.strictEqual(made.body.posted, 1);
    assert.strictEqual(made.body.rule.category, 'Rent');
    assert.ok(made.body.rule.next_run_date.slice(0, 10) > today());
    const txns = (await call('GET', '/api/transactions', { token: u.token })).body;
    assert.ok(txns.some((t) => t.description === 'Room rent' && t.recurring_id === made.body.rule.recurring_id), 'the posted transaction links to its rule');
    const list = (await call('GET', '/api/recurring', { token: u.token })).body;
    assert.strictEqual(list.length, 1);
  });

  test('TXN-07 log-in posts rules that came due; pausing and resuming skips the paused dates', async () => {
    const u = await newUser('weekly');
    const rule = (await call('POST', '/api/recurring', { token: u.token, body: {
      account_id: u.cash, category_id: u.cat('Transport'), amount: 500, description: 'Bus pass', frequency: 'weekly', start_date: daysAgo(14) } })).body;
    assert.strictEqual(rule.posted, 3, 'started 14 days ago: 3 weekly transactions caught up');

    // pretend a week passed without anyone opening FinTrack
    await adminQuery("UPDATE recurring_transactions SET next_run_date = CURRENT_DATE WHERE recurring_id = $1", [rule.rule.recurring_id]);
    const login = await call('POST', '/api/auth/login', { body: { email: u.email, password: 'secret123' } });
    assert.strictEqual(login.status, 200);
    const count = async () => (await call('GET', '/api/transactions?search=Bus%20pass', { token: u.token })).body.length;
    assert.strictEqual(await count(), 4, 'logging in posted the one that came due');

    const paused = await call('PUT', `/api/recurring/${rule.rule.recurring_id}`, { token: u.token, body: { is_active: false } });
    assert.strictEqual(paused.body.rule.is_active, false);
    await adminQuery("UPDATE recurring_transactions SET next_run_date = CURRENT_DATE - 7 WHERE recurring_id = $1", [rule.rule.recurring_id]);
    const resumed = await call('PUT', `/api/recurring/${rule.rule.recurring_id}`, { token: u.token, body: { is_active: true } });
    assert.strictEqual(resumed.body.rule.is_active, true);
    assert.ok(resumed.body.rule.next_run_date.slice(0, 10) >= today(), 'resuming moves to today or later');
    assert.strictEqual(await count(), 4, "the week missed while paused is not posted");

    assert.strictEqual((await call('DELETE', `/api/recurring/${rule.rule.recurring_id}`, { token: u.token })).status, 204);
    assert.ok(await count() >= 4, 'deleting the rule keeps its transactions');
  });

  test('TXN-07 rules are checked and private', async () => {
    const u = await newUser('rules-check');
    const other = await newUser('rules-other');
    const bad = [
      [{ frequency: 'daily' }, 'Choose how often it repeats: weekly or monthly.'],
      [{ start_date: '2020-01-01' }, 'The start date must be within a year of today.'],
      [{ amount: 0 }, null],
      [{ account_id: other.cash }, 'Account or category not found.'],
    ];
    for (const [change, message] of bad) {
      const res = await call('POST', '/api/recurring', { token: u.token, body: {
        account_id: u.cash, category_id: u.cat('Food'), amount: 100, frequency: 'weekly', start_date: today(), ...change } });
      assert.ok([400, 404].includes(res.status), JSON.stringify(change));
      if (message) assert.strictEqual(res.body.error, message);
    }
    const mine = (await call('POST', '/api/recurring', { token: u.token, body: {
      account_id: u.cash, category_id: u.cat('Food'), amount: 100, frequency: 'weekly', start_date: today() } })).body.rule;
    assert.strictEqual((await call('GET', '/api/recurring', { token: other.token })).body.length, 0, 'SEC-01 another user sees none');
    assert.strictEqual((await call('PUT', `/api/recurring/${mine.recurring_id}`, { token: other.token, body: { is_active: false } })).status, 404);
    assert.strictEqual((await call('DELETE', `/api/recurring/${mine.recurring_id}`, { token: other.token })).status, 404);
  });
});

describe('too many wrong passwords (SEC-05)', () => {
  const email = 'locked@test.pk';
  before(async () => {
    await adminQuery('DELETE FROM login_attempts');
    await call('POST', '/api/auth/register', { body: { full_name: 'Locked Out', email, password: 'right-password' } });
  });
  after(() => adminQuery('DELETE FROM login_attempts'));

  test('SEC-05 after 5 wrong passwords in 10 minutes, log-in is refused for 10 minutes', async () => {
    for (let i = 1; i <= 5; i++) {
      const wrong = await call('POST', '/api/auth/login', { body: { email, password: 'wrong' + i } });
      assert.strictEqual(wrong.status, 401, `wrong password ${i} gets the normal message`);
    }
    const sixth = await call('POST', '/api/auth/login', { body: { email, password: 'wrong6' } });
    assert.strictEqual(sixth.status, 429);
    assert.strictEqual(sixth.body.error, 'Too many wrong passwords from this computer. Please try again in 10 minutes.');
    const right = await call('POST', '/api/auth/login', { body: { email, password: 'right-password' } });
    assert.strictEqual(right.status, 429, 'even the right password waits, so guessing cannot continue');

    const { rows } = await adminQuery('SELECT COUNT(*)::int AS n, MIN(host(ip_address)) AS ip FROM login_attempts');
    assert.strictEqual(rows[0].n, 5, 'only the 5 checked failures are stored; refused tries are not');
    assert.ok(['127.0.0.1', '::1'].includes(rows[0].ip));
  });

  test('SEC-05 once the 10 minutes have passed, log-in works again', async () => {
    await adminQuery("UPDATE login_attempts SET attempted_at = attempted_at - INTERVAL '11 minutes'");
    const right = await call('POST', '/api/auth/login', { body: { email, password: 'right-password' } });
    assert.strictEqual(right.status, 200);
  });
});
