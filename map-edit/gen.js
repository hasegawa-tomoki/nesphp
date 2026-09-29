// node map-edit/gen.js map-edit/town.json examples/town_map.php examples/town.data.bin [chr-edit/misaki_bdf_2021-05-05/misaki_gothic.bdf]
const fs = require('fs');
const { exportMapPhp, parseBdf } = require('./export.js');
const [, , jsonPath, mapOut, binOut, bdfPath] = process.argv;
const data = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
const bdf = bdfPath ? parseBdf(fs.readFileSync(bdfPath, 'utf8')) : null;
const r = exportMapPhp(data, bdf);
fs.writeFileSync(mapOut, r.php);
fs.writeFileSync(binOut, r.bin);
for (const w of r.warnings) console.warn('warning: ' + w);
console.log(`wrote ${mapOut}, ${binOut} (${r.bin.length} bytes)`);
