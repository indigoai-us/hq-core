# AI Security Framework for Autonomous Workflows

> **Your "Driver's License" for AI-Powered Automation**

A comprehensive security knowledge base for individuals and organizations deploying AI agents with broad system access. Born from the Ralph Wiggum Loop methodology—where AI runs autonomously with fresh context—this framework addresses the unique security challenges of giving AI access to browsers, keychains, and critical business systems.

---

## Why This Exists

The promise of AI automation is extraordinary: $10/hour software development, 24/7 autonomous agents, and exponential productivity gains. But with that power comes significant risk:

- **94.4%** of state-of-the-art LLM agents are vulnerable to prompt injection
- **45%** of enterprises now run production AI agents with critical system access
- **September 2025** saw the first documented large-scale cyberattack executed by agentic AI
- Machine identities now outnumber human employees **82 to 1**

This framework helps you embrace the Ralph philosophy—"make mistakes and learn"—while ensuring those mistakes don't become catastrophic.

---

## Core Philosophy

```
"Accept that one-offs will happen. That's part of the Ralph philosophy.
But distinguish between recoverable mistakes and existential ones."
```

**Three Security Tiers:**

| Tier | Risk Level | Example Actions | Approach |
|------|-----------|-----------------|----------|
| **Green** | Recoverable | Drafts, research, file organization | Full autonomy |
| **Yellow** | Consequential | External comms, code changes, data analysis | Review gates |
| **Red** | Existential | Financial transactions, credential access, publishing | Human approval required |

---

## Quick Start

**Need to get secure fast?** → [30-Minute Quick Start Guide](QUICK-START.md)

### 1. Read the Essentials
- [Core Principles](docs/01-core-principles.md) - The mental model
- [Threat Landscape](docs/02-threat-landscape.md) - What you're protecting against
- [Your Security Posture](docs/03-security-posture.md) - Self-assessment
- [Glossary](GLOSSARY.md) - Key terms defined

### 2. Run the Checklists
- [Pre-Flight Checklist](checklists/pre-flight.md) - Before enabling AI automation
- [Browser Security Checklist](checklists/browser-security.md) - Claude in Chrome hardening
- [Credential Isolation Checklist](checklists/credential-isolation.md) - Protecting your keychain
- [Incident Response](checklists/incident-response.md) - When things go wrong

### 3. Implement the Configs
- [agents.md Security Template](templates/agents-security.md) - Autonomy levels
- [Audit Logging Setup](configs/audit-logging.md) - What to track
- [Kill Switch Patterns](configs/kill-switches.md) - Emergency stops

### 4. Maintain Security
- [Weekly Audit Checklist](checklists/weekly-audit.md) - Ongoing hygiene (15 min/week)

---

## Framework Structure

```
ai-security-framework/
├── README.md                    # You are here
├── QUICK-START.md              # 30-minute setup guide
├── GLOSSARY.md                 # Key terms defined
├── CONTRIBUTING.md             # How to contribute
├── docs/                       # Deep-dive documentation
│   ├── 01-core-principles.md   # Security mental model
│   ├── 02-threat-landscape.md  # Attack vectors & risks
│   └── 03-security-posture.md  # Self-assessment guide
├── checklists/                 # Actionable checklists
│   ├── pre-flight.md           # Before you start
│   ├── browser-security.md     # Browser hardening
│   ├── credential-isolation.md # Secrets management
│   ├── weekly-audit.md         # Ongoing hygiene
│   └── incident-response.md    # Emergency checklist
├── configs/                    # Technical configurations
│   ├── audit-logging.md        # Logging setup
│   └── kill-switches.md        # Emergency patterns
└── templates/
    └── agents-security.md      # Autonomy configuration template
```

---

## Key Concepts

### The Blast Radius Principle

Every AI action should have a defined "blast radius"—the maximum damage if something goes wrong:

| Action | Blast Radius | Mitigation |
|--------|-------------|------------|
| Reading public websites | Minimal | None needed |
| Drafting documents | Low | Auto-save, version control |
| Sending emails | Medium | Draft review, delay send |
| Financial transactions | High | Multi-factor approval |
| Credential access | Critical | Never allow |

