/**
 * The session's company lock, read the way core/scripts/lib/session-scope-capability.sh
 * reads it, so a run is only shown for a company this session may see.
 */

const SLUG = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/
const SESSION = /^[A-Za-z0-9][A-Za-z0-9._-]*$/

export const capabilityPath = (sessionId: string) =>
  SESSION.test(sessionId) ? `workspace/sessions/${sessionId}/scope-capability.json` : undefined

/**
 * The companies a scope-capability.json grants this session; [] when malformed.
 * Only the primary company is granted: the shell resolver also checks the
 * multi-company kill switch, which a mod cannot read, before it grants the rest
 * of company_slugs. The set is still validated, so a tampered file grants nothing.
 */
export function lockedCompanies(cap: unknown, sessionId: string): string[] {
  if (cap === null || typeof cap !== 'object') return []
  const { session_id, agent_id, company_slug, company_slugs } = cap as Record<string, unknown>
  if (session_id !== sessionId || (agent_id ?? '') !== '') return []
  if (typeof company_slug !== 'string' || !SLUG.test(company_slug)) return []
  if (company_slugs === undefined) return [company_slug]

  const set = company_slugs
  const isValid =
    Array.isArray(set) &&
    set.length > 0 &&
    set.every(one => typeof one === 'string' && SLUG.test(one)) &&
    set[0] === company_slug &&
    new Set(set).size === set.length &&
    (company_slug === 'personal' ? set.length === 1 : !set.includes('personal'))

  return isValid ? [company_slug] : []
}

/** The company a PRD path is under: `companies/<slug>/...`, or `personal/...`. */
function prdCompany(prdPath: string): string | undefined {
  const parts = prdPath.split('/')
  if (parts[0] === 'personal') return 'personal'
  return parts[0] === 'companies' && parts[1] !== undefined && parts[1] !== '' ? parts[1] : undefined
}

/**
 * Whether a run may be shown under the lock, and why not when it may not. The
 * run's company is state.json's `company`, else the company its PRD is under;
 * both, when present, must be locked.
 */
export function stateScope(
  stateCompany: string | undefined,
  prdPath: string | undefined,
  locked: string[],
): { isAllowed: boolean; note?: string } {
  if (locked.length === 0) return { isAllowed: false, note: 'run not shown: this session has no company lock' }
  const fromPrd = prdPath === undefined ? undefined : prdCompany(prdPath)
  if (prdPath !== undefined && fromPrd === undefined) {
    return { isAllowed: false, note: 'run not shown: its PRD is outside companies/' }
  }
  if (stateCompany === undefined && fromPrd === undefined) {
    return { isAllowed: false, note: 'run not shown: state.json names no company' }
  }
  for (const one of [stateCompany, fromPrd]) {
    if (one !== undefined && !locked.includes(one)) {
      return { isAllowed: false, note: `run not shown: ${one} is outside this session's companies` }
    }
  }

  return { isAllowed: true }
}
