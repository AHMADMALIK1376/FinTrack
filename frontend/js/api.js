// Shared helpers for every page: API calls, login state, navbar, formatting.
const API = '/api';

const auth = {
  get token() { return localStorage.getItem('ft_token'); },
  get user() { try { return JSON.parse(localStorage.getItem('ft_user')); } catch { return null; } },
  save(data) { localStorage.setItem('ft_token', data.token); localStorage.setItem('ft_user', JSON.stringify(data.user)); },
  logout() { localStorage.removeItem('ft_token'); localStorage.removeItem('ft_user'); location.href = 'index.html'; },
  requireLogin() { if (!this.token) location.href = 'index.html'; },
};

async function api(path, { method = 'GET', body } = {}) {
  const res = await fetch(API + path, {
    method,
    headers: { 'Content-Type': 'application/json', ...(auth.token ? { Authorization: `Bearer ${auth.token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (res.status === 401 && auth.token) { auth.logout(); return; }
  if (res.status === 204) return null;
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || 'Request failed');
  return data;
}

const money = (n) => 'Rs ' + Number(n || 0).toLocaleString('en-PK', { maximumFractionDigits: 0 });
const thisMonth = () => new Date().toISOString().slice(0, 7);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function toast(message, type = 'success') {
  let box = document.getElementById('toastBox');
  if (!box) {
    box = document.createElement('div');
    box.id = 'toastBox';
    box.className = 'toast-container position-fixed bottom-0 end-0 p-3';
    document.body.appendChild(box);
  }
  const el = document.createElement('div');
  el.className = `toast align-items-center text-bg-${type} border-0`;
  el.innerHTML = `<div class="d-flex"><div class="toast-body">${esc(message)}</div>
    <button type="button" class="btn-close btn-close-white me-2 m-auto" data-bs-dismiss="toast"></button></div>`;
  box.appendChild(el);
  new bootstrap.Toast(el, { delay: 3000 }).show();
}

function renderNavbar(active) {
  const links = [
    ['dashboard.html', 'Dashboard', 'speedometer2'],
    ['transactions.html', 'Transactions', 'arrow-left-right'],
    ['accounts.html', 'Accounts', 'wallet2'],
    ['budgets.html', 'Budgets & Goals', 'piggy-bank'],
  ];
  document.getElementById('navbar').innerHTML = `
  <nav class="navbar navbar-expand-lg ft-nav sticky-top">
    <div class="container">
      <a class="navbar-brand d-flex align-items-center gap-2" href="dashboard.html">
        <img src="assets/icon.svg" width="36" height="36" alt=""><span>Fin<span style="color:var(--ft-blue)">Track</span></span>
      </a>
      <button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#nav"><span class="navbar-toggler-icon"></span></button>
      <div class="collapse navbar-collapse" id="nav">
        <ul class="navbar-nav mx-auto gap-1">
          ${links.map(([href, label, icon]) => `<li class="nav-item"><a class="nav-link ${active === href ? 'active' : ''}" href="${href}">
            <i class="bi bi-${icon} me-1"></i>${label}</a></li>`).join('')}
        </ul>
        <div class="d-flex align-items-center gap-3">
          <span class="text-muted-ft small"><i class="bi bi-person-circle me-1"></i>${esc(auth.user?.full_name)}</span>
          <button class="btn btn-outline-secondary btn-sm" onclick="auth.logout()">Log out</button>
        </div>
      </div>
    </div>
  </nav>`;
}
