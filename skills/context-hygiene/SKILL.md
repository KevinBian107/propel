---
name: context-hygiene
description: >
  Enforces /clear discipline and context management for long research sessions.
  Auto-activates when the conversation exceeds ~15 substantive turns, or when the
  user says "getting long", "context is large", "should I clear". Prevents context
  degradation by ensuring living READMEs are updated, retrospectives are captured,
  and sessions are archived before /clear. Research sessions can run very long —
  this skill enforces the discipline of clearing before Claude gets stupid.
---

# Context Hygiene — /clear Discipline

## Why This Matters

Claude degrades with long context. Responses become less precise, more generic, and more likely to hallucinate details. Research sessions with investigation + implementation + debugging can easily exceed the threshold where degradation kicks in. This skill enforces the discipline of clearing context proactively.

## When This Activates

- **Auto**: Conversation exceeds ~15 substantive turns (not counting short confirmations)
- **User trigger**: "getting long", "context is large", "should I clear", "running out of context"
- **Post-implementation**: After completing a major component or reaching a pause point in the plan

## Pre-Clear Checklist

Before clearing, ensure ALL of the following:

### 1. Update the Living README
- Is the investigation README in `scratch/` up to date with current findings?
- Are all design decisions documented?
- Is the plan status updated (which tasks are done)?

> "Let me update the investigation README with our current progress before we clear."

### 2. Capture a Retrospective (if applicable)
- Were experiments run this session?
- Were bugs found and fixed?
- Were there failed attempts worth documenting?

If yes to any:
> "We should capture a retrospective before clearing — the failed attempts table won't survive a context reset."

### 3. Archive the Session
- Suggest session archival via `propel-session save` or `/new-session`
- If a session was started with `propel-session launch`, remind the user the chat history will be saved on exit

> "Consider archiving this session with `propel-session save` before clearing."

### 4. Note Where to Resume
- Write a clear "## Next Steps" section in the investigation README
- Include: what to do next, which plan tasks remain, any open questions

> "I've added a 'Next Steps' section to the README. When you resume, start by reading scratch/{investigation}/README.md."

## After Clear

When the session resumes (session-start hook re-fires):
- Read the investigation README to restore context
- Check `scratch/registry/` for relevant entries
- Check the plan for incomplete tasks
- Continue from where we left off

## Proactive Reminders

At natural pause points, suggest:
> "We've been going for a while. Good time to update the README and /clear — context quality degrades in long sessions. I've updated the README with our current progress."

## Important

- **Don't wait for the user to notice degradation.** By the time responses feel "off", significant context quality has already been lost.
- **The README IS the memory.** Everything that matters must be written down before clearing. Anything not in the README is lost.
- **Retrospectives are cheap, re-derivation is expensive.** 5 minutes capturing what we learned saves 30 minutes of repeating failed experiments after /clear.
- **Session archives enable continuity.** Chat history + investigation README + retrospective = full context recovery for the next session.
