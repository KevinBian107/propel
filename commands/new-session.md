Create a new session directory for this experiment and set up session tracking.

Description: $ARGUMENTS

## Process

1. **Create session directory**:
   - Find project root via `git rev-parse --show-toplevel`
   - Create `sessions/{date}-{slug}/` with:
     - `prompt.md` — template with the session description
     - `.session_id` — UUID for this session
   - If there's an active investigation in `scratch/`, create a symlink to it

2. **Update session index**:
   - Add entry to `sessions/INDEX.md` (create if it doesn't exist)

3. **Report back**:
   - Print the session directory path
   - Print the session ID
   - Remind user to save session before `/clear`:
     > "When you're done, run `propel-session save <session-id> <session-dir>` to archive the chat history."

## If propel-session CLI is installed

Use it directly:
```bash
propel-session launch "$ARGUMENTS"
```

## If not installed

Do it manually — create the directory structure, generate a UUID, write the files. The CLI is a convenience, not a requirement.
