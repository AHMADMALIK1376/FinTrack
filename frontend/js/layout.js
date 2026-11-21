// The app shell shared by every logged-in page: sidebar, top bar, Shan's tip card, notifications
// and, on phones, a bottom tab bar. Pages call shell.render(...) once, then shell.refresh() after changes.

const NAV = [
  { href: 'dashboard.html', label: 'Dashboard', icon: 'grid' },
  { href: 'transactions.html', label: 'Transactions', icon: 'swap' },
  { href: 'imports.html', label: 'SMS import', icon: 'message', count: 'imports' },
  { href: 'accounts.html', label: 'Accounts', icon: 'wallet', count: 'accounts' },
  { href: 'budgets.html', label: 'Budgets & goals', icon: 'pie', count: 'warnings' },
  { href: 'committees.html', label: 'Committees', icon: 'users', count: 'committees' },
  { href: 'reports.html', label: 'Reports', icon: 'chart' },
];

const shell = {
  page: '',

  /**
   * @param {string} page   file name of this page, e.g. 'dashboard.html'
   * @param {object} opts   title, sub (text under the title), actions (extra HTML for the top bar)
   */
  render(page, { title, sub, actions = '' }) {
    auth.requireLogin();
    this.page = page;
    const user = auth.user || {};
    const hour = new Date().getHours();
    const greeting = hour < 12 ? 'Good morning' : hour < 17 ? 'Good afternoon' : 'Good evening';

    document.getElementById('sidebar').innerHTML = `
      <a class="ft-brand" href="dashboard.html" aria-label="FinTrack home"><img src="assets/icon.svg" alt=""><span class="ft-wordmark">Fin<span>Track</span></span></a>
      <form class="ft-search" role="search" id="quickSearch">
        ${icon('search', 18)}<input id="quickSearchInput" aria-label="Search transactions" placeholder="Search…" autocomplete="off">
        <span class="ft-kbd" aria-hidden="true">Ctrl K</span>
      </form>
      <p class="ft-sec">Menu</p>
      <nav aria-label="Main">${NAV.map((n) => `<a class="ft-nav-link ${n.href === page ? 'active' : ''}" href="${n.href}" ${n.href === page ? 'aria-current="page"' : ''}>
        ${icon(n.icon, 20)}<span>${esc(n.label)}</span>${n.count ? `<span class="ft-count d-none" data-count="${n.count}"></span>` : ''}</a>`).join('')}</nav>
      <p class="ft-sec">Account</p>
      <button class="ft-nav-link" type="button" onclick="auth.logout()">${icon('logout', 20)}<span>Log out</span></button>
      <div style="flex:1;min-height:24px"></div>
      <div id="shanCard" class="ft-shan-card good" aria-live="polite">
        <div class="d-flex align-items-center gap-2">
          <img src="assets/shan.svg" alt="Shan the Snow Leopard, the FinTrack mascot" width="46" height="55">
          <div><div class="who">SHAN SAYS</div><div class="head" id="shanHead">Checking your budgets…</div></div>
        </div>
        <p id="shanText"></p>
        <a href="budgets.html" id="shanLink" class="d-none">Review budget ${icon('arrowr', 16)}</a>
      </div>`;

    document.getElementById('topbar').innerHTML = `
      <div class="ft-phone-head w-100">
        <img src="assets/shan-wave.svg" alt="Shan the Snow Leopard, waving">
        <div class="flex-grow-1"><p class="ft-muted">${greeting},</p><p class="m-0 fw-semibold" style="font-size:17px">${esc(user.full_name || '')}</p></div>
      </div>
      <div style="min-width:0"><h1>${esc(title)}</h1><p class="sub">${esc(sub)}</p></div>
      <div class="ft-top-actions">
        ${actions}
        <div class="dropdown">
          <button class="ft-iconbtn" id="bellBtn" data-bs-toggle="dropdown" aria-expanded="false" aria-label="Notifications">${icon('bell', 20)}<span class="ft-dot d-none" id="bellDot"></span></button>
          <div class="dropdown-menu dropdown-menu-end" style="width:320px" id="bellMenu"><p class="ft-empty m-0">No notifications.</p></div>
        </div>
        <div class="dropdown">
          <button class="ft-user" data-bs-toggle="dropdown" aria-expanded="false" aria-label="Account menu for ${esc(user.full_name || '')}">
            <span class="ft-avatar">${esc(initials(user.full_name))}</span>
            <span><span class="name">${esc(user.full_name || '')}</span><span class="mail">${esc(user.email || '')}</span></span>
            <span class="chev">${icon('chev', 16)}</span>
          </button>
          <ul class="dropdown-menu dropdown-menu-end">
            <li><a class="dropdown-item" href="accounts.html">${icon('wallet', 18)}My accounts</a></li>
            <li><a class="dropdown-item" href="reports.html">${icon('chart', 18)}Reports</a></li>
            <li><hr class="dropdown-divider"></li>
            <li><button class="dropdown-item" type="button" onclick="auth.logout()">${icon('logout', 18)}Log out</button></li>
          </ul>
        </div>
      </div>`;

    const tabs = [['dashboard.html', 'Home', 'grid'], ['transactions.html', 'Activity', 'swap'], null, ['committees.html', 'Committees', 'users'], ['budgets.html', 'Budgets', 'pie']];
    document.getElementById('tabbar').innerHTML = tabs.map((t) => (t
      ? `<a href="${t[0]}" class="${t[0] === page ? 'active' : ''}" ${t[0] === page ? 'aria-current="page"' : ''}>${icon(t[2], 22)}${t[1]}</a>`
      : `<a href="transactions.html#add" class="add" aria-label="Add transaction">${icon('plus', 26)}</a>`)).join('');

    // quick search: Enter opens Transactions filtered by the text; Ctrl+K jumps to the box
    document.getElementById('quickSearch').addEventListener('submit', (e) => {
      e.preventDefault();
      const q = document.getElementById('quickSearchInput').value.trim();
      location.href = 'transactions.html' + (q ? '?search=' + encodeURIComponent(q) : '');
    });
    document.addEventListener('keydown', (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); document.getElementById('quickSearchInput').focus(); }
    });
    this.refresh();
  },

  /** Updates the menu counts, Shan's tip and the notifications for the current month. */
  async refresh() {
    try {
      const [accounts, report, committees, imports] = await Promise.all([api('/accounts'), api('/reports/dashboard?month=' + thisMonth()),
        api('/committees').catch(() => []), api('/imports?status=pending').catch(() => ({ counts: { pending: 0 } }))]);
      const warnings = report.budget_warnings;
      const bc = committeeNotices(committees);
      const waiting = imports.counts.pending;
      if (waiting) bc.unshift({ href: 'imports.html', icon: 'message', head: `${waiting} SMS to review`, text: 'Check them and add them to your accounts' });
      const counts = { accounts: accounts.length, warnings: warnings.length, committees: bc.length - (waiting ? 1 : 0), imports: waiting };
      document.querySelectorAll('[data-count]').forEach((el) => {
        const n = counts[el.dataset.count];
        el.textContent = n;
        el.classList.toggle('d-none', !n);
      });

      const card = document.getElementById('shanCard');
      const link = document.getElementById('shanLink');
      if (warnings.length) {
        const w = warnings[0];
        card.classList.remove('good');
        document.getElementById('shanHead').innerHTML = `${icon('alert', 16)}${esc(w.category)} is over budget`;
        document.getElementById('shanText').textContent = `You've spent ${money(w.spent)} of your ${money(w.limit_amount)} ${w.category} budget this month.`
          + (warnings.length > 1 ? ` ${warnings.length - 1} more ${warnings.length === 2 ? 'budget is' : 'budgets are'} over too.` : '');
        link.classList.remove('d-none');
      } else {
        card.classList.add('good');
        document.getElementById('shanHead').innerHTML = `${icon('check', 16)}You're on track`;
        document.getElementById('shanText').textContent = Number(report.net_saving) > 0
          ? `You've saved ${money(report.net_saving)} so far this month. Keep it up!`
          : 'No budget is over its limit this month.';
        link.classList.add('d-none');
      }

      const total = warnings.length + bc.length;
      const item = (href, ic, bg, fg, head, text) => `<a class="dropdown-item align-items-start" href="${href}" style="white-space:normal">
            <span class="ft-cat" style="width:34px;height:34px;background:${bg};color:${fg}">${icon(ic, 16)}</span>
            <span><b class="d-block" style="font-size:14px">${head}</b><span class="ft-muted">${text}</span></span></a>`;
      document.getElementById('bellDot').classList.toggle('d-none', !total);
      document.getElementById('bellBtn').setAttribute('aria-label', total ? `Notifications, ${total} new` : 'Notifications');
      document.getElementById('bellMenu').innerHTML = total
        ? (warnings.length ? `<p class="ft-sec mt-1 mb-2">This month</p>` + warnings.map((w) => item('budgets.html', 'alert', 'var(--ft-amber-bg)', 'var(--ft-amber)',
            `${esc(w.category)} is over budget`, `by ${money(w.over_by)} (${money(w.spent)} of ${money(w.limit_amount)})`)).join('') : '')
          + (bc.length ? `<p class="ft-sec mt-2 mb-2">To do</p>` + bc.map((n) => item(n.href, n.icon, '#EAF1FC', 'var(--ft-brand)', n.head, n.text)).join('') : '')
        : '<p class="ft-empty m-0">You\'re all caught up. No budget is over its limit.</p>';
    } catch (e) {
      document.getElementById('shanHead').textContent = 'Shan is resting';
    }
  },

  /** A month picker for the top bar. */
  monthPicker(id = 'month', value = thisMonth()) {
    return `<label class="ft-month">${icon('calendar', 18)}<span class="visually-hidden">Month</span><input type="month" id="${id}" value="${value}" max="2100-12"></label>`;
  },
};

