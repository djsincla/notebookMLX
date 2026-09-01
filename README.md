# notebookMLX

Drop a document in, ask it questions, and get answers whose citations open the
passage they name.

Embedding happens **on the machine**, through `MLXEmbedders` - the documents
never leave it. Generation is answered by a [dAI](https://github.com/djsincla/dAI)
gateway, which is itself a fleet of local machines, so the same holds there.

## Three repositories, and how they fit

**This one is the app.** It is a client of a dAI fleet, and it shares that
project's fork of Apple's MLX examples rather than borrowing a copy.

```mermaid
flowchart TB
  fork["<b>mlx-swift-examples</b> · MIT<br/>fork of ml-explore's<br/>adds pipeline parallelism for dense Qwen"]
  dai["<b>dAI</b> · Apache-2.0<br/>control plane + node agent<br/>harvests idle Macs, serves models"]
  nb["<b>notebookMLX</b> · Apache-2.0 · you are here<br/>drop a document in, ask it questions"]
  fork -->|"MLXLLM, MLXLMCommon<br/>pinned revision"| dai
  fork -->|"MLXEmbedders<br/>the same pinned revision"| nb
  nb -->|"HTTP: asks the gateway<br/>to generate an answer"| dai
```

| | What it is |
|---|---|
| **[notebookMLX](https://github.com/djsincla/notebookMLX)** | This app. Ingests documents, embeds and indexes them locally, answers with citations that resolve to a page. |
| **[dAI](https://github.com/djsincla/dAI)** | The fleet behind the answers: idle Apple Silicon machines, centrally scheduled, serving models over an OpenAI-compatible gateway. Nothing leaves the building. |
| **[mlx-swift-examples](https://github.com/djsincla/mlx-swift-examples)** | The fork both depend on. `MLXEmbedders` here, `MLXLLM` there, one pinned revision for both. |

Without a gateway configured the app still ingests, embeds and searches - that
part is entirely local. It is generation that needs the fleet.

## Pointing it somewhere other than dAI

It is an ordinary OpenAI client: `POST /v1/chat/completions` with a bearer
token, reading `choices[0].message.content`. So any OpenAI-compatible endpoint
works - set the Gateway field in Settings and put the key in the same place.

Two things to know before you do.

- **Clear the CA certificate path.** With one set the app trusts *only* that
  authority (`SecTrustSetAnchorCertificatesOnly`), which is right for a fleet
  with its own CA and fails every handshake against a public host. Empty means
  the system roots, which is what a public host needs.
- **Name a model.** dAI serves whatever the group is pinned to, so the field is
  optional there; everyone else answers a request without one with a 400. The
  app now refuses before sending rather than passing that back as a refusal
  that reads like a bad key.

**Embedding stays local regardless** - there is no `/v1/embeddings` call
anywhere in this app, and the index never leaves the machine. What travels is
the question and the passages retrieval found for it. That is worth deciding
deliberately rather than discovering, so Settings says so when the endpoint is
not a fleet.

## What it does

- Ingests PDF, plain text and xlsx. A spreadsheet is a zip of XML, which is why
  `CoreXLSX` is a dependency rather than something written here.
- Chunks, embeds and indexes locally, with pooling chosen by model family
  because the conversions do not ship a `1_Pooling` directory to read it from.
- Answers with citations that resolve to a page, and an evidence column beside
  the answer rather than footnotes underneath it.
- Says when an answer was cut off, and what cut it.

## Building

    swift build

The app bundle is assembled by `packaging/make-app.sh`, which wraps the built
executable - a menu-bar-free document app needs an `Info.plist`, and SwiftPM
produces a bare binary.

Command-line tools alongside the app: `notebook-ingest` (one document, with
memory reported as it goes), `notebook-import` (adopt an existing index),
`notebook-reembed` (re-embed keeping chunks and citations), `notebook-verify`
(check this embedder against the agent's fixture), and `notebook-demo`.

## The pinned fork

`Package.swift` pins
[djsincla/mlx-swift-examples](https://github.com/djsincla/mlx-swift-examples) to
an exact revision, and **dAI pins the same one**. Both use `MLXEmbedders`; two
copies at different revisions could pool or normalise differently, and an index
built by one would be silently incomparable with a query from the other. That
is not a failure anything reports, so `Tests` asserts the two agree.

## Security

It parses documents it did not write and holds a gateway key in the Keychain.
[`SECURITY.md`](SECURITY.md) says how to report something, and what those two
facts mean.

## Licence

Apache License 2.0, © 2026 Dwayne Sinclair - see [LICENSE](LICENSE) and
[NOTICE](NOTICE). The pinned fork is MIT and is not covered by that notice.

Model weights are not in this repository and carry their own licences.
