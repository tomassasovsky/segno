# Prompting basis

The owner confirmed **Claude Fable 5.1**. The official [model overview](https://platform.claude.com/docs/en/models/fable-5-1/overview) identifies `claude-fable-5-1`. Guidance was checked on September 9, 2026.

The [Fable 5.1 prompting guide](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-fable-5-1) informs the prompt's explicit completion criteria, concise progress updates, independent-call batching, targeted edits and preservation of decisions and next steps during long work. The entry prompt links a context pack rather than repeating the entire conversation. Product requirements come from the owner's accepted designs, not from Anthropic.

The general [prompting best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices) support clear task boundaries, structured context and concrete success conditions. Accordingly, the handoff distinguishes accepted behavior, executable examples, implementation evidence and unresolved sources. These sections are ordinary Markdown, suitable for a coding agent with repository access.

Start with the model's default **high** effort, then evaluate cost and quality on real slices before changing it. This is a suggested host setting, not a magic phrase in the prompt. An API harness must preserve conversation history and returned thinking blocks as required by Anthropic, and configure progress visibility if needed. The prompt cannot configure the host, grant tools, bypass approvals or prove hardware behavior.

No benchmark was run comparing prompt variants; this is a source-informed handoff, not a claim of optimal token efficiency.