/** Committee things waiting for the user: invitations, people to approve, this round's payment. */
function committeeNotices(list) {
  const out = [];
  for (const c of list) {
    const href = `committee.html?id=${c.committee_id}`;
    if (c.my_status === 'invited') out.push({ href, icon: 'users', head: `Invitation: ${esc(c.name)}`, text: `${esc(c.organizer_name)} invited you · ${money(c.amount)} a month` });
    if (c.requests) out.push({ href, icon: 'users', head: `${c.requests} waiting to join ${esc(c.name)}`, text: 'Approve or remove them' });
    if (c.status === 'active' && c.my_status === 'approved' && !c.my_marked_at) {
      out.push({ href, icon: 'clock', head: `Pay ${money(c.amount)} · ${esc(c.name)}`, text: `Round ${c.current_round}, due by ${c.due_day} ${monthName(String(c.current_month).slice(0, 7)).split(' ')[0]}` });
    }
  }
  return out;
}

/**
 * Gentle 3D tilt for the smaller cards: they lean up to 5 degrees towards the mouse and lift a little.
 * Works for cards added later too (one listener for the whole page). Off on touch screens and when the
 * computer asks for reduced motion.
 */
(function cardTilt() {
  const TILT = '.ft-tilt, .ft-stat, .ft-acct, .ft-goal-mini, article.ft-card';
  const MAX = 5;   // degrees
  if (!matchMedia('(hover: hover) and (pointer: fine)').matches || matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  let current = null;
  const reset = (card) => { if (card) card.style.transform = ''; };
  document.addEventListener('pointermove', (e) => {
    const card = e.target.closest(TILT);
    if (card !== current) { reset(current); current = card; }
    if (!card || card.querySelector('.dropdown-menu.show')) { reset(card); return; }   // keep still while its menu is open
    const r = card.getBoundingClientRect();
    const x = (e.clientX - r.left) / r.width - 0.5;    // -0.5 (left) .. 0.5 (right)
    const y = (e.clientY - r.top) / r.height - 0.5;    // -0.5 (top) .. 0.5 (bottom)
    card.style.transform = `perspective(900px) rotateX(${(-y * MAX).toFixed(2)}deg) rotateY(${(x * MAX).toFixed(2)}deg) translateY(-4px)`;
  }, { passive: true });
  document.addEventListener('pointerleave', () => { reset(current); current = null; });
  document.addEventListener('shown.bs.dropdown', (e) => reset(e.target.closest(TILT)));   // straighten when its menu opens
  window.addEventListener('blur', () => { reset(current); current = null; });
})();

