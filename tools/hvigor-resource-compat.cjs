/* SDK 6.1.1 can load its optional image-transcoding DLL even when compression
 * is explicitly disabled. Omit that unused generated option on Windows; this
 * leaves source resources and every enabled compression configuration intact.
 * Hooked from hvigorfile.ts, without modifying the installed SDK.
 */
'use strict';
if (process.platform === 'win32') {
  const cp = require('node:child_process');
  const fs = require('node:fs');
  for (const name of ['spawn', 'spawnSync']) {
    const original = cp[name];
    cp[name] = function (file, args, ...rest) {
      if (/(?:^|[\\/])restool(?:\.exe)?$/i.test(String(file)) && Array.isArray(args)) {
        const index = args.indexOf('-l');
        if (index >= 0 && typeof args[index + 1] === 'string') {
          const configPath = args[index + 1];
          const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
          if (typeof config.compression === 'string') {
            const options = JSON.parse(fs.readFileSync(config.compression, 'utf8'));
            if (options.compression?.media?.enable === false &&
                Array.isArray(options.compression.filters) && options.compression.filters.length === 0) {
              delete config.compression;
              fs.writeFileSync(configPath, JSON.stringify(config));
            }
          }
        }
      }
      return original.call(this, file, args, ...rest);
    };
  }
}
