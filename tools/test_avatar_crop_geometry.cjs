// Exercise the production ArkTS geometry directly, without a device or generated files.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const deveco = process.env.DEVECO_HOME || 'D:/DevEco/DevEco Studio';
const ts = require(process.argv[2] || path.join(deveco, 'tools/hvigor/hvigor/node_modules/typescript'));
const source = fs.readFileSync(path.join(__dirname,
  '../app/entry/src/main/ets/utils/AvatarCropGeometry.ets'), 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;
const exportsObject = {};
vm.runInNewContext(compiled, { exports: exportsObject });
const geometry = exportsObject.AvatarCropGeometry;
const region = (...args) => JSON.parse(JSON.stringify(geometry.region(...args)));

assert.deepEqual(region(800, 400, 200, 1, 0, 0), { x: 200, y: 0, side: 400 });
assert.deepEqual(region(800, 400, 200, 1, 100, 0), { x: 0, y: 0, side: 400 });
assert.deepEqual(region(800, 400, 200, 1, -100, 0), { x: 400, y: 0, side: 400 });
assert.deepEqual(region(400, 800, 200, 1, 0, -100), { x: 0, y: 400, side: 400 });
assert.deepEqual(region(400, 800, 200, 2, 50, -50), { x: 50, y: 350, side: 200 });
assert.deepEqual(region(400, 800, 400, 2, 100, -100), region(400, 800, 200, 2, 50, -50));
assert.equal(geometry.clampOffset(1000, 800, 0.5, 200), 100);
assert.ok(geometry.clampOffset(-1000, 400, 0.5, 200) === 0);

let scenarios = 0;
for (const [width, height] of [[1024, 300], [300, 1024], [601, 601], [1, 1]]) {
  for (const viewport of [240, 320, 420]) {
    for (const zoom of [1, 1.5, 2, 4]) {
      const factor = geometry.factor(width, height, viewport, zoom);
      for (const delta of [-10000, 0, 10000]) {
        const x = geometry.clampOffset(delta, width, factor, viewport);
        const y = geometry.clampOffset(delta, height, factor, viewport);
        const crop = region(width, height, viewport, zoom, x, y);
        assert.ok(crop.side >= 1 && crop.side <= Math.min(width, height));
        assert.ok(crop.x >= 0 && crop.x + crop.side <= width);
        assert.ok(crop.y >= 0 && crop.y + crop.side <= height);
        // No uncovered background can enter the viewport after dragging or zooming.
        assert.ok(Math.abs(x) <= (width * factor - viewport) / 2 + 1e-6);
        assert.ok(Math.abs(y) <= (height * factor - viewport) / 2 + 1e-6);
        scenarios++;
      }
    }
  }
}
console.log(`Avatar crop geometry: 8 landmark/resize checks and ${scenarios} boundary scenarios passed.`);
