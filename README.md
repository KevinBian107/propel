<p align="center">
  <img src="assets/logo.svg" alt="Propel Logo" width="140"/>
</p>

# Propel

A research coding assistant for Claude Code, not an autonomous scientist. Structured constraints turn unconstrained LLM output into precise, paper-aligned research code, while every research decision stays with you.

**[Website](https://kbian.org/propel-website/)** | **[Documentation](https://kbian.org/propel-website/docs/)** | **[Vibe Coding Articles](https://kbian.org/Kaiwen-Wiki/articles/vibe_coding/)**

<p align="center">
  <img src="assets/propel_pipeline.svg" alt="Propel pipeline: seven stages from intake to retrospective, with human gates G0–G4, questioners Q0 and Q1, a per-component review loop, a working-memory loop into the next session, and the stages each mode runs" width="100%"/>
</p>

## Why Propel?

Propel is a **research coding assistant**. It is not an autonomous scientist: it does not choose your research question, run experiments unattended, or decide what counts as a result. You bring the question, the paper, and the judgment. Propel makes Claude Code a careful collaborator on the code that tests them.

That split matters because an unconstrained LLM writes the **mean of its training data**. Ask it to "add a diffusion policy head" and you get a blend of every diffusion codebase it has seen: a cosine noise schedule from one repo, ε-prediction from another, an EMA decay from a third. The code runs and may even train, but it is not the variant your paper describes, and the choices that decide whether your experiment means anything were made without asking you.

Propel adds structure instead of cleverer prompts. Claude has to investigate before it writes code, stop at five gates to ask you design questions, and send every change past auditors that compare it against the paper and look for silent bugs. Each retrospective feeds a working memory of past experiments and designs that is loaded into the next session, so Claude checks what was already tried before proposing it again.

## Core Principles

| Principle | Rule |
|-----------|------|
| **Assistant, not agent** | Investigate and present — don't guess and act. Every claim traceable to evidence. |
| **Evidence over agreement** | Be correct, not agreeable. Steel-man the counterargument before agreeing. |
| **Context discipline** | Hallucination risk grows with context. Preserve state in living READMEs, clear proactively. |
| **Critical self-reflection** | Question your own reasoning as hard as the user's. |
| **Break logic loops** | Name circular reasoning, reframe, or bring new data. 3-strike limit. |

## Four Modes

| Mode | Active Gates | When to Use |
|------|-------------|-------------|
| **Researcher** | Gate 0, 1 | Understanding the problem space — papers, code tracing, approaches |
| **Engineer** | All (0–4) | Full pipeline from investigation through implementation (default) |
| **Debugger** | Gate 0, 1, 4 | Root-cause analysis — classify bugs vs. design issues with evidence |
| **Trainer** | Gate 4 (runtime) | Launch training, monitor, fix CUDA/OOM/path errors |

Switch anytime: `/switch researcher`, `/switch engineer`, `/switch debugger`, `/switch trainer`.

## Installation

```bash
git clone https://github.com/KevinBian107/propel.git
cd propel && pip install -e .

cd /path/to/your/project
propel init
```

Then start Claude and run `/intro` to select a mode and set up your project. See the [Getting Started guide](https://kbian.org/propel-website/docs/getting-started.html) for details.

## Documentation

Full documentation is available on the [Propel website](https://kbian.org/propel-website/docs/):

- [Getting Started](https://kbian.org/propel-website/docs/getting-started.html) — Installation and first workflow
- [Core Principles](https://kbian.org/propel-website/docs/core-principles.html) — The five non-negotiable principles
- [Pipeline](https://kbian.org/propel-website/docs/pipeline/) — Gates, questioners, and phase transitions
- [Modes](https://kbian.org/propel-website/docs/modes/) — Researcher, Engineer, Debugger, Trainer
- [Skills](https://kbian.org/propel-website/docs/skills/) — 17 specialized skills by workflow phase
- [Agents](https://kbian.org/propel-website/docs/agents/) — 8 domain-specific auditors
- [Customization](https://kbian.org/propel-website/docs/customization.html) — Project-specific agents, skills, commands
- [Common Pitfalls](https://kbian.org/propel-website/docs/pitfalls.html) — Known failure modes and anti-patterns

## Acknowledgments

Propel combines ideas from: [obra/superpowers](https://github.com/obra/superpowers), [scott-yj-yang/new-prompt](https://github.com/scott-yj-yang/new-prompt), [Talmo's sleap-io](https://github.com/talmolab/sleap-io), [Sionic AI](https://huggingface.co/blog/sionic-ai/claude-code-skills-training), [brunoasm's claude skills](https://github.com/brunoasm/my_claude_skills), [Weizhena's Deep-Research](https://github.com/Weizhena/Deep-Research-skills), and [Context Engineering Template](https://github.com/coleam00/context-engineering-intro).

External plugins bridged by Propel skills: [openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc) (via `/c-codex`), [anthropics/claude-code code-review plugin](https://github.com/anthropics/claude-code/tree/main/plugins/code-review) (via `/c-review`).

Skills vendored directly: [anthropics/skills — frontend-design](https://github.com/anthropics/skills/blob/main/skills/frontend-design/SKILL.md) (see source repo for LICENSE).

## License

MIT — Built by [Kaiwen Bian](https://kbian.org) and [Yuer Tang](https://yuertang.dev/).
