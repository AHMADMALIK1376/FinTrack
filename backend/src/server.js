// FinTrack server entry point: loads settings from .env and starts the app.
require('dotenv').config({ path: require('path').join(__dirname, '..', '.env') });
const { checkDatabaseSettings } = require('./check-env');

try {
  checkDatabaseSettings();
}
catch (err) {
  console.error(err.message);
  process.exit(1);
}

const app = require('./app');

const port = process.env.PORT || 3000;
app.listen(port, () => console.log(`FinTrack running at http://localhost:${port}`));
