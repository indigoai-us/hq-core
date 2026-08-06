---
type: reference
domain: [engineering]
status: canonical
tags: [ralph, core-concepts, mallocing, context-management, terminology]
relates_to: []
---

# Core Concepts

## Key Terminology

### Mallocing / Memory Allocation

In the context of Ralph, "mallocing" refers to how you allocate and manage the AI's context window - similar to memory allocation in programming.

> "Ralph is really just a mallocing orchestrator that avoids context rot and compaction."
> — Geoffrey Huntley

Good mallocing means:
- Only loading relevant specifications into context
- Clearing context between tasks
- Being intentional about what information the AI sees

### Context Rot

Context rot occurs when the AI's context window becomes polluted with outdated or irrelevant information from earlier in the conversation. This degrades the quality of outputs over time.

**Solution**: Start fresh for each task by spawning a new agent instance.

### Compaction

Compaction is when the context window gets filled with verbose or unnecessary content, leaving less room for the actual task at hand.

> "Compaction is the devil"
> — Geoffrey Huntley

**Solution**: Use focused specifications and remove unnecessary content from the context.

### Back Pressure

Back pressure is the feedback mechanism that pushes back on the AI when it generates incorrect code. This is the key to making autonomous coding work.

> "The back pressure if it generates something wrong, the test pushes back on the generative function to try again before the wheel is allowed to turn around."
> — Geoffrey Huntley

Forms of back pressure:
- Unit tests
- Integration tests
- Type checking (TypeScript, etc.)
- Linting
- Build processes
- Pre-commit hooks

### Generative Function

The AI model that generates code. In Ralph, we "engineer back pressure to keep the generative function on the rails."

### The Loop / Wheel

The core iteration cycle of Ralph:
1. Pick a task from specifications
2. Generate code
3. Run back pressure checks
4. If checks pass, commit and move to next task
5. If checks fail, regenerate
6. Repeat

### Routing

The process of directing the AI's attention to specific tasks or specifications. In Ralph, you control the routing by selecting which specifications to load into context.

### Weavers

Geoffrey's term for autonomous coding agents that work together. They can:
- Introduce features with feature flags
- Deploy code
- Monitor analytics
- Make autonomous decisions about optimizations

### AFK Coding

"Away From Keyboard" coding - running AI agents autonomously while you're not actively supervising.

> "This front-end feedback loop makes AFK AI coding a lot more powerful. If you're looping an AI, for instance, in the Ralph Wiggum setup, then plugging a browser into your front end or full stack work will be such a massive improvement."
> — Matt Pocock

## The Six Stages of AI Adoption

Geoffrey Huntley describes six stages software developers go through:

1. **"It's not good enough"** - Dismissing AI capabilities
2. **"Prove to me that this isn't hype"** - Skepticism
3. **"Experimenting with LLMs"** - Trying it out
4. **"Deer in headlights"** - Realizing implications ("Will I have a job in the future?")
5. **"Alarmed - need to bin our planning and change priorities"** - Organizational response
6. **"Engaged - realization that LLMs can be programmed"** - Active adoption

## Key Principles

### 1. Simplicity Over Complexity
A for loop beats elaborate orchestration systems.

### 2. Fresh Context Per Task
Start each task with a clean context to avoid rot.

### 3. Small, Atomic Changes
Keep changes small enough to verify and commit independently.

### 4. Robust Feedback Loops
Invest heavily in automated testing and verification.

### 5. No Human Tool Calls
> "Anytime you tool call a human, that's not AGI, that's not Ralph."
> — Geoffrey Huntley

### 6. Fast Feedback
Optimize for quick iteration cycles - slow compilation (like Rust) can be a bottleneck.

### 7. Engineering Still Matters
> "I still believe in engineering. Still believe in engineering and like the bridge collapses, that's on you."
> — Geoffrey Huntley
