# Sample grilling question set

Fixture for core/scripts/tests/grilling-count.test.sh. 12 questions: 10 decisions and 2 facts. The test passes Q-users, Q-scope, and Q-naming as known, so the engine asks the remaining 7 decisions.

## Q-users
Who is the primary user?

- tier: strategic
- kind: decision
- depends_on: []
- options: Operators | Developers | Both
- recommended: Operators

## Q-scope
What is the v1 scope boundary?

- tier: strategic
- kind: decision
- depends_on: [Q-users]
- options: One company | All companies
- recommended: One company

## Q-success
How is success measured?

- tier: strategic
- kind: decision
- depends_on: [Q-users]
- options: Adoption | Time saved | Error rate
- recommended: Time saved

## Q-runtime
Which runtimes does the repo already support?

- tier: architecture
- kind: fact
- depends_on: []

## Q-storage
Where is state stored?

- tier: architecture
- kind: decision
- depends_on: [Q-scope, Q-runtime]
- options: Local files | Cloud vault | Both
- recommended: Local files

## Q-existing
Which existing skills already parse question sets?

- tier: architecture
- kind: fact
- depends_on: [Q-storage]

## Q-api
What interface do callers use?

- tier: architecture
- kind: decision
- depends_on: [Q-storage, Q-existing]
- options: Skill include | Script | Both
- recommended: Skill include

## Q-migration
How are existing callers migrated?

- tier: architecture
- kind: decision
- depends_on: [Q-api]
- options: In one PR | One caller per PR
- recommended: One caller per PR

## Q-tests
What test level is required?

- tier: quality
- kind: decision
- depends_on: [Q-api]
- options: Unit | Unit and e2e
- recommended: Unit and e2e

## Q-naming
What naming convention do ids use?

- tier: quality
- kind: decision
- depends_on: []
- options: Q-prefixed | Free form
- recommended: Q-prefixed

## Q-docs
Where does the documentation live?

- tier: quality
- kind: decision
- depends_on: [Q-naming]
- options: Skill file | Knowledge base
- recommended: Skill file

## Q-rollout
How is it rolled out?

- tier: quality
- kind: decision
- depends_on: [Q-tests, Q-migration]
- options: Behind a flag | Default on
- recommended: Default on
