// Shared by committees.html and committee.html: avatars, tags, the round bar, and the
// "Start a committee" and "Join with a code" pop-ups. The rules themselves live in the database.

const BC_COLOURS = ['#1C2B44', '#2F6FD6', '#3CCB8E', '#F59E0B', '#8B5CF6', '#EC4899', '#0EA5E9', '#14B8A6', '#64748B', '#EF4444'];
const BC_METHODS = {
  draw: { label: 'Lucky draw', short: 'Lucky draw order', icon: 'dice', help: 'FinTrack draws the order once everyone has joined. It\'s recorded and can\'t be redrawn.' },
  fixed: { label: 'I set the order', short: 'Order set by the organizer', icon: 'edit', help: 'You put everyone in order before starting. It can\'t be changed afterwards.' },
  organizer: { label: 'I decide monthly', short: 'Organizer chooses each month', icon: 'calendar', help: 'Each month you choose who gets the pot. Nobody can get it twice.' },
};

/** A round coloured avatar with initials; the same index always gets the same colour. */
const bcInitials = (name) => initials(String(name || '?').replace(/[^\p{L}\s]/gu, ' ').trim() || '?');
const bcAvatar = (name, i, extra = '') => `<span class="ft-av" style="background:${BC_COLOURS[Math.abs(i) % BC_COLOURS.length]};${extra}" title="${esc(name)}">${esc(bcInitials(name))}</span>`;
const bcTag = (text, kind, ic) => `<span class="ft-tag ${kind}">${ic ? icon(ic, 14) : ''}${esc(text)}</span>`;
/** Rounds as a row of pills: green = paid out, blue = now, grey = to come. */
const bcRounds = (done, total, lg = false) => `<div class="ft-rounds ${lg ? 'lg' : ''}" role="img" aria-label="${done} of ${total} rounds paid out">${
  Array.from({ length: total }, (_, r) => `<span class="${r < done ? 'done' : r === done ? 'now' : ''}"></span>`).join('')}</div>`;
const bcStack = (names, total) => `<span class="ft-stack">${names.slice(0, 5).map((n, i) => bcAvatar(n, i)).join('')}${
  total > 5 ? `<span class="ft-av more">+${total - 5}</span>` : ''}</span>`;

/** "2026-11-01" + 3 months → "2027-02-01" */
function bcAddMonths(iso, n) {
  const d = new Date(`${String(iso).slice(0, 10)}T00:00:00`);
  d.setMonth(d.getMonth() + n);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-01`;
}
// month names written out, so every browser shows "Sep" (some write "Sept")
const BC_MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
function bcMonth(iso, long = false) {
  const [y, m] = String(iso).slice(0, 7).split('-').map(Number);
  return `${long ? BC_MONTHS[m - 1] : BC_MONTHS[m - 1].slice(0, 3)} ${y}`;
}
/** "2026-12-05" → "5 Dec 2026"; withYear false → "5 Dec" */
function bcDate(iso, withYear = true) {
  const d = new Date(iso);
  const local = /^\d{4}-\d{2}-\d{2}$/.test(String(iso)) ? new Date(`${iso}T00:00:00`) : d;
  return `${local.getDate()} ${BC_MONTHS[local.getMonth()].slice(0, 3)}${withYear ? ' ' + local.getFullYear() : ''}`;
}
const bcRange = (start, n) => `${bcMonth(start)} – ${bcMonth(bcAddMonths(start, n - 1))}`;
const bcDay = (iso, day) => `${day} ${bcMonth(iso)}`;
const bcIcon = (name) => (/family|ghar|home|ammi|khala|phupp/i.test(name) ? 'home' : /office|work|job|team/i.test(name) ? 'brief' : /eid|gift|wedding|shaadi/i.test(name) ? 'gift' : 'users');

/** The share text for WhatsApp, with a link that opens the join pop-up (after log-in if needed). */
function bcInviteLink(code) {
  return `${location.origin}${location.pathname.replace(/[^/]*$/, '')}committees.html?join=${encodeURIComponent(code)}`;
}
function bcWhatsApp(text) {
  window.open(`https://wa.me/?text=${encodeURIComponent(text)}`, '_blank', 'noopener');
}
async function bcCopy(text, what) {
  try {
    await navigator.clipboard.writeText(text);
    toast(`${what} copied.`);
  } catch {
    toast(`Couldn't copy. The ${what.toLowerCase()} is: ${text}`, 'danger');
  }
}

