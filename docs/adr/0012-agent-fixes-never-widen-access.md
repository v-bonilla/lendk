# A non-interactive FIX never widens access

Every class has two FIX texts, one for an interactive call and one for a non-interactive call, and a non-interactive call is most often an agent that follows its FIX as written. An agent must be able to diagnose a failure without seeing a value and without being told to widen access. So no non-interactive FIX tells it to run `lendk add`, `lendk rm`, `lendk run` with keys, `lendk upgrade` or `pass`, or to print the environment: those steps widen what a command or the agent can reach, put values into the agent's context, or replace the file that reads every key, and each is the human's decision. A non-interactive FIX sends the agent to the human instead: it says to stop and ask, to ask the human to run `lendk unlock` in a terminal, or to install a missing command or ask.

## Considered Options

- One FIX for every caller: the interactive FIX texts name steps a human at a terminal may well take, such as `lendk add --force`, `lendk rm` or `pass insert`. One text would either hide those steps from humans or hand them to agents.

## Consequences

- `lendk check` follows the same rule: its non-interactive FIX is "ask the user", except `lendk sync`, which only rewrites the shims to match the map, and `lendk run -- CMD`, which gives CMD only its mapped keys.
- The `usage` FIX and the `lendk-missing` FIX are the same for every caller, since neither widens access; the second tells the human to reinstall lendk from its project repository ([ADR 0015](0015-install-only-from-project-repo.md)).
- `run_lendk` in `test/helpers/common.bash` fails any test whose non-interactive stderr names one of these steps.
