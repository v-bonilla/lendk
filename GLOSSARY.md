# lendk

lendk gives the keys a human keeps in pass to the commands mapped to them, only while those commands run. This glossary names the concepts that its code, tests, docs and issues share.

## Language

### People

**Human**:
A person who runs commands from a terminal and owns the map and the store.
_Avoid_: operator, owner

**Agent**:
An AI assistant that runs commands on a human's behalf, often without a terminal.
_Avoid_: bot; never use it for gpg-agent, which is always written in full

### Keys and the store

**Key**:
A named secret that lendk injects, named by the environment variable that carries it.
_Avoid_: secret, token, API key

**Value**:
The secret text of a key: the first line of its store entry.
_Avoid_: secret, password

**Plaintext**:
A value, the identity, or the passphrase or PIN that protects the identity, held in memory in a form that needs no further decryption.

**GnuPG key**:
The encryption key that protects the store.
_Avoid_: key, on its own

**Store**:
The pass store, holding one store entry per key.
_Avoid_: vault, keychain

**Store entry**:
The encrypted pass file that holds one key's value.
_Avoid_: entry, on its own; secret file

**Locked store**:
The state in which gpg-agent holds no passphrase, so reading a value needs a prompt.
_Avoid_: locked, for anything but the store

**Backend**:
pass, gpg and gpg-agent, as lendk runs them to read values.
_Avoid_: provider, vault

### The map

**Map**:
The file that says which keys each mapped command gets and defines the groups.
_Avoid_: config, manifest; the planning issue of `/wayfinder` is always a "wayfinder map"

**Map entry**:
One line of the map: a group definition, or a mapped command with its keys and groups.
_Avoid_: entry, on its own; mapping, rule

**Group**:
A named list of keys, written `@NAME`, that a map entry can use in place of the keys.
_Avoid_: profile, set

**Mapped command**:
A command the map gives keys to, and which therefore has a shim.
_Avoid_: wrapped command

**Reserved command**:
A command lendk itself runs, which the map can never hold.
_Avoid_: forbidden command

**Guarded command**:
A command that runs other programs, which the map holds only when forced.
_Avoid_: dangerous command, unsafe command

**Denied name**:
An environment variable name that can never be a key, because it steers lendk, pass, gpg, the shell or the loader.
_Avoid_: reserved name, which belongs to commands

### Running a command

**Shim**:
The small script, named after a mapped command, that sits first on PATH and hands the call to lendk.
_Avoid_: wrapper, alias

**Shim directory**:
The directory that holds the shims and comes first on PATH.

**Caller**:
The process that runs a shim or `lendk run`, whose environment the target inherits.
_Avoid_: parent, invoker

**Target**:
The real program lendk execs with the keys injected, reached through a shim or through `lendk run`. Every mapped command becomes a target when it runs; not every target is a mapped command.
_Avoid_: child, wrapped command

**Inject**:
To export the values of keys into the target's environment just before exec.
_Avoid_: lend, outside the name lendk; pass, forward

**Interactive call**:
A call that may prompt for the passphrase, because stdin or stderr is a terminal or prompting is allowed.
_Avoid_: TTY mode

**Write lock**:
The lock that makes writes to the map and the shim directory take turns.
_Avoid_: lock, on its own

### Failures

**Class**:
The one-word failure category on the last line of lendk's stderr, which callers act on.
_Avoid_: error code, exit code

**FIX**:
The next step a failure message names, worded separately for an interactive and a non-interactive call.
_Avoid_: hint, suggestion

### Releases

**Platform**:
An OS and architecture pair that a release ships one archive for.
_Avoid_: target, triple
