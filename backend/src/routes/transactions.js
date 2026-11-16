const router = require('express').Router();
const db = require('../db');

// GET /api/transactions?month=2026-11&type=expense&category_id=3&search=rent
router.get('/', async (req, res, next) => {
  try {
    const where = ['a.user_id = $1'];
    const params = [req.user.id];
    const add = (sql, value) => { params.push(value); where.push(sql.replace('?', `$${params.length}`)); };
    if (req.query.month) add("DATE_TRUNC('month', t.txn_date) = DATE_TRUNC('month', ?::date)", `${req.query.month}-01`);
    if (req.query.type) add('c.type = ?', req.query.type);
    if (req.query.category_id) add('t.category_id = ?', req.query.category_id);
    if (req.query.account_id) add('t.account_id = ?', req.query.account_id);
    if (req.query.search) add('t.description ILIKE ?', `%${req.query.search}%`);
    const { rows } = await db.query(
      `SELECT t.*, a.account_name, c.name AS category, c.type
       FROM transactions t
       JOIN accounts a   ON a.account_id = t.account_id
       JOIN categories c ON c.category_id = t.category_id
       WHERE ${where.join(' AND ')}
       ORDER BY t.txn_date DESC, t.transaction_id DESC
       LIMIT 500`, params);
    res.json(rows);
  } catch (err) { next(err); }
});

// Makes sure the account belongs to the logged-in user
async function ownsAccount(userId, accountId) {
  const { rowCount } = await db.query(
    'SELECT 1 FROM accounts WHERE account_id = $1 AND user_id = $2', [accountId, userId]);
  return rowCount === 1;
}

router.post('/', async (req, res, next) => {
  try {
    const { account_id, category_id, amount, txn_date, description } = req.body;
    if (!(await ownsAccount(req.user.id, account_id))) return res.status(404).json({ error: 'Account not found.' });
    const { rows } = await db.query(
      `INSERT INTO transactions (account_id, category_id, amount, txn_date, description)
       VALUES ($1, $2, $3, COALESCE($4::date, CURRENT_DATE), $5) RETURNING *`,
      [account_id, category_id, amount, txn_date || null, description]);
    res.status(201).json(rows[0]);
  } catch (err) { next(err); }
});

router.put('/:id', async (req, res, next) => {
  try {
    const { account_id, category_id, amount, txn_date, description } = req.body;
    if (!(await ownsAccount(req.user.id, account_id))) return res.status(404).json({ error: 'Account not found.' });
    const { rows } = await db.query(
      `UPDATE transactions t
       SET account_id = $1, category_id = $2, amount = $3, txn_date = $4, description = $5
       FROM accounts a
       WHERE t.transaction_id = $6 AND a.account_id = t.account_id AND a.user_id = $7
       RETURNING t.*`,
      [account_id, category_id, amount, txn_date, description, req.params.id, req.user.id]);
    if (!rows[0]) return res.status(404).json({ error: 'Transaction not found.' });
    res.json(rows[0]);
  } catch (err) { next(err); }
});

router.delete('/:id', async (req, res, next) => {
  try {
    const { rowCount } = await db.query(
      `DELETE FROM transactions t USING accounts a
       WHERE t.transaction_id = $1 AND a.account_id = t.account_id AND a.user_id = $2`,
      [req.params.id, req.user.id]);
    if (!rowCount) return res.status(404).json({ error: 'Transaction not found.' });
    res.status(204).end();
  } catch (err) { next(err); }
});

module.exports = router;
