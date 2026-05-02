---
id: hq-cloudformation-sub-for-template-strings
title: Wrap CloudFormation strings containing ${Var} references in !Sub
scope: global
trigger: authoring or editing CloudFormation templates (YAML) with string fields that reference parameters, resources, or pseudo-parameters via `${...}`
enforcement: soft
public: true
version: 1
created: 2026-04-21
updated: 2026-04-21
source: session-learning
applies_to: [aws]
---

## Rule

ALWAYS wrap CloudFormation strings containing `${Var}` template references in `!Sub`. Plain multiline YAML scalars (`>` or `|`) do NOT interpolate — the `${Var}` will appear literally in the deployed resource.

Wrong:
```yaml
AlarmDescription: >
  Lambda ${FunctionName} exceeded error threshold in ${AWS::Region}.
  Runbook: https://runbooks.example.com/${FunctionName}
```

Right:
```yaml
AlarmDescription: !Sub >
  Lambda ${FunctionName} exceeded error threshold in ${AWS::Region}.
  Runbook: https://runbooks.example.com/${FunctionName}
```

Run `cfn-lint` on every CloudFormation template before committing — it flags this as W1020 (short form) or E1020 (error-level). Easy to miss in long-form fields like `AlarmDescription`, `Description`, and `Statement` blocks in IAM policies.

## Rationale

CloudFormation's YAML parser does not treat `${...}` as a template directive by default — that behavior is owned by the `!Sub` intrinsic function. A plain multiline scalar preserves the literal `${FunctionName}` string and ships it to the deployed resource, which then renders useless alarm descriptions, broken runbook links, or (worse) IAM statements referencing non-existent ARNs. `cfn-lint` catches this reliably but only if actually run; the failure mode is silent at synth time.
