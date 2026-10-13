const fs = require('fs');
const vm = require('vm');
const h = fs.readFileSync('hub/src/assets/dashboard.html', 'utf8');
const m = h.match(/<script>([\s\S]*?)<\/script>/);
if (!m) { console.log('NO SCRIPT FOUND'); process.exit(1); }
try {
  new vm.Script(m[1]);
  console.log('JS syntax OK (' + m[1].length + ' chars)');
} catch (e) {
  console.log('JS SYNTAX ERROR: ' + e.message);
  process.exit(1);
}
