---
type: reference
domain: [operations, engineering]
status: canonical
tags: [glossary, terminology, security, definitions]
relates_to: []
---

# Glossary

> Key terms used in this security framework

---

## A

### AI Agent
An AI system that can take autonomous actions in the world—browsing websites, sending emails, writing code, etc. Unlike a chatbot that only responds, agents act on your behalf.

### Allowlist
A list of explicitly permitted resources (sites, APIs, actions). Everything NOT on the list is blocked by default. More secure than blocklist approach.

### Audit Log
A chronological record of all actions taken by an AI agent, including what was done, when, and the outcome. Essential for security review and incident investigation.

### Autonomy Level
The degree of independence granted to an AI agent for a particular type of action. Ranges from "full autonomy" (no human approval needed) to "never allowed" (agent cannot perform).

---

## B

### Back Pressure
In the Ralph methodology, the checks that prevent bad work from accumulating. For security, this includes permission checks, approval gates, and validation before actions execute.

### Blast Radius
The maximum potential damage if something goes wrong with a particular action or capability. A key concept for determining what level of autonomy to grant.

### Blocklist
A list of explicitly prohibited resources. Everything NOT on the list is allowed. Less secure than allowlist approach because new threats aren't automatically blocked.

### Bounded Autonomy
The principle of giving AI freedom to operate within carefully defined limits. AI can act independently within boundaries but cannot exceed them.

---

## C

### Circuit Breaker
An automated mechanism that stops AI agent activity when certain thresholds are exceeded (error rate, spending, unusual patterns). Like an electrical circuit breaker that trips to prevent damage.

### Context Isolation
From the Ralph methodology: starting each AI task with fresh context, without accumulated data from previous tasks. A security feature that prevents sensitive data leakage between operations.

### Credential Broker
An architecture pattern where AI agents don't have direct credential access. Instead, they request access through a broker (human or automated) that provides time-limited, scoped tokens.

---

## D

### Defense in Depth
Layering multiple security controls so that failure of any single control doesn't result in complete compromise. Each layer provides protection if other layers fail.

---

## F

### Fail-Secure
When a security control fails, the system becomes MORE restrictive, not less. Example: if the approval system fails, actions are blocked rather than auto-approved.

### Fresh Context
Starting an AI operation without carrying over context from previous operations. Prevents accumulated sensitive data and reduces attack surface.

---

## G

### GREEN Zone
In this framework: actions that AI can take autonomously without human approval. Low blast radius, easily reversible.

---

## K

### Kill Switch
An emergency mechanism to immediately stop all AI agent activity. Should be accessible in under 60 seconds and tested regularly.

---

## L

### Least Privilege
The security principle of giving an entity (user, AI, system) only the minimum access needed to perform its specific task—no more.

---

## M

### Machine Identity (NHI - Non-Human Identity)
Credentials, tokens, or accounts used by automated systems rather than humans. AI agents use machine identities to access services.

### Memory Poisoning
An attack where malicious information is injected into an AI's persistent memory, causing it to behave incorrectly in future sessions.

---

## P

### Prompt Injection
An attack where malicious instructions are hidden in content the AI processes (websites, documents, emails), causing the AI to take unintended actions.

---

## R

### RED Zone
In this framework: actions that AI must NEVER take, regardless of instructions. Critical blast radius, potentially catastrophic consequences.

### Review Gate
A checkpoint requiring human approval before AI can proceed with a consequential action. Provides oversight for YELLOW zone actions.

---

## S

### Sandboxing
Running AI agents in an isolated environment where they cannot affect systems outside the sandbox. Limits blast radius of compromises.

### Scoped Token
A credential with limited permissions, valid only for specific actions or resources. Contrasts with full-access credentials.

### Session Termination
Immediately ending an AI agent's active session, including revoking any temporary access and clearing active state.

### System Prompt Extraction
An attack where adversaries trick AI into revealing its configuration or instructions, exposing security rules and business logic.

---

## T

### Token Rotation
Regularly replacing credentials/tokens with new ones, even if no compromise is suspected. Limits the window of opportunity if a credential is stolen.

---

## Y

### YELLOW Zone
In this framework: actions that AI can take but requires notification or review. Moderate blast radius, requires oversight.

---

## Z

### Zero Standing Privileges
An access model where no entity has permanent access to sensitive resources. Access is granted just-in-time, scoped, and revoked after use.

### Zero Trust
A security model that assumes no implicit trust based on network location, previous authentication, or other contextual factors. Every request must be verified.

---

## Security Framework Acronyms

| Acronym | Meaning |
|---------|---------|
| MFA | Multi-Factor Authentication |
| IAM | Identity and Access Management |
| RBAC | Role-Based Access Control |
| PAT | Personal Access Token |
| SSO | Single Sign-On |
| OAuth | Open Authorization (delegation protocol) |
| CSRF | Cross-Site Request Forgery |
| XSS | Cross-Site Scripting |
| CVE | Common Vulnerabilities and Exposures |
| OWASP | Open Web Application Security Project |
| NIST | National Institute of Standards and Technology |
| SOC 2 | Service Organization Control Type 2 |

---

*Can't find a term? It might be in the [Core Principles](docs/01-core-principles.md) or [Threat Landscape](docs/02-threat-landscape.md) docs.*
