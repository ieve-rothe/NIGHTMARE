# NIGHTMARE LLM Harness

Tagline: It's a human-in-the-loop terminal-computer-use LLM harness written in crystal lang, resident in ~25 MB RAM.
The shorter tagline: It's like Claude Code, except cheaper ...and worse!

General CONOPS:
* Terminal interface; Navigate to work directory in shell, run 'nightmare', bot loads with cwd as its cwd.
* Bots get file read/write/search, a (guarded) shell execute, and (depth controlled) subagent delegation. Surely that's enough for anybody...
* Basic chat loop interface, bot is allowed to spin on tool loops up to N (configurable) iterations, user approves diffs / shell commands, return to user for next prompt.
* This tool doesn't leave any in-repo litter. There is XDG-directory-centralized observability/event logging and state storage, segmented based on cwd at harness boot. (Centralized harness data storage can be disabled by config or flag).
* A handful of useful commands for inspecting and managing harness state are provided at the terminal prompt interface - see /help

Agent execution security:
* This is meant to be a 'human in the loop' harness for prototyping workflows and giving a bot (especially with an orchestrator farming work out) the leeway to go off on a long-running task, but ... they're on a leash. (They don't know about the leash... don't tell em plz)
* SO ...
  * Within-cwd, file/directory reads, grep search and creation of new files is allowed without human approval
  * A few sensitive directory / file types are guarded and can never be read by the agent (eg .git/*, .env*)
  * File writes (other than new) require diff approval
  * Subagent delegation is allowed without human approval
  * Shell commands are all prompt-guarded by default, but there is an allowlisting option in the guard prompt

Context Management:
* Assembled context for each turn intended to be maximally visible to the human - it's just ...
    * whatever system prompt you load the harness with or set, plus
    * any files you've pinned to context manually, plus 
    * a very limited set of user-configurable ephemeral data (eg today's date), plus 
    * whatever the bot has dragged in.
* No fancy memory mechanisms are provided. The context store is a sliding store with some extra logic to keep the triggering user message for the current turn from getting deleted during tool execution / final response for that same turn. But other than that, overflow just silently falls off the back end.
* NIGHTMARE is designed for local models (the author's development system allocates up to 20GB VRAM for model use, including KV store, with about ~10,000 tokens as a soft upper limit on a useful session)
* Within-turn token management - To accomodate long series of tool calls and file reads, and to prevent busting context when reading large files, the harness will trim 'non-essential' parts of the within-turn context in an attempt to let the LLM finish whatever it's trying to do during that turn. (They still frequently bust context, eg by spending 10 kilotokens thinking. That was the whole budget, my guy... ya thought yourself to death.)

Observability:
* By default (but able to be disabled in settings), the harness logs every call to the LLM model in a jsonl file for review. The logging behavior is implemented at the client level to ensure that all chat interactions, tool calls, and subagent actions are captured across the harness.
* The jsonl can be loaded in TREMOR, the observability tool within the MANTLE ecosystem -- or your favorite codebot can easily create an interface suited to your needs if given the file. (TBH, NIGHTMARE may not be your favorite codebot, depending on the current year and your available computing resources.)

---

## Quickstart

### System Prerequisites

- [Crystal](https://crystal-lang.org/) (>= 1.21.0)
- [Ollama](https://ollama.com/) running locally (`http://127.0.0.1:11434`) with a model installed (e.g. `qwen2.5-coder:7b`, `gemma4:26b`, etc.)

### Dependencies

- [MANTLE](https://github.com/ieve-rothe/mantle) -- MANTLE is the base framework which provides basic connection, execution, context management, and tool calling functionality.
- [salamander](https://github.com/ieve-rothe/salamander) -- Salamander is a companion framework, containing reusable terminal UI elements for Mantle applications, stuff that didn't really seem like it was in scope of Mantle but I don't know anything about like submodules or whatever so, it's a separate repo.

### Build

```bash
shards build
```

The compiled binary will be placed at `bin/nightmare`.

### Run

```bash
# Launch in the current directory with default model
bin/nightmare

# Launch with a specific model
bin/nightmare -m gemma4:26b

# Launch targeting a specific workspace directory
bin/nightmare /path/to/project

# Launch with a custom system prompt file
bin/nightmare -s /path/to/custom_prompt.md

# Launch in zero-footprint ghost mode
bin/nightmare --no-logs
```

---

## Documentation

Check out the [User's Guide](USERS_GUIDE.md)!
