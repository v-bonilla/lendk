# Security policy

## Supported versions

The latest 1.x release gets security fixes.

## Reporting a vulnerability

Report it privately through GitHub's "Report a vulnerability" form: https://github.com/v-bonilla/lendk/security/advisories/new

Do not open a public issue or pull request for a vulnerability.

Include:
- the lendk version (`lendk --version`)
- the OS, and the bash and GnuPG versions
- the steps to reproduce
- what was exposed, and where

Never include a real key value. A made-up value shows the problem as well.

## What counts

The security model is section 3 of `docs/prd.md`. A vulnerability is:
- a key value reaching a process, file, argv or lendk output it should not (section 3 "Protects against", FR20)
- the installer accepting an archive whose checksum does not match (FR40)

The cases under "Does not protect against" in section 3 are outside the model.
