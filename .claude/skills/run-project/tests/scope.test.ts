import { describe, expect, test } from 'claude-code/testing'

import { capabilityPath, lockedCompanies, stateScope } from '../hooks/scope'

describe('lockedCompanies', () => {
  test('a single-company lock', () => {
    expect(lockedCompanies({ session_id: 's1', company_slug: 'acme' }, 's1')).toEqual(['acme'])
  })

  test('a multi-company lock grants only its primary company', () => {
    const cap = { session_id: 's1', company_slug: 'acme', company_slugs: ['acme', 'globex'] }

    expect(lockedCompanies(cap, 's1')).toEqual(['acme'])
  })

  test('fails closed on anything malformed or not this session', () => {
    expect(lockedCompanies(null, 's1')).toEqual([])
    expect(lockedCompanies({ session_id: 's2', company_slug: 'acme' }, 's1')).toEqual([])
    expect(lockedCompanies({ session_id: 's1', agent_id: 'a1', company_slug: 'acme' }, 's1')).toEqual([])
    expect(lockedCompanies({ session_id: 's1', company_slug: '../x' }, 's1')).toEqual([])
    expect(lockedCompanies({ session_id: 's1', company_slug: 'acme', company_slugs: ['globex', 'acme'] }, 's1')).toEqual([])
    expect(lockedCompanies({ session_id: 's1', company_slug: 'acme', company_slugs: ['acme', 'acme'] }, 's1')).toEqual([])
    expect(lockedCompanies({ session_id: 's1', company_slug: 'acme', company_slugs: ['acme', 'personal'] }, 's1')).toEqual([])
    expect(lockedCompanies({ session_id: 's1', company_slug: 'acme', company_slugs: 'acme' }, 's1')).toEqual([])
  })

  test('the capability lives in the session folder', () => {
    expect(capabilityPath('s1')).toBe('workspace/sessions/s1/scope-capability.json')
    expect(capabilityPath('../s1')).toBeUndefined()
  })
})

describe('stateScope', () => {
  test('a run of a locked company is shown', () => {
    expect(stateScope(undefined, 'companies/acme/projects/p/prd.json', ['acme'])).toEqual({ isAllowed: true })
    expect(stateScope('acme', 'companies/acme/projects/p/prd.json', ['acme'])).toEqual({ isAllowed: true })
    expect(stateScope('acme', undefined, ['acme'])).toEqual({ isAllowed: true })
    expect(stateScope(undefined, 'personal/projects/p/prd.json', ['personal'])).toEqual({ isAllowed: true })
  })

  test('a run of another company, or of no company, is not', () => {
    expect(stateScope(undefined, 'companies/globex/projects/p/prd.json', ['acme']).isAllowed).toBe(false)
    expect(stateScope('globex', 'companies/acme/projects/p/prd.json', ['acme']).isAllowed).toBe(false)
    expect(stateScope('acme', 'companies/globex/projects/p/prd.json', ['acme']).isAllowed).toBe(false)
    expect(stateScope('globex', undefined, ['acme']).isAllowed).toBe(false)
    expect(stateScope('acme', 'projects/p/prd.json', ['acme']).isAllowed).toBe(false)
    expect(stateScope(undefined, 'personal/projects/p/prd.json', ['acme']).isAllowed).toBe(false)
    expect(stateScope(undefined, undefined, ['acme']).isAllowed).toBe(false)
    expect(stateScope('acme', 'companies/acme/projects/p/prd.json', []).isAllowed).toBe(false)
  })

  test('says why it refused', () => {
    expect(stateScope(undefined, 'companies/globex/projects/p/prd.json', ['acme']).note).toBe(
      'run not shown: globex is outside this session\'s companies',
    )
    expect(stateScope('acme', 'companies/acme/projects/p/prd.json', []).note).toBe(
      'run not shown: this session has no company lock',
    )
    expect(stateScope(undefined, undefined, ['acme']).note).toBe('run not shown: state.json names no company')
    expect(stateScope('acme', 'projects/p/prd.json', ['acme']).note).toBe(
      'run not shown: its PRD is outside companies/',
    )
  })
})