/** A Bootstrap pop-up with our own body; returns { el, modal, done(value) } and a promise of the value. */
function bcModal(title, body, foot, width = 460) {
  const el = document.createElement('div');
  el.className = 'modal fade';
  el.tabIndex = -1;
  el.innerHTML = `<div class="modal-dialog modal-dialog-centered" style="max-width:${width}px"><form class="modal-content p-2" novalidate>
    <div class="modal-header"><h2 class="modal-title">${esc(title)}</h2><button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Close"></button></div>
    <div class="modal-body pt-0 d-flex flex-column gap-3">${body}</div>
    <div class="modal-footer">${foot}</div></form></div>`;
  document.body.appendChild(el);
  el.querySelectorAll('[data-i]').forEach((x) => { x.outerHTML = icon(x.dataset.i, Number(x.dataset.s || 18)); });
  const modal = new bootstrap.Modal(el);
  let value = null;
  const result = new Promise((resolve) => el.addEventListener('hidden.bs.modal', () => { el.remove(); resolve(value); }));
  el.addEventListener('shown.bs.modal', () => el.querySelector('input:not([type=radio]),select')?.focus());
  modal.show();
  return { el, modal, result, done(v) { value = v; modal.hide(); } };
}

/** "Start a committee": returns the new committee, or null. */
function bcCreateDialog() {
  const next = new Date();
  next.setMonth(next.getMonth() + 1);
  const firstMonth = `${next.getFullYear()}-${String(next.getMonth() + 1).padStart(2, '0')}`;
  const d = bcModal('Start a committee', `
    <div class="ft-field"><label for="bcName">Name</label><input class="ft-input" id="bcName" maxlength="80" placeholder="e.g. Family Committee" required></div>
    <div class="d-grid gap-3" style="grid-template-columns:1fr 1fr">
      <div class="ft-field"><label for="bcAmount">Each person pays (Rs)</label><input class="ft-input fw-semibold" id="bcAmount" inputmode="decimal" placeholder="10,000" autocomplete="off"></div>
      <div class="ft-field"><label for="bcCount">Number of people</label><input class="ft-input fw-semibold" id="bcCount" type="number" min="2" max="50" value="10"></div>
      <div class="ft-field"><label for="bcStart">First month</label><input class="ft-input" id="bcStart" type="month" value="${firstMonth}"></div>
      <div class="ft-field"><label for="bcDue">Pay by (day of month)</label><input class="ft-input" id="bcDue" type="number" min="1" max="28" value="5"></div>
    </div>
    <fieldset class="ft-field m-0"><legend class="lab mb-1" style="font-size:13px;font-weight:500;color:#334155">Who gets the pot first?</legend>
      <div class="ft-choice">${Object.entries(BC_METHODS).map(([k, m], i) => `<label><input type="radio" name="bcMethod" value="${k}" ${i === 0 ? 'checked' : ''}>
        <b>${icon(m.icon, 16)}${esc(m.label)}</b></label>`).join('')}</div>
      <p class="ft-muted mt-1" id="bcMethodHelp">${esc(BC_METHODS.draw.help)}</p></fieldset>
    <div style="border-radius:16px;background:var(--ft-ink);color:#fff;padding:16px;display:flex;justify-content:space-between;gap:12px" aria-live="polite">
      <div><p class="m-0" style="font-size:12px;color:#CBD5E1">Pot each month</p><p class="ft-big" style="color:#fff;font-size:26px;margin-top:4px" id="bcPot">Rs 0</p>
        <p class="m-0 mt-1" style="font-size:12px;color:#CBD5E1" id="bcPotSum"></p></div>
      <div class="text-end"><p class="m-0" style="font-size:12px;color:#CBD5E1" id="bcRuns"></p><p class="m-0 mt-1 fw-semibold" style="font-size:15px;white-space:nowrap" id="bcRange"></p></div>
    </div>
    <p class="text-danger small m-0 d-none" id="bcErr" role="alert"></p>`,
  `<button type="button" class="ft-btn light" data-bs-dismiss="modal">Cancel</button><button class="ft-btn" id="bcGo">Create and invite<span data-i="arrowr"></span></button>`);
  const $ = (id) => d.el.querySelector('#' + id);
  const amount = () => Number(String($('bcAmount').value).replace(/[,\s]/g, '').replace(/^rs/i, ''));
  const update = () => {
    const n = Number($('bcCount').value) || 0;
    $('bcPot').textContent = money((amount() || 0) * n);
    $('bcPotSum').textContent = amount() > 0 && n ? `${money(amount())} × ${n} people, one gets it all` : '';
    $('bcErr').classList.add('d-none');   // the message from the last try goes away as soon as something changes
    $('bcRuns').textContent = n ? `Runs for ${n} months` : '';
    $('bcRange').textContent = n && $('bcStart').value ? bcRange(`${$('bcStart').value}-01`, n) : '';
    $('bcMethodHelp').textContent = BC_METHODS[d.el.querySelector('input[name=bcMethod]:checked').value].help;
  };
  d.el.addEventListener('input', update);
  update();
  d.el.querySelector('form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const err = (m) => { $('bcErr').textContent = m; $('bcErr').classList.remove('d-none'); };
    if (!$('bcName').value.trim()) return err('Give the committee a name.');
    if (!(amount() > 0)) return err('Type how much each person pays.');
    $('bcGo').disabled = true;
    try {
      const c = await api('/committees', { method: 'POST', body: {
        name: $('bcName').value.trim(), amount: amount(), member_count: Number($('bcCount').value), start_month: $('bcStart').value,
        due_day: Number($('bcDue').value), payout_day: Math.min(28, Number($('bcDue').value) + 5),
        payout_method: d.el.querySelector('input[name=bcMethod]:checked').value } });
      d.done(c);
    } catch (ex) {
      err(ex.message);
      $('bcGo').disabled = false;
    }
  });
  return d.result;
}

