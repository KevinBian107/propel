# Skill Trigger Tests

Expected trigger mappings for Propel skills. Use these to verify that the correct skill activates for a given user input.

## Meta Skill

| User Input | Expected Skill | Gate |
|------------|---------------|------|
| "I want to implement RVQ" | using-propel → Gate 0 (Intake) | 0 |
| "Build me a new loss function" | using-propel → Gate 0 (Intake) | 0 |
| Any new task description | using-propel → Gate 0 (Intake) | 0 |

## Process Skills (highest priority)

| User Input | Expected Skill |
|------------|---------------|
| "Start an investigation into the encoder" | investigation |
| "Trace from the dataset to the loss function" | investigation |
| "What touches the reward computation?" | investigation |
| "Figure out why the gradients vanish" | investigation |
| "This should work, right?" | think-deeply |
| "I think the issue is the learning rate" | think-deeply |
| "Isn't it better to use sum instead of mean?" | think-deeply |
| "Should we use A or B?" | think-deeply |
| "Retrospective" | retrospective |
| "Capture what we learned" | retrospective |
| "Save this for next time" | retrospective |
| [~20 turns without retrospective] | retrospective (auto-suggest) |
| "Getting long" | context-hygiene |
| "Context is large" | context-hygiene |
| [>15 substantive turns] | context-hygiene (auto-suggest) |

## Research Skills

| User Input | Expected Skill |
|------------|---------------|
| "Survey the state of VQ-VAE variants" | deep-research |
| "What approaches exist for codebook collapse?" | deep-research |
| "Compare methods for discrete representation" | deep-research |
| "Process these papers" | paper-extraction |
| "Build a paper database from these PDFs" | paper-extraction |
| "Propose how to implement the RVQ module" | research-design |
| "Design the implementation for the new loss" | research-design |
| "How should we implement this?" | research-design |
| "Write the plan" | writing-plans |
| "Break this into tasks" | writing-plans |

## Implementation Skills

| User Input | Expected Skill | Gate |
|------------|---------------|------|
| "Go" (after plan approval) | subagent-driven-research | - |
| "Implement this" (after plan approval) | subagent-driven-research | - |
| "Start building" (after plan approval) | subagent-driven-research | - |
| "Validate this implementation" | research-validation | - |
| "Test if this works" | research-validation | - |
| "Check if this is correct" | research-validation | - |
| [After each component in plan] | subagent-driven-research → Gate 3 | 3 |
| [Before claiming "done"] | verification-before-completion | - |

## Debugging Skills

| User Input | Expected Skill | Gate |
|------------|---------------|------|
| "NaN loss after 500 steps" | systematic-debugging | - |
| "Loss plateaus and won't decrease" | systematic-debugging | - |
| "The model outputs are all identical" | systematic-debugging | - |
| [After diagnosis complete] | systematic-debugging → Gate 4 | 4 |

## Commands

| User Input | Expected Command |
|------------|-----------------|
| "/read-paper path/to/paper.pdf" | read-paper |
| "/debug-training NaN loss at step 1000" | debug-training |
| "/trace-shapes training forward pass" | trace-shapes |
| "/primer" | primer |
| "/new-session RVQ experiment" | new-session |

## Prerequisite Checks

| Skill | Prerequisite | If Missing |
|-------|-------------|-----------|
| research-design | Investigation complete + Gate 1 passed | Refuses, directs to investigation |
| writing-plans | Design complete | Refuses, directs to research-design |
| subagent-driven-research | Plan complete + Gate 2 passed | Refuses, directs to writing-plans |

## Gate Question Quality Checks

Gate questions must be:
- **Disjunctive**: "Should we [A] or [B]?" — NOT "Shall I proceed?"
- **Assumption-exposing**: "I'm assuming [X]. If wrong, this changes." — NOT "Do you have questions?"
- **Design-revealing**: "The paper doesn't specify [Y]. Our choice determines [Z]." — NOT "Is this okay?"
- **Evidence-based**: "I found [evidence] suggesting [conclusion]." — NOT generic

Invalid gate questions (must never appear):
- "Shall I proceed?"
- "Is this okay?"
- "Do you have any questions?"
- "Can I continue?"
- "Does this look good?"
