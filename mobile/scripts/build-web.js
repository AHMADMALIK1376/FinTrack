// Copies the website (../frontend) into www/ for the app, and tells the pages where the server is.
// The server address comes from FT_API_BASE, else the FinTrack on Render.
//   node scripts/build-web.js                 (or: npm run web)
//   FT_API_BASE=https://other.onrender.com node scripts/build-web.js
const fs = require('fs');
const path = require('path');

const apiBase = (process.env.FT_API_BASE || 'https://fintrack-y4wq.onrender.com').replace(/\/$/, '');
if (!/^https:\/\//.test(apiBase)) {
  console.error('FT_API_BASE must start with https:// (Android blocks plain http).');
  process.exit(1);
}
const from = path.join(__dirname, '..', '..', 'frontend');
const to = path.join(__dirname, '..', 'www');

fs.rmSync(to, { recursive: true, force: true });
fs.cpSync(from, to, { recursive: true });

// api.js reads window.FT_CONFIG.apiBase; it is set at the very top of the copy, before anything runs
const api = path.join(to, 'js', 'api.js');
fs.writeFileSync(api, `window.FT_CONFIG = ${JSON.stringify({ apiBase, app: 'android' })};\n` + fs.readFileSync(api, 'utf8'));
console.log(`www/ ready: pages from frontend/, server ${apiBase}`);
