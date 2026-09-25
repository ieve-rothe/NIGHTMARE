# DUSK Design Doc

## Overview
No-human-in-the-loop (NHITL) autonomous harness. DUSK shares a core codebase with the **NIGHTMARE** (HITL) harness but implements a fundamentally different governance model.

## Governance Comparison
| Feature | NIGHTMARE (HITL) | DUSK (NHITL) |
| :--- | :--- | :--- |
| **Interaction** | Interactive TUI / Prompt-driven | Autonomous "Warden Loop" |
| **Approval** | Human-in-the-loop (User approves diffs/commands) | Automated (Verification guards/classifiers) |
| **Sandboxing** | CWD-based isolation | Heavyweight (Bubblewrap + OverlayFS) |
| **Execution** | Reactive to user input | Proactive (Task queue polling) |

## Core Architecture
- **The Warden Loop**: A continuous execution loop that manages task lifecycle, from polling `incoming/` to final commitment.
- **Sandboxing**: Bubblewrap jail for deep isolation.
- **Ephemeral Workspace**: OverlayFS for transient execution.
- **Persistence**: Commit work products to live location only after automated verification.
- **Model Integration**: Calling online models is a fundamental capability to be implemented at the **MANTLE** framework level.

## Key Challenges
- **Safety**: Preventing destructive actions without manual approval via secondary model verification guards or classifier guards.
- **Observability**: Transitioning human role from validator to observer (via TREMOR).
- **Self-Correction**: Implementing internal verification loops and critic agents.
- **Resource Control**: Circuit breakers for infinite loops and context overflow.

## CONOPS
- **Task Queueing**: Manage tasks submitted during model downtime.
- **Auto-scale/Activation**: Spin up model runner based on resource/time triggers.
- **Parallelism**: Distributed execution via online model farming.
- **Scheduling**: Potential `systemd` or `cron` integration for job execution.

## Task Management (Folder-Based)
- **Structure**:
  - `~/.local/share/dusk/incoming/`: Drop task files here (e.g., `ticket_104.md`).
  - `~/.local/share/dusk/processing/`: Active tasks mounted in the sandbox.
  - `~/.local/share/dusk/completed/`: Finished diffs + telemetry logs.
  - `~/.local/share/dusk/failed/`: Breaker trips and incident reports.

## Software Engineering Challenges
1. **Verification Guard Robustness**: How can we guarantee that the automated verification guards and classifiers are sufficiently robust to prevent destructive or unauthorized actions in the absence of human oversight?
2. **MANTLE Integration Architecture**: What is the specific architectural plan for integrating the MANTLE framework to ensure reliable and seamless model-switching capabilities?
3. **Observability vs. Intervention**: How will the system provide real-time, actionable observability (via TREREM) that allows for human intervention without re-introducing the human-in-the-loop bottleneck?
4. **Self-Correction Loop Stability**: How can we implement internal verification loops and critic agents without risking infinite loops of self-correction or "hallucination-driven" regression?
5. **Distributed Execution Consistency**: How will the system manage state consistency and prevent race conditions when executing tasks in parallel via distributed model farming?


## Security & Threat Modeling

1. **Indirect Prompt Injection**: Since the system autonomously processes tasks from the `incoming/` directory, an attacker could provide a maliciously crafted task file containing instructions designed to subvert the Warden Loop, bypass verification guards, or manipulate the agent's behavior.
2. **Automated Guard Bypass**: The reliance on automated classifiers and verification guards instead of human oversight introduces a critical vulnerability where adversarial inputs (e.g., obfuscated code or adversarial examples) could be designed to appear benign to the guards while executing unauthorized or destructive actions.
3. **Sandbox Escape via OverlayFS/Bubblewrap Misconfiguration**: While heavyweight sandboxing is used, any misconfiguration in the Bubblewrap profile or vulnerabilities in the OverlayFS implementation could allow an autonomous task to break out of the ephemeral workspace and gain access to the host filesystem or the `~/.local/share/dusk/` persistent directories.
4. **Resource Exhaustion (DoS)**: An attacker could exploit the autonomous nature of the system by submitting tasks designed to trigger infinite self-correction loops or high-compute "model farming" requests, leading to CPU/memory exhaustion and denial of service for the Warden Loop.
5. **Model Supply Chain & Poisoning**: The integration with external "online models" and "model farming" introduces a dependency on third-party model integrity. Compromised or poisoned models could be used to inject malicious logic into the autonomous execution flow, bypassing the system's internal safety constraints.
