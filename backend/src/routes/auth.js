const router = require('express').Router();
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const db = require('../db');

const sign = (u) => jwt.sign({ id: u.user_id, name: u.full_name, email: u.email },
                             process.env.JWT_SECRET, { expiresIn: '7d' });

// POST /api/auth/register  { full_name, email, password }
router.post('/register', async (req, res, next) => {
  const { full_name, email, password } = req.body;
  if (!full_name || !email || !password || password.length < 6) {
    return res.status(400).json({ error: 'Name, email and a password of at least 6 characters are required.' });
  }
  const client = await db.pool.connect();
  try {
    await client.query('BEGIN');
    const hash = await bcrypt.hash(password, 10);
    const { rows } = await client.query(
      `INSERT INTO users (full_name, email, password_hash) VALUES ($1, $2, $3)
       RETURNING user_id, full_name, email`, [full_name.trim(), email.trim().toLowerCase(), hash]);
    const user = rows[0];
    // give every new user a starter set of categories and a cash account
    await client.query(
      `INSERT INTO categories (user_id, name, type) VALUES
        ($1,'Salary','income'), ($1,'Other Income','income'), ($1,'Opening Balance','income'),
        ($1,'Food','expense'), ($1,'Rent','expense'), ($1,'Transport','expense'),
        ($1,'Bills','expense'), ($1,'Shopping','expense'), ($1,'Health','expense')`, [user.user_id]);
    await client.query(`INSERT INTO accounts (user_id, account_name, account_type) VALUES ($1,'Cash','cash')`, [user.user_id]);
    await client.query('COMMIT');
    res.status(201).json({ token: sign(user), user });
  } catch (err) {
    await client.query('ROLLBACK');
    if (err.code === '23505') return res.status(409).json({ error: 'An account with this email already exists.' });
    next(err);
  } finally {
    client.release();
  }
});

// POST /api/auth/login  { email, password }
router.post('/login', async (req, res, next) => {
  try {
    const { email = '', password = '' } = req.body;
    const { rows } = await db.query('SELECT * FROM users WHERE email = $1', [email.trim().toLowerCase()]);
    const user = rows[0];
    if (!user || !(await bcrypt.compare(password, user.password_hash))) {
      return res.status(401).json({ error: 'Wrong email or password.' });
    }
    res.json({ token: sign(user), user: { user_id: user.user_id, full_name: user.full_name, email: user.email } });
  } catch (err) { next(err); }
});

module.exports = router;
