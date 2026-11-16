// Activity: the logged-in user's audit log as plain sentences (DB-09).
// Only entries about the user's own data are returned (SEC-01).
const router = require('express').Router();
const db = require('../db');

const rupees = (value) => `Rs ${Number(value).toLocaleString('en-PK', { maximumFractionDigits: 2 })}`;
const quoted = (text) => (text ? `"${text}"` : '');

/** Field names shown to people, per table; fields not listed here are not mentioned. */
const FIELD_NAMES = {
  transactions: { amount: 'amount', txn_date: 'date', description: 'description', account_id: 'account', category_id: 'category' },
  accounts: { account_name: 'name', account_type: 'type' },
  budgets: { limit_amount: 'limit', month: 'month' },
};

/** Shows one changed value in plain words. */
function show(field, value, names) {
  if (value === null || value === undefined || value === '') return 'nothing';
  if (['amount', 'limit_amount'].includes(field)) return rupees(value);
  if (field === 'account_id') return names.accounts[value] || 'another account';
  if (field === 'category_id') return names.categories[value] || 'another category';
  if (field === 'month') return String(value).slice(0, 7);
  return quoted(String(value));
}

/**
 * Turns one audit_log row into a sentence, e.g. 'Added "Groceries": −Rs 8,000 from Cash'.
 * @param {object} entry audit_log row
 * @param {{accounts: object, categories: object}} names id → name lookups for the user's accounts and categories
 * @returns {string} the sentence
 */
function describe(entry, names) {
  const row = entry.new_data || entry.old_data;
  const fieldNames = FIELD_NAMES[entry.table_name] || {};
  const changes = entry.action === 'UPDATE'
    ? Object.keys(fieldNames)
      .filter((f) => JSON.stringify(entry.old_data[f]) !== JSON.stringify(entry.new_data[f]))
      .map((f) => `${fieldNames[f]} ${show(f, entry.old_data[f], names)} → ${show(f, entry.new_data[f], names)}`)
    : [];

  if (entry.table_name === 'transactions') {
    const type = names.categoryTypes[row.category_id];
    const what = quoted(row.description) || (type ? `an ${type}` : 'a transaction');
    const account = names.accounts[row.account_id] || 'a deleted account';
    // e.g. "−Rs 8,000 from Cash" or "+Rs 120,000 to HBL Bank"
    const movement = type === 'income' ? `+${rupees(row.amount)} to ${account}`
      : type === 'expense' ? `−${rupees(row.amount)} from ${account}` : `${rupees(row.amount)} in ${account}`;
    if (entry.action === 'INSERT') return `Added ${what}: ${movement}`;
    if (entry.action === 'DELETE') return `Deleted ${what} (${movement})`;
    return `Changed ${what}: ${changes.join(', ')}`;
  }
  if (entry.table_name === 'accounts') {
    if (entry.action === 'INSERT') return `Added the account ${quoted(row.account_name)}`;
    if (entry.action === 'DELETE') return `Deleted the account ${quoted(row.account_name)}`;
    return `Changed the account ${quoted(entry.old_data.account_name)}: ${changes.join(', ')}`;
  }
  const category = names.categories[row.category_id] || 'a category';
  if (entry.action === 'INSERT') return `Set a ${rupees(row.limit_amount)} budget for ${category}`;
  if (entry.action === 'DELETE') return `Removed the ${category} budget`;
  return `Changed the ${category} budget: ${changes.join(', ')}`;
}

// GET /api/activity?limit=20  -> newest first
router.get('/', async (req, res, next) => {
  try {
    const limit = Math.min(Math.max(parseInt(req.query.limit, 10) || 20, 1), 100);
    const [log, accounts, categories] = await Promise.all([
      db.query(
        `SELECT audit_id, table_name, record_id, action, old_data, new_data, changed_at,
                changed_by_user_id = $1 AS by_me, changed_by_user_id IS NULL AS by_database
         FROM audit_log WHERE owner_user_id = $1
         ORDER BY changed_at DESC, audit_id DESC LIMIT $2`, [req.user.id, limit]),
      db.query('SELECT account_id, account_name FROM accounts WHERE user_id = $1', [req.user.id]),
      db.query('SELECT category_id, name, type FROM categories WHERE user_id = $1', [req.user.id]),
    ]);
    const names = {
      accounts: Object.fromEntries(accounts.rows.map((a) => [a.account_id, a.account_name])),
      categories: Object.fromEntries(categories.rows.map((c) => [c.category_id, c.name])),
      categoryTypes: Object.fromEntries(categories.rows.map((c) => [c.category_id, c.type])),
    };
    res.json(log.rows.map((entry) => ({
      audit_id: entry.audit_id,
      table_name: entry.table_name,
      record_id: entry.record_id,
      action: entry.action,
      changed_at: entry.changed_at,
      who: entry.by_me ? 'you' : entry.by_database ? 'database' : 'someone else',
      summary: describe(entry, names),
    })));
  } catch (err) { next(err); }
});

module.exports = router;
module.exports.describe = describe;
