// FinTrack API server: serves the REST API under /api and the website from ../frontend
require('dotenv').config();
const path = require('path');
const express = require('express');
const cors = require('cors');
const requireAuth = require('./middleware/auth');

const app = express();
app.use(cors());
app.use(express.json());

// API routes
app.use('/api/auth', require('./routes/auth'));
app.use('/api/accounts', requireAuth, require('./routes/accounts'));
app.use('/api/categories', requireAuth, require('./routes/categories'));
app.use('/api/transactions', requireAuth, require('./routes/transactions'));
app.use('/api/budgets', requireAuth, require('./routes/budgets'));
app.use('/api/goals', requireAuth, require('./routes/goals'));
app.use('/api/reports', requireAuth, require('./routes/reports'));
app.get('/api/health', (req, res) => res.json({ status: 'ok' }));

// Website (HTML, CSS, JS, Bootstrap)
app.use(express.static(path.join(__dirname, '..', '..', 'frontend')));

// Turn database errors into clear messages
app.use((err, req, res, next) => {
  const known = {
    '23505': 'This item already exists.',
    '23503': 'This item is linked to other records and cannot be changed.',
    '23514': 'A value is not allowed (for example, amounts must be greater than zero).',
    '22P02': 'A value has the wrong format.',
    'P0001': err.message,
  };
  if (known[err.code]) return res.status(400).json({ error: known[err.code] });
  console.error(err);
  res.status(500).json({ error: 'Something went wrong on the server.' });
});

const port = process.env.PORT || 3000;
app.listen(port, () => console.log(`FinTrack running at http://localhost:${port}`));
