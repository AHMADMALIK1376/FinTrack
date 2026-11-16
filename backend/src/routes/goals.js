const router = require('express').Router();
const db = require('../db');

router.get('/', async (req, res, next) => {
  try {
    const { rows } = await db.query(
      'SELECT * FROM savings_goals WHERE user_id = $1 ORDER BY deadline NULLS LAST', [req.user.id]);
    res.json(rows);
  } catch (err) { next(err); }
});

router.post('/', async (req, res, next) => {
  try {
    const { goal_name, target_amount, saved_amount = 0, deadline } = req.body;
    const { rows } = await db.query(
      `INSERT INTO savings_goals (user_id, goal_name, target_amount, saved_amount, deadline)
       VALUES ($1, $2, $3, $4, $5) RETURNING *`,
      [req.user.id, goal_name, target_amount, saved_amount, deadline || null]);
    res.status(201).json(rows[0]);
  } catch (err) { next(err); }
});

// PATCH /api/goals/:id/add  { amount }  -> add money to a goal
router.patch('/:id/add', async (req, res, next) => {
  try {
    const { rows } = await db.query(
      `UPDATE savings_goals SET saved_amount = saved_amount + $1
       WHERE goal_id = $2 AND user_id = $3 RETURNING *`,
      [req.body.amount, req.params.id, req.user.id]);
    if (!rows[0]) return res.status(404).json({ error: 'Goal not found.' });
    res.json(rows[0]);
  } catch (err) { next(err); }
});

router.delete('/:id', async (req, res, next) => {
  try {
    const { rowCount } = await db.query(
      'DELETE FROM savings_goals WHERE goal_id = $1 AND user_id = $2', [req.params.id, req.user.id]);
    if (!rowCount) return res.status(404).json({ error: 'Goal not found.' });
    res.status(204).end();
  } catch (err) { next(err); }
});

module.exports = router;
