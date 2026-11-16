const router = require('express').Router();
const db = require('../db');

router.get('/', async (req, res, next) => {
  try {
    const { rows } = await db.query(
      'SELECT * FROM accounts WHERE user_id = $1 ORDER BY account_id', [req.user.id]);
    res.json(rows);
  } catch (err) { next(err); }
});

router.post('/', async (req, res, next) => {
  try {
    const { account_name, account_type } = req.body;
    const { rows } = await db.query(
      `INSERT INTO accounts (user_id, account_name, account_type) VALUES ($1, $2, $3) RETURNING *`,
      [req.user.id, account_name, account_type]);
    res.status(201).json(rows[0]);
  } catch (err) { next(err); }
});

router.put('/:id', async (req, res, next) => {
  try {
    const { account_name, account_type } = req.body;
    const { rows } = await db.query(
      `UPDATE accounts SET account_name = $1, account_type = $2
       WHERE account_id = $3 AND user_id = $4 RETURNING *`,
      [account_name, account_type, req.params.id, req.user.id]);
    if (!rows[0]) return res.status(404).json({ error: 'Account not found.' });
    res.json(rows[0]);
  } catch (err) { next(err); }
});

router.delete('/:id', async (req, res, next) => {
  try {
    const { rowCount } = await db.query(
      'DELETE FROM accounts WHERE account_id = $1 AND user_id = $2', [req.params.id, req.user.id]);
    if (!rowCount) return res.status(404).json({ error: 'Account not found.' });
    res.status(204).end();
  } catch (err) { next(err); }
});

// POST /api/accounts/transfer  { from_account, to_account, amount }
router.post('/transfer', async (req, res, next) => {
  try {
    const { from_account, to_account, amount } = req.body;
    const own = await db.query(
      'SELECT COUNT(*)::int AS n FROM accounts WHERE user_id = $1 AND account_id IN ($2, $3)',
      [req.user.id, from_account, to_account]);
    if (own.rows[0].n !== 2) return res.status(404).json({ error: 'Account not found.' });
    await db.query('CALL transfer_money($1, $2, $3)', [from_account, to_account, amount]);
    res.json({ ok: true });
  } catch (err) { next(err); }
});

module.exports = router;
