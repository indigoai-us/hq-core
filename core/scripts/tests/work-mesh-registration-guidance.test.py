#!/usr/bin/env python3
"""Contract checks for the agent's server-view-before-registration workflow."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[3]


class RegistrationGuidanceTest(unittest.TestCase):
    def test_shared_workflow_persists_and_reads_back_before_registering(self):
        text = (ROOT / 'core/skills/work-mesh/SKILL.md').read_text()
        steps = [text.index(label) for label in (
            '1. **Read before writing:**', '2. **Persist the server view:**',
            '3. **Verify persistence:**', '4. **Register only after verification:**')]
        self.assertEqual(steps, sorted(steps))
        self.assertIn('PUT /v1/work-mesh/projects/{projectId}', text[steps[1]:steps[2]])
        verify = text[steps[2]:steps[3]]
        self.assertIn('GET /v1/work-mesh/projects/{projectId}?companyUid={companyUid}', verify)
        for requirement in ('company and project IDs', 'story ID', 'repo identity/path',
                            'not just counts', 'mismatch', 'stop'):
            self.assertIn(requirement, verify)
        self.assertIn('POST /v1/work-mesh/projects/{projectId}/register', text[steps[3]:])

    def test_existing_view_is_not_blindly_replaced(self):
        text = (ROOT / 'core/skills/work-mesh/SKILL.md').read_text()
        for requirement in ('confirmed 404', 'reuse it without a PUT',
                            'preserve live story', 'retain unrelated server entries',
                            'no conditional-version', 'exclusive',
                            'expectedVersion', 'stop'):
            self.assertIn(requirement, text)

    def test_both_planning_entry_points_require_server_view_prerequisite(self):
        for name in ('plan', 'prd'):
            with self.subTest(skill=name):
                text = (ROOT / f'.claude/skills/{name}/SKILL.md').read_text()
                step = text.split('## Step 5.7:', 1)[1].split('## Step 6:', 1)[0]
                self.assertIn('local `board.json` does not establish the server', step)
                put = step.index('PUT /v1/work-mesh/projects/{projectId}')
                verify = step.index('GET verification')
                register = step.index('POST /v1/work-mesh/projects/{projectId}/register')
                self.assertLess(put, verify)
                self.assertLess(verify, register)
                for requirement in ('stories', 'repos', 'exact company', 'story IDs/content',
                                    'repo identities/paths', 'Preserve live story', 'Stop'):
                    self.assertIn(requirement, step)


if __name__ == '__main__':
    unittest.main()
