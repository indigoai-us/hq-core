# changelog.d: changelog entry fragments

Add a changelog entry for a PR as a new file in this folder instead of
editing the `## [Unreleased]` section of `core/docs/hq/CHANGELOG.md`.
Every PR that adds a line at the top of that section conflicts with each
new commit on main; a new file with its own name does not.

## Adding an entry

- One file per change, named after the change in kebab case, for example
  `changelog.d/company-jobs-failure-reasons.md`. Pick a name no other open
  PR is likely to use.
- The file holds the entry text as it should appear in the changelog, in
  the same form as the existing entries: start with `Fixed (...)`,
  `Added (...)`, `Changed (...)` or `Tests (...)`, then the description and
  the regression tests. Leave out the leading `- `; it is added at release.
- Do not edit `core/docs/hq/CHANGELOG.md` in the same PR.

## Collecting at release

The person cutting the release adds each fragment as a `- ` bullet under
`## [Unreleased]` (or under the new version heading) in
`core/docs/hq/CHANGELOG.md`, then deletes the collected fragment files in
the release PR. This README stays.