### Context Isolation (from Ralph)

The Ralph methodology's "fresh context per task" isn't just about performance—it's a security feature:

- **No context rot** = No accumulated sensitive data leaking between tasks
- **Controlled mallocing** = Only relevant specs loaded, nothing extra
- **Clean state** = Each iteration starts without historical baggage

### Defense in Depth

Never rely on a single security control:

```
Layer 1: Least Privilege (limit what AI can access)
    └── Layer 2: Sandboxing (isolate where AI runs)
        └── Layer 3: Audit Logging (track what AI does)
            └── Layer 4: Kill Switches (stop AI if needed)
                └── Layer 5: Human Review (verify outcomes)
```

---

## Integration with Ralph Methodology

This framework extends the Ralph back-pressure concept to security:

**Traditional Ralph Back-Pressure:**
- Tests pass?
- Linting clean?
- Types check?
- Build succeeds?

**Security Back-Pressure (additions):**
- Action within authorized scope?
- Credentials isolated?
- Audit log captured?
- Blast radius acceptable?
- Human approval obtained (if required)?

Add these checks to your `agents.md`:

```markdown
## Security Rules

- NEVER access password managers or stored credentials directly
- NEVER execute financial transactions without explicit approval
- ALWAYS log actions to audit trail before execution
- ALWAYS verify scope before accessing external systems
- IF action blast radius > "low", request human review
```

---

## Compliance Mapping

| Framework | Relevance | Key Requirements |
|-----------|-----------|-----------------|
| **OWASP Agentic Top 10 (2026)** | Direct | Prompt injection, credential theft, memory poisoning |
| **NIST AI RMF** | High | Govern, Map, Measure, Manage |
| **ISO 42001** | High | AI management systems, risk assessment |
| **SOC 2 Type II** | Medium | Access controls, audit logging |
| **GDPR** | Medium | Data processing, consent, logging |

---

## Quick Reference Card

### Red Lines (Never Allow AI To)
- Access password managers or keychains
- Execute financial transactions autonomously
- Publish content without review
- Modify authentication systems
- Access production databases directly

### Yellow Zones (Require Review)
- External communications (email, Slack, social)
- Code commits to main branches
- File deletions or bulk modifications
- API calls to paid services
- Data exports

### Green Zones (Allow Autonomously)
- Research and information gathering
- Draft creation and editing
- Local file organization
- Development in sandboxed environments
- Reading (not writing) approved systems

---

## Contributing

This framework is designed to evolve. If you've discovered:
- New attack vectors specific to AI agents
- Better mitigation strategies
- Useful configurations or scripts
- Real-world incident learnings

Please contribute via pull request. Security is a community effort.

---

## Resources

### Industry Standards
- [OWASP Top 10 for Agentic Applications 2026](https://genai.owasp.org/resource/owasp-top-10-for-agentic-applications-for-2026/)
- [NIST AI Risk Management Framework](https://www.nist.gov/itl/ai-risk-management-framework)
- [MAESTRO Framework](https://www.mitre.org/focus-areas/cybersecurity/maestro)

### AI-Specific Guidance
- [Claude in Chrome Safety Guide](https://support.claude.com/en/articles/12902428-using-claude-in-chrome-safely)
- [Claude Code Sandboxing](https://code.claude.com/docs/en/sandboxing)
- [AWS Well-Architected: Agentic Workflows](https://docs.aws.amazon.com/wellarchitected/latest/generative-ai-lens/gensec05-bp01.html)

### Methodology
- [Ralph Methodology](https://github.com/geoffrey-huntley/ralph) - The autonomous coding approach this framework secures
- [Geoffrey Huntley's Original Documentation](https://ghuntley.com/ralph)

---

## License

MIT License - Use freely, contribute back, stay secure.

---

*"The goal isn't to prevent all mistakes—it's to ensure mistakes are learning opportunities, not catastrophes."*