/** "Join a committee": type a code, see who runs it, then ask to join. Returns the join result, or null. */
function bcJoinDialog(code = '') {
  const d = bcModal('Join a committee', `
    <div class="ft-field"><label for="bcCode">Committee code</label><input class="ft-input ft-code-input" id="bcCode" maxlength="9" placeholder="FAM-7K2Q" autocomplete="off" value="${esc(code)}"></div>
    <div id="bcPreview" aria-live="polite"></div>`,
  `<button type="button" class="ft-btn light" data-bs-dismiss="modal">Cancel</button><button class="ft-btn" id="bcJoin" disabled><span data-i="check"></span>Ask to join</button>`, 440);
  const $ = (id) => d.el.querySelector('#' + id);
  let found = null;
  let timer;
  const look = async () => {
    const value = $('bcCode').value.trim();
    found = null;
    $('bcJoin').disabled = true;
    if (value.length < 8) { $('bcPreview').innerHTML = ''; return; }
    try {
      const c = await api('/committees/code?code=' + encodeURIComponent(value));
      found = c;
      const mine = { approved: 'You are already in this committee.', requested: 'You\'ve asked to join. The organizer will approve you.', invited: 'You\'re invited. Joining accepts the invitation.' }[c.my_status];
      $('bcPreview').innerHTML = `<div style="border-radius:18px;overflow:hidden;border:1px solid var(--ft-line)">
        <div style="height:64px;background:linear-gradient(135deg,var(--ft-brand),var(--ft-accent));display:flex;align-items:center;justify-content:flex-end;padding:0 14px"><span class="ft-save">${icon(bcIcon(c.name), 18)}</span></div>
        <div class="d-flex flex-column gap-2" style="padding:14px 16px">
          <p class="m-0 fw-semibold" style="font-size:16px">${esc(c.name)}</p><p class="ft-muted">Organized by ${esc(c.organizer_name)}</p>
          <div class="d-flex flex-wrap gap-2"><span class="ft-pill">${icon('cash', 14)}${money(c.amount)} a month</span><span class="ft-pill">${icon('users', 14)}${c.approved_count} of ${c.member_count} joined</span>
            <span class="ft-pill">${icon('calendar', 14)}${bcRange(c.start_month, c.member_count)}</span><span class="ft-pill">${icon(BC_METHODS[c.payout_method].icon, 14)}${esc(BC_METHODS[c.payout_method].label.replace('I set', 'Set').replace('I decide', 'Decided'))}</span></div>
          <div class="ft-iconbox">${icon(mine ? 'alert' : 'gift', 17)}<span>${mine ? esc(mine) : `You'd pay ${money(c.amount)} each month, and get ${money(c.amount * c.member_count)} once, on your turn.`}</span></div>
        </div></div>`;
      const member = c.my_status === 'approved';
      $('bcJoin').innerHTML = member ? `${icon('arrowr', 18)}Open it` : `${icon('check', 18)}Ask to join`;
      $('bcJoin').disabled = !member && (c.status !== 'forming' || c.my_status === 'requested');
      if (c.status !== 'forming' && !mine) $('bcPreview').insertAdjacentHTML('beforeend', '<p class="ft-muted mt-2">This committee has already started, so it can\'t take new members.</p>');
    } catch (ex) {
      $('bcPreview').innerHTML = `<p class="text-danger small m-0" role="alert">${esc(ex.message)}</p>`;
    }
  };
  $('bcCode').addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(look, 300); });
  if (code) look();
  d.el.querySelector('form').addEventListener('submit', async (e) => {
    e.preventDefault();
    if (!found) return;
    if (found.my_status === 'approved') return d.done({ committee_id: found.committee_id, name: found.name, status: 'approved' });
    $('bcJoin').disabled = true;
    try {
      d.done(await api('/committees/join', { method: 'POST', body: { code: $('bcCode').value.trim() } }));
    } catch (ex) {
      toast(ex.message, 'danger');
      $('bcJoin').disabled = false;
    }
  });
  return d.result;
}
