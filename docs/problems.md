# Problems Found in the ACP Agent Integration

## High priority

### ACP file and terminal requests bypass permission prompts

The ACP client automatically executes `fs/read_text_file`, `fs/write_text_file`, and `terminal/create` requests. Permission prompts are handled only for explicit `session/request_permission` messages, so an agent can read or modify files and run shell commands without a user decision.

Relevant code:

- `Sources/AnyDiffCore/ACP/ACPClient.swift:313`
- `Sources/AnyDiffCore/ACP/ACPClient.swift:315`
- `Sources/AnyDiffCore/ACP/ACPClient.swift:332`
- `Sources/AnyDiffCore/ACP/ACPClient.swift:351`

This also contradicts the README statement that live tool calls are subject to permission choices. The implementation should require explicit approval for writes and terminal execution, and ideally for reads outside the opened project.

### Path resolution is not confined to the opened working directory

`resolvePath` accepts absolute paths and does not reject relative paths containing `..`. An ACP agent can therefore access paths outside the project, including through file-system requests and terminal working directories.

Relevant code:

- `Sources/AnyDiffCore/ACP/ACPClient.swift:405`
- `Sources/AnyDiffCore/ACP/ACPClient.swift:360`

Paths should be normalized and checked against the resolved working-directory boundary, unless the user explicitly approves an external path.

## Medium priority

### Explicit tool-result updates are discarded

The handler recognizes `tool_result`, `tool_call_result`, `tool_end`, and `tool_complete` in a switch below, but the preceding guard does not classify them as tool events. Those updates return early and never update the tool card's output or status.

Relevant code:

- `Sources/AnyDiffCore/Agent/ACPAgentSessionManager.swift:412-418`
- `Sources/AnyDiffCore/Agent/ACPAgentSessionManager.swift:544-560`

Add the result event types to `isTool`, then add regression coverage for a running tool transitioning to completed or failed with output.

## Validation

- `swift test -c debug --filter AnyDiffCoreTests --skip Performance` — passed, 105 tests; 1 network test skipped.
- `git diff --check` — passed.
