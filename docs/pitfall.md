# Pitfalls — Known Failure Modes When Working with Claude

This is a living document. When you discover a new pitfall, add it here so future sessions can reference it.

---

## Pitfall 1: Unconstrained Implementation

**Severity**: High — leads to plausible-looking but fundamentally wrong code

### The Problem

Claude works badly when given vague, open-ended implementation requests. An unconstrained problem like "I want to build a can transport task with robosuite" is dangerous because Claude will:

1. **Fill in gaps with training-data averages** — it picks the most likely architecture, reward structure, API usage, etc. based on what it has seen, not what your project needs
2. **Make confident but arbitrary choices** — it won't tell you it's guessing about the reward function, the observation space, or the controller interface
3. **Produce code that compiles but is subtly wrong** — the implementation looks reasonable, passes a cursory review, but embeds wrong assumptions that surface much later (e.g., during training)

### Why This Happens

Claude is fundamentally a pattern-matching system. When given a specific example to morph ("take PickPlace and add a transport phase"), it produces excellent results because the constraints are tight. When given an open-ended request ("build a can transport task"), it has to fill in every design decision from its training distribution — and the mean of all possible implementations is rarely the correct one for your specific use case.

**Claude is great at**: looking at one thing and morphing it into something you want.
**Claude is bad at**: creating something new from scratch when the problem is unconstrained.

### Symptoms

- Claude produces a complete implementation without asking clarifying questions about architecture or reference implementations
- The code uses a plausible but wrong API (e.g., an older version of robosuite, or a different simulator's conventions)
- Reward functions look reasonable but don't match any known working design
- The implementation doesn't follow the patterns established in the rest of the codebase
- After training, the agent doesn't learn — and debugging reveals fundamental design issues, not just hyperparameter problems

### The Fix

The Questioner checkpoints (Q0 and Q1) in the Propel pipeline exist specifically to prevent this:

**Q0 (before investigation)** forces the user to provide:
- A reference codebase or repo to start from
- An architecture or design pattern to follow
- An existing example to study and adapt
- A benchmark or ground truth to verify against
- Specific APIs or framework conventions to use

**Q1 (before design)** forces the user to specify:
- Interface contracts and data formats
- Configuration approach and defaults
- Edge case handling
- Integration points with existing code
- Minimal vs. extended scope

If the user cannot provide any reference implementation or example to adapt from, Q0 flags this as a **high-risk unconstrained implementation** so that investigation is extra thorough and Claude doesn't pretend it knows the right approach.

### Examples

**Bad** (unconstrained):
```
User: Build a can transport task with robosuite.
Claude: [produces 300 lines of code with arbitrary choices for reward, obs space, controller, etc.]
```

**Good** (constrained with Q0):
```
User: Build a can transport task with robosuite.
Claude (Q0): Is there an existing task I should use as a starting point?
User: Yes, look at PickPlace in robosuite/environments/manipulation/
Claude (Q0): What architecture should I follow — same reward phases as PickPlace?
User: Same structure, but add a transport phase between pick and place.
Claude (Q0): What benchmark should I verify against?
User: PickPlace test suite as baseline.
[Claude now has concrete anchors and produces correct code]
```

### Key Insight

The cost of 5 minutes of Q0/Q1 questions is negligible. The cost of an unconstrained implementation that compiles but trains wrong is hours of debugging and wasted compute. When in doubt, ask for a reference — it's always faster than guessing.
