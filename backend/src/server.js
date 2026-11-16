// FinTrack server entry point: loads settings from .env and starts the app.
require('dotenv').config();
const app = require('./app');

const port = process.env.PORT || 3000;
app.listen(port, () => console.log(`FinTrack running at http://localhost:${port}`));
