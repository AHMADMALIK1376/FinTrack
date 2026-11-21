// API tests for SMS import (IM-01 - IM-07): forwarding with a private key, reading messages,
// skipping codes and non-payments, catching duplicates, adding once, remembering choices, privacy.
const { test, describe, before, after } = require('node:test');
const assert = require('node:assert');
const { resetDatabase, startPhpServer } = require('./setup');

let server;
let baseUrl;

async function call(method, path, { token, body, raw, type } = {}) {
  const res = await fetch(baseUrl + path, {
    method,
    headers: { 'Content-Type': type || 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: raw !== undefined ? raw : body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null };
}

async function newUser(name) {
  const email = `${name.toLowerCase().replace(/\W/g, '')}@sms.test.pk`;
  const reg = await call('POST', '/api/auth/register', { body: { full_name: name, email, password: 'secret123' } });
  assert.strictEqual(reg.status, 201, JSON.stringify(reg.body));
  return { token: reg.body.token };
}

const ok = (res, status) => assert.strictEqual(res.status, status, JSON.stringify(res.body));
const inbox = async (u, status = 'pending') => (await call('GET', `/api/imports?status=${status}`, { token: u.token })).body;

before(async () => {
  await resetDatabase();
  server = await startPhpServer();
  baseUrl = server.baseUrl;
});

after(() => {
  if (server) server.stop();
});

describe('SMS import', () => {
  let amna; let other; let key; let jazz; let food; let salary;

  before(async () => {
    amna = await newUser('Amna Butt');
    other = await newUser('Other Person');
    jazz = (await call('POST', '/api/accounts', { token: amna.token, body: { account_name: 'JazzCash', account_type: 'wallet' } })).body.account_id;
    const cats = (await call('GET', '/api/categories', { token: amna.token })).body;
    food = cats.find((c) => c.name === 'Food' && c.type === 'expense')?.category_id
      ?? (await call('POST', '/api/categories', { token: amna.token, body: { name: 'Food', type: 'expense' } })).body.category_id;
    salary = cats.find((c) => c.type === 'income')?.category_id
      ?? (await call('POST', '/api/categories', { token: amna.token, body: { name: 'Salary', type: 'income' } })).body.category_id;
  });

  test('IM-06 the forwarding key: made on request, shown once, only works while it is current', async () => {
    assert.strictEqual((await call('GET', '/api/sms/key', { token: amna.token })).body.active, false);
    const made = await call('POST', '/api/sms/key', { token: amna.token });
    ok(made, 201);
    key = made.body.key;
    assert.ok(key.length >= 40);
    const info = (await call('GET', '/api/sms/key', { token: amna.token })).body;
    assert.strictEqual(info.active, true);
    assert.strictEqual(info.key, undefined, 'the key is never shown again');
    assert.strictEqual((await call('POST', `/api/sms/${'x'.repeat(43)}`, { body: { from: 'JazzCash', text: 'Rs 5 sent to X' } })).status, 404);
  });

  test('IM-01 a forwarded JazzCash SMS is read and waits in the inbox', async () => {
    const res = await call('POST', `/api/sms/${key}`, { body: {
      from: 'JazzCash', text: 'You have received Rs 1,500.00 from ALI RAZA 03001234567 on 20-Nov-26 at 14:05. TID: 012345678901. New balance: Rs 3,200.50' } });
    ok(res, 200);
    assert.strictEqual(res.body.saved, true);
    const [m] = (await inbox(amna)).items;
    assert.strictEqual(m.provider, 'JazzCash');
    assert.strictEqual(m.direction, 'in');
    assert.strictEqual(Number(m.amount), 1500);
    assert.strictEqual(m.counterparty, 'Ali Raza');
    assert.strictEqual(m.reference, '012345678901');
    assert.strictEqual(m.txn_date, '2026-11-20');
    assert.strictEqual(m.suggested_account_id, jazz, 'IM-05 suggests the account named after the provider');
    // nothing is added until the user says so (IM-04)
    assert.strictEqual((await call('GET', '/api/transactions', { token: amna.token })).body.length, 0);
  });

  test('IM-01 forms and plain text from other forwarding apps work too', async () => {
    const form = await call('POST', `/api/sms/${key}`, { type: 'application/x-www-form-urlencoded',
      raw: new URLSearchParams({ sender: 'HBL', message: 'Your HBL Debit Card ending 1234 was used for PKR 2,450.00 at FOODPANDA on 21-Nov-2026. Avl Bal PKR 45,210.00' }).toString() });
    assert.strictEqual(form.body.saved, true);
    const plain = await call('POST', `/api/sms/${key}`, { type: 'text/plain', raw: 'Rs. 2,000.00 received from AHMED KHAN in your Easypaisa account. Trx ID 12345678901.' });
    assert.strictEqual(plain.body.saved, true);
    const items = (await inbox(amna)).items;
    const hbl = items.find((m) => m.provider === 'HBL');
    assert.strictEqual(hbl.counterparty, 'Foodpanda');
    assert.strictEqual(hbl.suggested_category_id, food, 'IM-05 Foodpanda suggests Food');
    assert.ok(items.some((m) => m.provider === 'Easypaisa' && m.direction === 'in'));
  });

  test('IM-07 codes, adverts and personal messages are never stored', async () => {
    for (const text of ['Your OTP for transaction of Rs 5,000 is 123456. Do not share.', 'Get 10GB for just Rs 500! Dial *6464#', 'Beta khana kha liya?']) {
      const res = await call('POST', `/api/sms/${key}`, { body: { from: 'X', text } });
      ok(res, 200);
      assert.strictEqual(res.body.saved, false, text);
    }
    assert.strictEqual((await inbox(amna, 'all')).items.length, 3);
  });

  test('IM-03 the same SMS twice is kept once; the same transaction ID is a duplicate', async () => {
    const text = 'You have received Rs 1,500.00 from ALI RAZA 03001234567 on 20-Nov-26 at 14:05. TID: 012345678901. New balance: Rs 3,200.50';
    const again = await call('POST', `/api/sms/${key}`, { body: { from: 'JazzCash', text } });
    assert.strictEqual(again.body.saved, false);
    const reminder = await call('POST', `/api/sms/${key}`, { body: { from: 'JazzCash', text: 'Reminder: Rs 1,500 received from Ali Raza. TID 012345678901' } });
    assert.strictEqual(reminder.body.status, 'duplicate');
    const counts = (await inbox(amna)).counts;
    assert.strictEqual(counts.pending, 3);
    assert.strictEqual(counts.duplicates, 1);
  });

  test('IM-04 adding makes one transaction, checks the category type, and can\'t happen twice', async () => {
    const m = (await inbox(amna)).items.find((x) => x.provider === 'JazzCash');
    const wrongType = await call('POST', `/api/imports/${m.import_id}/add`, { token: amna.token, body: { account_id: jazz, category_id: food } });
    ok(wrongType, 400);
    assert.match(wrongType.body.error, /income category/);
    // two clicks at the same moment: one wins, the other is told it's already added
    const [a, b] = await Promise.all([1, 2].map(() => call('POST', `/api/imports/${m.import_id}/add`, { token: amna.token, body: { account_id: jazz, category_id: salary } })));
    assert.deepStrictEqual([a.status, b.status].sort(), [201, 400]);
    const txns = (await call('GET', '/api/transactions', { token: amna.token })).body;
    assert.strictEqual(txns.length, 1);
    assert.strictEqual(Number(txns[0].amount), 1500);
    assert.strictEqual(txns[0].description, 'JazzCash · Ali Raza');
    const added = (await inbox(amna, 'added')).items[0];
    assert.strictEqual(added.account_name, 'JazzCash');
  });

  test('IM-05 choices are remembered for the next message from the same person', async () => {
    const res = await call('POST', '/api/imports/test', { token: amna.token, body: { sender: '8558', text: 'Rs 900 received from Ali Raza on 21/11/2026. TID 5556667778' } });
    ok(res, 201);
    const m = (await inbox(amna)).items.find((x) => x.import_id === res.body.import_id);
    assert.strictEqual(m.suggested_category_id, salary);
    assert.strictEqual(m.suggested_account_id, jazz);
  });

  test('IM-03 a payment already typed in by hand is pointed out', async () => {
    await call('POST', '/api/transactions', { token: amna.token, body: { account_id: jazz, category_id: food, amount: 2450, txn_date: '2026-11-21', description: 'Dinner' } });
    const hbl = (await inbox(amna)).items.find((x) => x.provider === 'HBL');
    assert.strictEqual(hbl.maybe_same.description, 'Dinner');
  });

  test('ignore, back to the inbox, and delete', async () => {
    const m = (await inbox(amna)).items.find((x) => x.provider === 'Easypaisa');
    ok(await call('POST', `/api/imports/${m.import_id}/ignore`, { token: amna.token }), 204);
    assert.strictEqual((await inbox(amna, 'ignored')).items.length, 1);
    ok(await call('POST', `/api/imports/${m.import_id}/restore`, { token: amna.token }), 204);
    ok(await call('DELETE', `/api/imports/${m.import_id}`, { token: amna.token }), 204);
    assert.ok(!(await inbox(amna, 'all')).items.some((x) => x.import_id === m.import_id));
    const added = (await inbox(amna, 'added')).items[0];
    ok(await call('POST', `/api/imports/${added.import_id}/ignore`, { token: amna.token }), 400);
  });

  test('SEC-01 nobody else sees or changes your messages; an old key stops working', async () => {
    const mine = (await inbox(amna, 'all')).items[0];
    assert.deepStrictEqual((await inbox(other, 'all')).items, []);
    ok(await call('POST', `/api/imports/${mine.import_id}/ignore`, { token: other.token }), 404);
    ok(await call('POST', `/api/imports/${mine.import_id}/add`, { token: other.token, body: { account_id: jazz, category_id: food } }), 404);
    const fresh = (await call('POST', '/api/sms/key', { token: amna.token })).body.key;
    ok(await call('POST', `/api/sms/${key}`, { body: { from: 'JazzCash', text: 'Rs 10 sent to X. TID 1231231231' } }), 404);
    ok(await call('POST', `/api/sms/${fresh}`, { body: { from: 'JazzCash', text: 'Rs 10 sent to Y Shop. TID 1231231232' } }), 200);
    ok(await call('DELETE', '/api/sms/key', { token: amna.token }), 204);
    ok(await call('POST', `/api/sms/${fresh}`, { body: { from: 'JazzCash', text: 'Rs 10 sent to Z. TID 1231231233' } }), 404);
  });
});
