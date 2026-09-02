# Security

## Reporting a vulnerability

Use GitHub's **[private vulnerability reporting](https://github.com/djsincla/notebookMLX/security/advisories/new)**
on this repository, rather than opening a public issue.

One maintainer, no SLA, no bounty.

## What this software touches

**It parses documents it did not write.** PDF, plain text and xlsx, through
PDFKit and CoreXLSX. A malicious document is the obvious attack surface, and
neither parser is sandboxed by this app beyond what the platform provides.

**It holds a gateway API key.** In the Keychain, as
`com.dai.notebookmlx.gateway` / `api-key`, with
`kSecAttrAccessibleWhenUnlocked` - not in `UserDefaults`, where a key would be
readable by anything running as that user, kept in Time Machine backups, and
visible in a screen share. The accessibility class means it cannot be read from
a sleeping laptop.

## What stays on the machine

Embedding runs locally through `MLXEmbedders`; documents and the index they
produce are never sent anywhere. Generation is answered by whichever
[dAI](https://github.com/djsincla/dAI) gateway is configured - a fleet of local
machines in the intended deployment, but it is a network call, and the prompt
and retrieved passages go over it.

## Supported versions

The most recent commit on `main`. This is a research project with no release
process yet.
