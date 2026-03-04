---
name: Reviewer (Opus)
description: Subagent controlled by * Code Review Orchestrator (NO STANDALONE USE)
tools: ['search', 'read/problems', 'read/terminalLastCommand', 'web/githubRepo', 'io.github.upstash/context7/*', ]
model: Claude Opus 4.6 (copilot)
handoffs:
  - label: Fix Issues
    agent: agent
    prompt: Fix the issues identified in the code review above.
    send: false
---