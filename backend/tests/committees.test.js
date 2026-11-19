// API tests for committees (BC-01 - BC-08): a whole committee from start to finish over HTTP,
// plus who may do what, and that people outside a committee can't see it (SEC-01).
const { test, describe, before, after } = require('node:test');
const assert = require('node:assert');
const { resetDatabase, startPhpServer } = require('./setup');

let server;
let baseUrl;

async function call(method, path, { token, body } = {}) {
  const res = await fetch(baseUrl + path, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null };
}

async function newUser(name) {
  const email = `${name.toLowerCase().replace(/\W/g, '')}@bc.test.pk`;
  const reg = await call('POST', '/api/auth/register', { body: { full_name: name, email, password: 'secret123' } });
  assert.strictEqual(reg.status, 201, JSON.stringify(reg.body));
  const token = reg.body.token;
  const accounts = (await call('GET', '/api/accounts', { token })).body;
  return { token, name, email, cash: accounts[0].account_id };
}

const ok = (res, status = 204) => assert.strictEqual(res.status, status, JSON.stringify(res.body));

before(async () => {
  await resetDatabase();
  server = await startPhpServer();
  baseUrl = server.baseUrl;
});

after(() => {
  if (server) server.stop();
});

describe('committees', () => {
  let sara; let ali; let zara; let outsider;
  let committee; let detail;

  before(async () => {
    sara = await newUser('Sara Malik');
    ali = await newUser('Ali Raza');
    zara = await newUser('Zara Shah');
    outsider = await newUser('Out Sider');
  });

  test('BC-01 the creator becomes the organizer; amounts and sizes are checked', async () => {
    const bad = await call('POST', '/api/committees', { token: sara.token, body: { name: 'X', amount: 0, member_count: 3, start_month: '2026-11' } });
    assert.strictEqual(bad.status, 400);
    const tooMany = await call('POST', '/api/committees', { token: sara.token, body: { name: 'X', amount: 100, member_count: 80, start_month: '2026-11' } });
    assert.strictEqual(tooMany.status, 400);

    const res = await call('POST', '/api/committees', {
      token: sara.token, body: { name: 'Family Committee', amount: 1000, member_count: 4, start_month: '2026-11', payout_method: 'draw' } });
    ok(res, 201);
    committee = res.body;
    assert.match(committee.invite_code, /^FAM-[A-Z2-9]{4}$/);
    const list = (await call('GET', '/api/committees', { token: sara.token })).body;
    assert.strictEqual(list.length, 1);
    assert.strictEqual(list[0].is_organizer, true);
    assert.strictEqual(list[0].approved_count, 1);
  });

  test('BC-02 join with a code (organizer approves), by invitation, or as a guest', async () => {
    const id = committee.committee_id;
    const preview = await call('GET', `/api/committees/code?code=${committee.invite_code.toLowerCase()}`, { token: ali.token });
    ok(preview, 200);
    assert.strictEqual(preview.body.organizer_name, 'Sara Malik');
    assert.strictEqual((await call('GET', '/api/committees/code?code=NOPE-0000', { token: ali.token })).status, 404);

    const join = await call('POST', '/api/committees/join', { token: ali.token, body: { code: committee.invite_code } });
    ok(join, 201);
    assert.strictEqual(join.body.status, 'requested');
    assert.strictEqual((await call('POST', '/api/committees/join', { token: ali.token, body: { code: committee.invite_code } })).status, 409);

    // a member who is only waiting sees the basics, not payments, history or the code
    const waiting = (await call('GET', `/api/committees/${id}`, { token: ali.token })).body;
    assert.strictEqual(waiting.me.status, 'requested');
    assert.deepStrictEqual(waiting.events, []);
    assert.strictEqual(waiting.committee.invite_code, undefined);

    // only the organizer approves
    const aliMember = (await call('GET', `/api/committees/${id}`, { token: sara.token })).body.members.find((m) => m.display_name === 'Ali Raza');
    assert.strictEqual((await call('POST', `/api/committees/${id}/members/${aliMember.member_id}/approve`, { token: ali.token })).status, 403);
    ok(await call('POST', `/api/committees/${id}/members/${aliMember.member_id}/approve`, { token: sara.token }));

    // invite by e-mail; an unknown e-mail gets a plain message
    assert.strictEqual((await call('POST', `/api/committees/${id}/invite`, { token: sara.token, body: { email: 'nobody@x.pk' } })).status, 404);
    ok(await call('POST', `/api/committees/${id}/invite`, { token: sara.token, body: { email: zara.email.toUpperCase() } }), 201);
    const invited = (await call('GET', '/api/committees', { token: zara.token })).body;
    assert.strictEqual(invited[0].my_status, 'invited');
    ok(await call('POST', `/api/committees/${id}/accept`, { token: zara.token }));

    ok(await call('POST', `/api/committees/${id}/guests`, { token: sara.token, body: { display_name: 'Khala Shabana' } }), 201);
    assert.strictEqual((await call('POST', `/api/committees/${id}/guests`, { token: ali.token, body: { display_name: 'X' } })).status, 403);
  });

  test('BC-01 a full committee refuses more members', async () => {
    const id = committee.committee_id;
    const res = await call('POST', `/api/committees/${id}/guests`, { token: sara.token, body: { display_name: 'One Too Many' } });
    assert.strictEqual(res.status, 400);
    assert.match(res.body.error, /full/);
  });

  test('SEC-01 people outside a committee get "not found" for everything', async () => {
    const id = committee.committee_id;
    assert.strictEqual((await call('GET', `/api/committees/${id}`, { token: outsider.token })).status, 404);
    assert.strictEqual((await call('POST', `/api/committees/${id}/start`, { token: outsider.token })).status, 404);
    assert.strictEqual((await call('PUT', `/api/committees/${id}/link`, { token: outsider.token, body: { account_id: outsider.cash } })).status, 404);
    assert.deepStrictEqual((await call('GET', '/api/committees', { token: outsider.token })).body, []);
    // and a member can't link someone else's account
    assert.strictEqual((await call('PUT', `/api/committees/${id}/link`, { token: ali.token, body: { account_id: outsider.cash } })).status, 404);
  });

  test('BC-03 the organizer starts it: the order is drawn once, one round per month', async () => {
    const id = committee.committee_id;
    assert.strictEqual((await call('POST', `/api/committees/${id}/start`, { token: ali.token })).status, 403);
    const res = await call('POST', `/api/committees/${id}/start`, { token: sara.token });
    ok(res, 200);
    detail = res.body;
    assert.strictEqual(detail.committee.status, 'active');
    assert.deepStrictEqual(detail.members.map((m) => m.turn_no), [1, 2, 3, 4]);
    assert.deepStrictEqual(detail.rounds.map((r) => r.month), ['2026-11-01', '2026-12-01', '2027-01-01', '2027-02-01']);
    const again = await call('POST', `/api/committees/${id}/start`, { token: sara.token });
    assert.strictEqual(again.status, 400);
    assert.match(again.body.error, /already started/);
    // nobody can join or leave any more
    assert.strictEqual((await call('POST', '/api/committees/join', { token: outsider.token, body: { code: committee.invite_code } })).status, 400);
  });

  test('BC-04 BC-07 pay, confirm and pay out; linked accounts get "Committee" transactions', async () => {
    const id = committee.committee_id;
    const round = detail.rounds[0];
    ok(await call('PUT', `/api/committees/${id}/link`, { token: ali.token, body: { account_id: ali.cash } }));

    ok(await call('POST', `/api/committees/${id}/rounds/${round.round_id}/paid`, { token: ali.token }));
    assert.strictEqual((await call('POST', `/api/committees/${id}/rounds/${round.round_id}/paid`, { token: ali.token })).status, 409);
    const aliTxns = (await call('GET', '/api/transactions', { token: ali.token })).body;
    assert.strictEqual(aliTxns.length, 1);
    assert.strictEqual(aliTxns[0].category, 'Committee');
    assert.strictEqual(Number(aliTxns[0].amount), 1000);
    assert.strictEqual(aliTxns[0].type, 'expense');

    // members can't confirm or pay out; a later round can't be paid yet
    const members = detail.members;
    const ofName = (n) => members.find((m) => m.display_name === n).member_id;
    assert.strictEqual((await call('POST', `/api/committees/${id}/rounds/${round.round_id}/confirm`, { token: ali.token, body: { member_id: ofName('Ali Raza') } })).status, 403);
    assert.strictEqual((await call('POST', `/api/committees/${id}/rounds/${detail.rounds[1].round_id}/paid`, { token: zara.token })).status, 400);

    // no payout until everyone is confirmed
    const early = await call('POST', `/api/committees/${id}/rounds/${round.round_id}/payout`, { token: sara.token });
    assert.strictEqual(early.status, 400);
    assert.match(early.body.error, /Not everyone has paid yet: 4/);

    for (const name of ['Ali Raza', 'Zara Shah', 'Khala Shabana', 'Sara Malik']) {
      ok(await call('POST', `/api/committees/${id}/rounds/${round.round_id}/confirm`, { token: sara.token, body: { member_id: ofName(name) } }));
    }
    assert.strictEqual((await call('POST', `/api/committees/${id}/rounds/${round.round_id}/confirm`, { token: sara.token, body: { member_id: ofName('Ali Raza') } })).status, 409);

    ok(await call('POST', `/api/committees/${id}/rounds/${round.round_id}/payout`, { token: sara.token }));
    const after = (await call('GET', `/api/committees/${id}`, { token: ali.token })).body;
    assert.ok(after.rounds[0].paid_out_at);
    assert.strictEqual(after.rounds[0].confirmed, 4);
    assert.strictEqual(Number(after.rounds[0].collected), 4000);
    assert.ok(after.events.some((e) => /paid out Rs 4,000/.test(e.message)));

    // the paid-out round is closed now
    assert.strictEqual((await call('POST', `/api/committees/${id}/rounds/${round.round_id}/payout`, { token: sara.token })).status, 400);

    // if Ali received round 1, his account got the pot as income
    if (after.rounds[0].receiver_name === 'Ali Raza') {
      const income = (await call('GET', '/api/transactions?type=income', { token: ali.token })).body;
      assert.strictEqual(Number(income[0].amount), 4000);
    }
    const list = (await call('GET', '/api/committees', { token: ali.token })).body[0];
    assert.strictEqual(list.current_round, 2);
    assert.strictEqual(list.rounds_done, 1);
    assert.strictEqual(Number(list.my_paid_in), 1000);
  });

  test('BC-04 the last payout finishes the committee', async () => {
    const id = committee.committee_id;
    for (const round of detail.rounds.slice(1)) {
      for (const m of detail.members) {
        ok(await call('POST', `/api/committees/${id}/rounds/${round.round_id}/confirm`, { token: sara.token, body: { member_id: m.member_id } }));
      }
      ok(await call('POST', `/api/committees/${id}/rounds/${round.round_id}/payout`, { token: sara.token }));
    }
    const done = (await call('GET', `/api/committees/${id}`, { token: sara.token })).body;
    assert.strictEqual(done.committee.status, 'finished');
    assert.strictEqual(new Set(done.rounds.map((r) => r.receiver_member_id)).size, 4);
  });

  test('BC-03 fixed order and "organizer chooses"; leaving before the start', async () => {
    const fixed = (await call('POST', '/api/committees', {
      token: ali.token, body: { name: 'Office BC', amount: 500, member_count: 2, start_month: '2027-01', payout_method: 'fixed' } })).body;
    const join = await call('POST', '/api/committees/join', { token: zara.token, body: { code: fixed.invite_code } });
    ok(join, 201);
    let d = (await call('GET', `/api/committees/${fixed.committee_id}`, { token: ali.token })).body;
    const zaraId = d.members.find((m) => m.display_name === 'Zara Shah').member_id;
    const aliId = d.members.find((m) => m.display_name === 'Ali Raza').member_id;

    // Zara cancels her request, then asks again and is approved
    ok(await call('DELETE', `/api/committees/${fixed.committee_id}/members/${zaraId}`, { token: zara.token }));
    ok(await call('POST', '/api/committees/join', { token: zara.token, body: { code: fixed.invite_code } }), 201);
    d = (await call('GET', `/api/committees/${fixed.committee_id}`, { token: ali.token })).body;
    const zaraId2 = d.members.find((m) => m.display_name === 'Zara Shah').member_id;
    ok(await call('POST', `/api/committees/${fixed.committee_id}/members/${zaraId2}/approve`, { token: ali.token }));

    // the organizer can't leave; a fixed order must list everyone
    assert.strictEqual((await call('DELETE', `/api/committees/${fixed.committee_id}/members/${aliId}`, { token: ali.token })).status, 400);
    assert.strictEqual((await call('POST', `/api/committees/${fixed.committee_id}/start`, { token: ali.token, body: { order: [aliId] } })).status, 400);
    assert.strictEqual((await call('POST', `/api/committees/${fixed.committee_id}/start`, { token: ali.token, body: { order: 'x' } })).status, 400);
    const started = await call('POST', `/api/committees/${fixed.committee_id}/start`, { token: ali.token, body: { order: [zaraId2, aliId] } });
    ok(started, 200);
    assert.strictEqual(started.body.rounds[0].receiver_name, 'Zara Shah');

    // organizer chooses each month: the receiver is required, and can't receive twice
    const choose = (await call('POST', '/api/committees', {
      token: zara.token, body: { name: 'Eid BC', amount: 300, member_count: 2, start_month: '2027-01', payout_method: 'organizer' } })).body;
    ok(await call('POST', `/api/committees/${choose.committee_id}/guests`, { token: zara.token, body: { display_name: 'Nani' } }), 201);
    const s = (await call('POST', `/api/committees/${choose.committee_id}/start`, { token: zara.token })).body;
    assert.strictEqual(s.rounds[0].receiver_member_id, null);
    for (const m of s.members) {
      ok(await call('POST', `/api/committees/${choose.committee_id}/rounds/${s.rounds[0].round_id}/confirm`, { token: zara.token, body: { member_id: m.member_id } }));
    }
    const none = await call('POST', `/api/committees/${choose.committee_id}/rounds/${s.rounds[0].round_id}/payout`, { token: zara.token });
    assert.strictEqual(none.status, 400);
    const nani = s.members.find((m) => m.display_name === 'Nani').member_id;
    ok(await call('POST', `/api/committees/${choose.committee_id}/rounds/${s.rounds[0].round_id}/payout`, { token: zara.token, body: { receiver_member_id: nani } }));
    for (const m of s.members) {
      ok(await call('POST', `/api/committees/${choose.committee_id}/rounds/${s.rounds[1].round_id}/confirm`, { token: zara.token, body: { member_id: m.member_id } }));
    }
    const twice = await call('POST', `/api/committees/${choose.committee_id}/rounds/${s.rounds[1].round_id}/payout`, { token: zara.token, body: { receiver_member_id: nani } });
    assert.strictEqual(twice.status, 409);
    assert.match(twice.body.error, /already had their turn/);
  });

  test('BC-01 only the organizer can delete, and only before the start', async () => {
    const c = (await call('POST', '/api/committees', {
      token: sara.token, body: { name: 'Short Lived', amount: 100, member_count: 2, start_month: '2027-03' } })).body;
    ok(await call('POST', '/api/committees/join', { token: ali.token, body: { code: c.invite_code } }), 201);
    assert.strictEqual((await call('DELETE', `/api/committees/${c.committee_id}`, { token: ali.token })).status, 403);
    ok(await call('DELETE', `/api/committees/${c.committee_id}`, { token: sara.token }));
    assert.strictEqual((await call('DELETE', `/api/committees/${committee.committee_id}`, { token: sara.token })).status, 400);
  });
});
