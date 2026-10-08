# Policy enforcement gates

Hard policy prompt priority is context, not proof of compliance. HQ therefore
uses receipt-backed hook gates for requirements the runtime can verify before an
outbound action.

## Lifecycle

1. `inject-policy-on-trigger.sh` remains the single tenant-safe policy selector.
   It writes the matched policy IDs and paths to the session enforcement state.
   For Bash sends, selection and action gating run in one sequence so a policy
   first matched by the outbound command applies to that same command.
2. On `UserPromptSubmit`, `policy-enforcement-gate.sh` declares required skill
   and attached-brief reads. Explicit MUST/NEVER conflicts between a matched
   hard policy and supplied instructions are surfaced before execution.
3. On `PostToolUse`, only a successful read-capable tool call can mint a receipt.
   A write to the same path is not a receipt.
4. On `PreToolUse`, outbound send/post/message actions are blocked while a
   declared receipt is missing. Deterministic content gates run before delivery
   against a structured body or an inspectable literal shell assignment.

Semantic conflicts are surfaced for human/agent resolution. They are not
automatically blocked because token overlap cannot safely decide which meaning
is correct. Receipt and content failures are blocked because they are
mechanically provable.

## Policy frontmatter

A matched policy may declare one or more of these optional scalar fields:

```yaml
required-skill: work-broadcast
required-brief: companies/acme/projects/launch/brief.md
delivery-forbid-regex: INTERNAL_ONLY|excluded exemplar
delivery-require-regex: ^:chart_with_upwards_trend:
```

- `required-skill` accepts one skill name or a comma-separated list.
- `required-brief` is an HQ-root-relative or absolute path.
- Delivery regexes use extended regular-expression syntax and should be
  unquoted YAML scalars. An invalid expression blocks delivery with the policy
  ID instead of silently disabling the gate.
- Regex gates inspect structured body fields (`message`, `text`, `body`,
  `content`, `details`, or `prompt`) and literal `MESSAGE`, `BODY`, or `TEXT`
  assignments in shell sends. If a governed body remains opaque behind shell
  expansion, delivery fails closed rather than silently skipping the gate.

User prompts also declare requirements without policy metadata when they name a
required skill, request a Slack/work broadcast, or refer to an attached brief.
If an attachment is declared but no path is available in the hook payload or
prompt, delivery fails closed and asks for a resolvable path.

## Governed outbound actions

The default governed boundary is a tool whose name represents send, post,
broadcast, message, email, or DM, plus recognized HQ/Slack broadcast commands.
Read, edit, test, and local build actions remain available so the agent can
satisfy missing receipts and repair blocked content.
