// FinTrack Express app: the REST API under /api and the website from ../frontend.
// Exported without listening, so tests can start it on a free port (server.js starts it for real).
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

// Turn errors into clear messages (UI-03): database error codes and broken JSON become 400s
// with a plain sentence; anything else is logged and answered with a general message.
app.use((err, req, res, next) => {
  if (err.type === 'entity.parse.failed') {
    return res.status(400).json({ error: 'The request could not be read. Please try again.' });
  }
  const known = {
    '23505': 'This item already exists.',
    '23503': 'This item is linked to other records and cannot be changed.',
    '23001': 'This item is linked to other records and cannot be changed.', // ON DELETE RESTRICT on PostgreSQL 18
    '23514': 'A value is not allowed (for example, amounts must be greater than zero).',
    '23502': 'Please fill in all required fields.',
    '22P02': 'A value has the wrong format.',
    '22007': 'A date has the wrong format.',
    '22008': 'That date does not exist.',
    '22003': 'That number is too large.',
    'P0001': err.message,
  };
  if (known[err.code]) return res.status(400).json({ error: known[err.code] });
  console.error(err);
  res.status(500).json({ error: 'Something went wrong on the server.' });
});

module.exports = app;
