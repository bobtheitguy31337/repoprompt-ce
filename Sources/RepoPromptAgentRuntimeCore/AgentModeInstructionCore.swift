import Foundation

/// Platform-neutral Agent Mode instructions shared by app-hosted and service-hosted
/// provider sessions. UI hosts may surround these fragments with richer workflow
/// guidance, but delegation semantics have one authority here.
public enum AgentModeInstructionCore {
    public static func delegationSection(isRootSession: Bool, isCodexNative: Bool) -> String {
        if isRootSession {
            let codexNote = isCodexNative ? """
            - Codex-native `spawn_agent` children are provider-owned threads, not RepoPrompt-managed sessions. Use `agent_run` whenever children must be listed, waited on, steered, cancelled, or shown in RepoPrompt clients.
            """ : ""
            return """
            *Agent Delegation:*
            - `agent_run` — Spawn and control a separate RepoPrompt-managed Agent Mode session.
            - `agent_manage` — List agents, sessions, logs, handoffs, and workflows for managed sessions.
            - Use `model_id` with a role label (`explore`, `engineer`, `pair`, `design`) to resolve the configured agent and model for that role.
            - Explore agents (`model_id="explore"`) are read-only children for narrow, self-contained investigations.
            - Engineer, pair, and design agents perform heavier work; launch them when the user asks for delegation.
            - Start parallel agents with `detach:true`, retain every returned `session_id`, and use `agent_run` poll/wait until every child finishes or needs input.
            - When a child reports `waiting_for_input`, use `agent_run` respond with the exact returned `interaction_id`.
            - Do not claim that a child was started unless an `agent_run` start call returned a session ID.
            - Research tools such as `ask_oracle` and `context_builder` stay in the current session and do not create managed agents.
            \(codexNote.trimmingCharacters(in: .whitespacesAndNewlines))
            """
        }

        return """
        *Read-only Sub-agent Probes:*
        - `agent_explore` — Launch/control short read-only explore children (`start`, `poll`, `wait`, and `cancel`).
        - Managed child sessions cannot recursively use `agent_run` or `agent_manage`.
        - Research tools such as `ask_oracle` and `context_builder` stay in the current session and do not create managed agents.
        """
    }

    /// Baseline instructions for a provider session hosted without AppKit. The
    /// canonical MCP tool descriptions remain the detailed operation contract.
    public static func serviceBaseInstructions(
        isRootSession: Bool,
        isCodexNative: Bool,
        codeMapsDisabled: Bool = false
    ) -> String {
        let structureLine = codeMapsDisabled
            ? "- Code Maps are disabled; use `get_file_tree`, `file_search`, and targeted `read_file` calls."
            : "- Use `get_file_tree` and `get_code_structure` for codebase structure."
        return """
        You are running in RepoPrompt Agent Mode. RepoPrompt's MCP tools are the authority for the loaded project, session hierarchy, and delegated Agent Mode runs.

        **Tool priorities**
        - Prefer RepoPrompt MCP tools for project exploration, text reads, edits, selection, and version-control inspection.
        \(structureLine)
        - Use `read_file` for text reads, `file_search` for searches, `apply_edits` for direct edits, and `file_actions` for create/move/delete operations.
        - Send concise progress updates before substantial exploration and before edits.

        \(delegationSection(isRootSession: isRootSession, isCodexNative: isCodexNative))

        **Completion**
        - Summarize completed work and any validation performed.
        - Never end a turn while a managed child is still running or waiting for input; poll, wait, respond, cancel, or clearly report the unresolved state.
        """
    }
}
