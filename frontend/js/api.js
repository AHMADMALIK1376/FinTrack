// Shared helpers for every page: API calls, login state, formatting, toasts and confirm pop-ups.
const API = '/api';

/** Login state. "Keep me logged in" stores the token in localStorage; otherwise only for this browser tab. */
const auth = {
  store() { return localStorage.getItem('ft_token') ? localStorage : sessionStorage; },
  get token() { return localStorage.getItem('ft_token') || sessionStorage.getItem('ft_token'); },
  get user() { try { return JSON.parse(this.store().getItem('ft_user')); } catch { return null; } },
  save(data, remember = true) {
    const s = remember ? localStorage : sessionStorage;
    s.setItem('ft_token', data.token);
    s.setItem('ft_user', JSON.stringify(data.user));
  },
  clear() { [localStorage, sessionStorage].forEach((s) => { s.removeItem('ft_token'); s.removeItem('ft_user'); }); },
  logout() { this.clear(); location.href = 'index.html'; },
  requireLogin() {
    if (this.token) return;
    const here = location.pathname.split('/').pop() + location.search;   // e.g. committees.html?join=FAM-7K2Q
    location.replace(here && !here.startsWith('dashboard.html') ? 'index.html?next=' + encodeURIComponent(here) : 'index.html');
  },
  /** Where to go after log-in: the page from ?next= if it is one of ours (never another site), else the dashboard. */
  nextPage() {
    const next = new URLSearchParams(location.search).get('next') || '';
    return /^[a-z]+\.html(\?[\w=&%.-]*)?$/.test(next) ? next : 'dashboard.html';
  },
};

