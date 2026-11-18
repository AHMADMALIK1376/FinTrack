// The app shell shared by every logged-in page: sidebar, top bar, Shan's tip card, notifications
// and, on phones, a bottom tab bar. Pages call shell.render(...) once, then shell.refresh() after changes.

const NAV = [
  { href: 'dashboard.html', label: 'Dashboard', icon: 'grid' },
  { href: 'transactions.html', label: 'Transactions', icon: 'swap' },
  { href: 'accounts.html', label: 'Accounts', icon: 'wallet', count: 'accounts' },
  { href: 'budgets.html', label: 'Budgets & goals', icon: 'pie', count: 'warnings' },
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
            <li><hr class="dropdown-divider"></li>
            <li><button class="dropdown-item" type="button" onclick="auth.logout()">${icon('logout', 18)}Log out</button></li>
          </ul>
        </div>
      </div>`;

    const tabs = [['dashboard.html', 'Home', 'grid'], ['transactions.html', 'Activity', 'swap'], null, ['budgets.html', 'Budgets', 'pie'], ['accounts.html', 'Accounts', 'wallet']];
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
      const [accounts, report] = await Promise.all([api('/accounts'), api('/reports/dashboard?month=' + thisMonth())]);
      const warnings = report.budget_warnings;
      const counts = { accounts: accounts.length, warnings: warnings.length };
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

      document.getElementById('bellDot').classList.toggle('d-none', !warnings.length);
      document.getElementById('bellBtn').setAttribute('aria-label', warnings.length ? `Notifications, ${warnings.length} new` : 'Notifications');
      document.getElementById('bellMenu').innerHTML = warnings.length
        ? `<p class="ft-sec mt-1 mb-2">This month</p>` + warnings.map((w) => `<a class="dropdown-item align-items-start" href="budgets.html" style="white-space:normal">
            <span class="ft-cat" style="width:34px;height:34px;background:var(--ft-amber-bg);color:var(--ft-amber)">${icon('alert', 16)}</span>
            <span><b class="d-block" style="font-size:14px">${esc(w.category)} is over budget</b><span class="ft-muted">by ${money(w.over_by)} (${money(w.spent)} of ${money(w.limit_amount)})</span></span></a>`).join('')
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
