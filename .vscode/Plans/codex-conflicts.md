# Plan: Codex Conflicts

## Problem

Currently copilot is still seeing `AGENTS.md` instructions and also dropping the `.github\skills` in favor of `.agents\skills`.  Need a way to provide codex format instructions/skills that might have codex specific syntax/language AND be able to provide variant that Claude/Copilot understand.

Currently `AGENTS.md` merges all instructions into one with `###### HEADER START #######` type gate.  Worth trying to put something like this?

```
---
ignored: true
user-invocable: false
disable-model-invocation: true
---

The YAML front matter above applies only to GitHub Copilot. Codex must ignore that metadata and follow all instructions below.
```

Above probably valid for repo specific instructions, but for global instructions where codex might be used outside of KAT intended projects, it might be wrong and they might want copilot to read it?

**HARD STOP**: Need to grill-me to see if fixing this is even possible.