/** Calls the PHP API. Throws an Error with the server's plain-English message when something is refused. */
async function api(path, { method = 'GET', body } = {}) {
  const res = await fetch(API + path, {
    method,
    headers: { 'Content-Type': 'application/json', ...(auth.token ? { Authorization: `Bearer ${auth.token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (res.status === 401 && auth.token) { auth.logout(); return new Promise(() => {}); }
  if (res.status === 204) return null;
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || 'Something went wrong. Please try again.');
  return data;
}

// ---------- formatting ----------
const fmt = (n, digits = 0) => Number(n || 0).toLocaleString('en-PK', { minimumFractionDigits: digits, maximumFractionDigits: digits });
/** "Rs 87,500" */
const money = (n) => 'Rs ' + fmt(Math.round(Number(n || 0)));
/** "Rs 120K", "Rs 1.2M" for small spaces */
const moneyShort = (n) => {
  const v = Math.abs(Number(n || 0));
  if (v >= 1e6) return `Rs ${+(v / 1e6).toFixed(1)}M`;
  if (v >= 1e3) return `Rs ${+(v / 1e3).toFixed(v >= 1e5 ? 0 : 1)}K`;
  return `Rs ${fmt(v)}`;
};
/** Big number with grey decimals, as in the designs: Rs 87,500<span>.00</span> */
const moneyBig = (n) => {
  const [whole, dec] = fmt(Math.abs(Number(n || 0)), 2).split('.');
  return `${Number(n) < 0 ? '−' : ''}Rs ${whole}<span class="dec">.${dec}</span>`;
};
const signed = (t) => `${t.type === 'income' ? '+' : '−'}${money(t.amount)}`;
const thisMonth = () => { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`; };
const today = () => { const d = new Date(); return `${thisMonth()}-${String(d.getDate()).padStart(2, '0')}`; };
const monthName = (ym) => new Date(`${ym}-01T00:00:00`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric' });
const prevMonth = (ym) => { const d = new Date(`${ym}-01T00:00:00`); d.setMonth(d.getMonth() - 1); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`; };
const dateLabel = (iso) => new Date(`${String(iso).slice(0, 10)}T00:00:00`).toLocaleDateString('en-US', { month: 'short', day: '2-digit', year: 'numeric' });
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const initials = (name) => String(name || '?').trim().split(/\s+/).slice(0, 2).map((w) => w[0]).join('').toUpperCase();
const pct = (part, whole) => (Number(whole) > 0 ? Math.round((Number(part) / Number(whole)) * 100) : 0);
/** Days left in a month (counting today) and how much of the month has passed, for the current month only. */
function monthProgress(ym) {
  const now = new Date();
  const [y, m] = ym.split('-').map(Number);
  const days = new Date(y, m, 0).getDate();
  if (ym !== thisMonth()) return { daysLeft: 0, used: ym < thisMonth() ? 100 : 0, days };
  return { daysLeft: days - now.getDate() + 1, used: Math.round(((now.getDate() - 1) / days) * 100), days };
}

// ---------- icons for categories and accounts ----------
const CATEGORY_ICONS = {
  salary: 'brief', freelance: 'laptop', 'opening balance': 'wallet', 'other income': 'plus', food: 'food', groceries: 'food',
  rent: 'home', transport: 'car', fuel: 'car', bills: 'bolt', shopping: 'bag', health: 'heart', transfer: 'swap', education: 'brief',
};
const catIcon = (name) => CATEGORY_ICONS[String(name || '').toLowerCase()] || 'pie';
const ACCOUNT_ICONS = { bank: 'bank', cash: 'cash', wallet: 'phone', card: 'card' };
const accIcon = (type) => ACCOUNT_ICONS[type] || 'wallet';
const ACCOUNT_TYPES = { bank: 'Bank', cash: 'Cash', wallet: 'Wallet', card: 'Card' };

// ---------- toasts and confirm pop-ups (Bootstrap) ----------
function toast(message, type = 'success') {
  let box = document.getElementById('toastBox');
  if (!box) {
    box = document.createElement('div');
    box.id = 'toastBox';
    box.className = 'toast-container position-fixed top-0 start-50 translate-middle-x p-3';   // top centre: never covers a button
    box.style.zIndex = 2000;
    box.setAttribute('aria-live', 'polite');
    document.body.appendChild(box);
  }
  const colour = { success: 'text-bg-dark', danger: 'text-bg-danger', warning: 'text-bg-warning' }[type] || 'text-bg-dark';
  const el = document.createElement('div');
  el.className = `toast align-items-center border-0 ${colour}`;
  el.setAttribute('role', type === 'danger' ? 'alert' : 'status');
  el.innerHTML = `<div class="d-flex"><div class="toast-body d-flex align-items-center gap-2">${icon(type === 'danger' ? 'alert' : 'check', 18)}${esc(message)}</div>
    <button type="button" class="btn-close btn-close-white me-2 m-auto" data-bs-dismiss="toast" aria-label="Close"></button></div>`;
  box.appendChild(el);
  el.addEventListener('hidden.bs.toast', () => el.remove());
  new bootstrap.Toast(el, { delay: type === 'danger' ? 5000 : 3000 }).show();
}

/** A friendly confirm pop-up. Resolves true when the user confirms. */
function confirmAction({ title, text, confirm = 'Delete', danger = true }) {
  return new Promise((resolve) => {
    const el = document.createElement('div');
    el.className = 'modal fade';
    el.tabIndex = -1;
    el.innerHTML = `<div class="modal-dialog modal-dialog-centered"><div class="modal-content p-2">
      <div class="modal-header"><h2 class="modal-title">${esc(title)}</h2><button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Close"></button></div>
      <div class="modal-body pt-0"><p class="mb-0" style="color:#475569">${esc(text)}</p></div>
      <div class="modal-footer"><button type="button" class="ft-btn light" data-bs-dismiss="modal">Cancel</button>
      <button type="button" class="ft-btn ${danger ? 'danger' : ''}" data-ok>${esc(confirm)}</button></div></div></div>`;
    document.body.appendChild(el);
    const modal = new bootstrap.Modal(el);
    let ok = false;
    el.querySelector('[data-ok]').addEventListener('click', () => { ok = true; modal.hide(); });
    el.addEventListener('hidden.bs.modal', () => { el.remove(); resolve(ok); });
    modal.show();
  });
}

/** A small form in a pop-up. fields: [{name, label, type, value, options, required, min, placeholder}]. Resolves the values, or null. */
function formDialog({ title, fields, submit = 'Save' }) {
  return new Promise((resolve) => {
    const el = document.createElement('div');
    el.className = 'modal fade';
    el.tabIndex = -1;
    const input = (f) => f.options
      ? `<select class="ft-input" name="${f.name}" id="fd_${f.name}">${f.options.map(([v, t]) => `<option value="${esc(v)}" ${String(v) === String(f.value) ? 'selected' : ''}>${esc(t)}</option>`).join('')}</select>`
      : `<input class="ft-input" name="${f.name}" id="fd_${f.name}" type="${f.type || 'text'}" value="${esc(f.value ?? '')}" ${f.required ? 'required' : ''}
         ${f.min !== undefined ? `min="${f.min}"` : ''} ${f.type === 'number' ? 'step="0.01"' : ''} placeholder="${esc(f.placeholder || '')}" maxlength="${f.max || 255}">`;
    el.innerHTML = `<div class="modal-dialog modal-dialog-centered"><form class="modal-content p-2">
      <div class="modal-header"><h2 class="modal-title">${esc(title)}</h2><button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Close"></button></div>
      <div class="modal-body pt-0 d-flex flex-column gap-3">${fields.map((f) => `<div class="ft-field"><label for="fd_${f.name}">${esc(f.label)}</label>${input(f)}</div>`).join('')}</div>
      <div class="modal-footer"><button type="button" class="ft-btn light" data-bs-dismiss="modal">Cancel</button><button class="ft-btn">${esc(submit)}</button></div></form></div>`;
    document.body.appendChild(el);
    const modal = new bootstrap.Modal(el);
    let result = null;
    el.querySelector('form').addEventListener('submit', (e) => { e.preventDefault(); result = Object.fromEntries(new FormData(e.target)); modal.hide(); });
    el.addEventListener('shown.bs.modal', () => el.querySelector('input,select')?.focus());
    el.addEventListener('hidden.bs.modal', () => { el.remove(); resolve(result); });
    modal.show();
  });
}

/** Runs an async action and shows its error as a toast instead of failing silently. */
const attempt = (fn) => async (...args) => { try { return await fn(...args); } catch (e) { toast(e.message, 'danger'); } };
