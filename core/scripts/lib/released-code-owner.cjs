// hq-core: public
// Root must own every path it executes, including parent directories.
const fs = require('node:fs');
const path = require('node:path');

function assertReleased(target, lstatSync) {
  for (let current = path.resolve(target); ; current = path.dirname(current)) {
    const stat = lstatSync(current);
    if (stat.isSymbolicLink()) throw Error('Symlink refused');
    if (stat.uid !== 0 || (stat.mode & 0o022)) throw Error('Released code must be root owned');
    if (current === path.dirname(current)) break;
  }
}

function assertReleasedCode(targets, lstatSync = fs.lstatSync) {
  for (const target of targets) assertReleased(target, lstatSync);
}

module.exports = { assertReleased, assertReleasedCode };
