// Mirrors hq-cloud v6.18.17 src/lib/cloud-authoritative.ts:38-45.
export const SERVER_OWNED_PATH_PREFIXES = Object.freeze([
  'ontology/',
  'signals/',
  'sources/',
]);

export function isServerOwnedPath(relativePath) {
  return SERVER_OWNED_PATH_PREFIXES.some((prefix) => relativePath.startsWith(prefix));
}
