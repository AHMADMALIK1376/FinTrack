const router = require('express').Router();
const db = require('../db');

// GET /api/budgets?month=2026-11  -> budgets with amount spent so far
router.get('/', async (req, res, next) => {
  try {
    const month = `${req.query.month || new Date().toISOString().slice(0, 7)}-01`;
    const { rows } = await db.query(
      `SELECT b.*, c.name AS category, COALESCE(cs.total_spent, 0) AS spent
       FROM budgets b
       JOIN categories c ON c.category_id = b.category_id
       LEFT JOIN category_spending cs ON cs.category_id = b.category_id AND cs.month = b.month
       WHERE b.user_id = $1 AND b.month = $2::date
       ORDER BY c.name`, [req.user.id, month]);
    res.json(rows);
  } catch (err) { next(err); }
});

router.post('/', async (req, res, next) => {
  try {
    const { category_id, limit_amount, month } = req.body; // month as "2026-11"
    const { rows } = await db.query(
      `INSERT INTO budgets (user_id, category_id, limit_amount, month)
       VALUES ($1, $2, $3, $4::date)
       ON CONFLICT (user_id, category_id, month) DO UPDATE SET limit_amount = EXCLUDED.limit_amount
       RETURNING *`, [req.user.id, category_id, limit_amount, `${month}-01`]);
    res.status(201).json(rows[0]);
  } catch (err) { next(err); }
});

router.delete('/:id', async (req, res, next) => {
  try {
    const { rowCount } = await db.query(
      'DELETE FROM budgets WHERE budget_id = $1 AND user_id = $2', [req.params.id, req.user.id]);
    if (!rowCount) return res.status(404).json({ error: 'Budget not found.' });
    res.status(204).end();
  } catch (err) { next(err); }
});

module.exports = router;
