const router = require('express').Router();
const db = require('../db');

// GET /api/reports/dashboard?month=2026-11  -> everything the dashboard needs
router.get('/dashboard', async (req, res, next) => {
  try {
    const month = `${req.query.month || new Date().toISOString().slice(0, 7)}-01`;
    const uid = req.user.id;
    const [balance, summary, byCategory, trend, warnings] = await Promise.all([
      db.query('SELECT COALESCE(SUM(balance), 0) AS total FROM accounts WHERE user_id = $1', [uid]),
      db.query('SELECT * FROM monthly_summary WHERE user_id = $1 AND month = $2::date', [uid, month]),
      db.query(`SELECT category, total_spent FROM category_spending
                WHERE user_id = $1 AND month = $2::date ORDER BY total_spent DESC`, [uid, month]),
      db.query(`SELECT TO_CHAR(month, 'Mon YYYY') AS label, total_income, total_expense
                FROM monthly_summary WHERE user_id = $1 AND month > ($2::date - INTERVAL '6 months')
                AND month <= $2::date ORDER BY month`, [uid, month]),
      db.query('SELECT * FROM check_budget($1, $2::date)', [uid, month]),
    ]);
    const s = summary.rows[0] || { total_income: 0, total_expense: 0, net_saving: 0 };
    res.json({
      total_balance: balance.rows[0].total,
      total_income: s.total_income,
      total_expense: s.total_expense,
      net_saving: s.net_saving,
      by_category: byCategory.rows,
      trend: trend.rows,
      budget_warnings: warnings.rows,
    });
  } catch (err) { next(err); }
});

module.exports = router;
