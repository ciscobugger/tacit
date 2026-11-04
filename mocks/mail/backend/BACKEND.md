# Local mock mail backend

This is a standalone Go service. The existing QML mock is unchanged and is not yet connected to it. No login, OAuth, IMAP, SMTP or provider API is used. “Sent” means accepted by the persistent mock provider, never delivered to the internet.

## Run on macOS or Linux

Requires Go 1.23 or newer. From this `backend` directory:

```sh
go test ./...
go build -o bin/maild ./cmd/maild
./bin/maild
```

The daemon prints its database and socket paths. Defaults:

- macOS database: `~/Library/Application Support/tacit/mail-mock/mail.sqlite`
- Linux database: `$XDG_DATA_HOME/tacit/mail-mock/mail.sqlite`, falling back to `~/.local/share/tacit/mail-mock/mail.sqlite`
- Socket: `tacit-mail-mock/mail.sock` under `$XDG_RUNTIME_DIR` when set, otherwise the platform user cache directory.

Explicit paths are often easier for development. The socket parent must be private and the socket path short enough for macOS:

```sh
mkdir -p /tmp/tacit-mail-dev
chmod 700 /tmp/tacit-mail-dev
./bin/maild --data-dir /tmp/tacit-mail-dev/data --socket /tmp/tacit-mail-dev/mail.sock
```

Stop with Ctrl+C. Restart with the same data directory to retain changes. `--worker-interval=0` disables automatic mock delivery, allowing deterministic tests through `/v1/mock/flush`. `--seed=false` skips fixtures and is mainly useful for tests; there is currently no account-creation API.

An existing socket is never replaced, even if stale. After checking that no daemon owns it, remove a stale socket manually. Do not run multiple daemons against one database using different sockets.

## What works

- Fourteen realistic mock messages, including the Dusk/Moss conversation, two accounts, read/unread flags, a sent reply and attachment bytes.
- One-shot, transactional seeding: subsequent starts preserve read status, folders and drafts.
- Persistent draft create/update, queued sending, simulated delivery failure, explicit retry and cached Sent messages.
- Mock incoming events, paged incremental receive, account-scoped remote deduplication and atomic cursor/cache updates. Remote changes preserve local read, flagged and folder state.
- SQLite FTS5 prefix search over subject, plain-text body, sender, recipients and attachment filenames; account/folder filters and pagination. Queries are literal terms, not a search-language parser. Accents are normalised; results sort newest first.
- Conversation history, read/flag/folder updates, attachment metadata and separate byte download.
- Versioned JSON API over a user-private Unix socket on macOS and Linux. No TCP listener or D-Bus requirement.

Sending a draft requires an idempotency key. Repeating a key for the same draft returns the same job; using it for another draft conflicts. Queued drafts are immutable. The mock provider also deduplicates delivery. After interruption during sending, the job becomes `uncertain`, requiring an explicit retry. A future SMTP adapter cannot promise exactly-once delivery; its reconciliation policy must handle this uncertainty.

## Boundaries for the real backend

`internal/backend.Provider` is the transport boundary. Implement `Receive` and `Send` there, or route accounts to multiple adapters. SQLite, service operations and the local API can remain in place. The current mock's cursor is an event sequence; real adapters must encode provider-specific cursors and stable remote/conversation identities. IMAP needs UIDVALIDITY handling; provider deletion/move reconciliation, MIME parsing, threading, incremental change notifications and provider rate limits are future work.

Other deferred work: credentials/keychain, OAuth, account setup, automatic receive scheduling, MIME/HTML sanitisation, attachment preview generation, cancellation of queued sends, draft deletion, frontend integration and large-mail performance tuning. HTML is opaque data and is never rendered by this service.

The database is not encrypted. Its file and the socket have mode `0600`; newly created directories have mode `0700`. The API rejects browser Origin headers, accepts strict JSON with an 8 MiB request limit and streams binary attachments with a separate 256 MiB per-file upload limit. Access protection is the local OS user boundary, not authentication against other processes running as that user.

## Dependencies and checks

Direct dependency: `modernc.org/sqlite v1.36.3`, pinned for the installed Go 1.23 toolchain; its transitive dependencies are recorded in `go.mod` and `go.sum`. No C compiler is required for the daemon. Network access is only needed to download Go modules, not to run the mock.

```sh
go test ./...
go test -race ./...
go vet ./...
CGO_ENABLED=0 go build -o bin/maild ./cmd/maild
```

Tests were written first and initially failed because the implementation did not exist. They cover restart persistence, seed idempotence, FTS updates and literal input, account filtering, cursor rollback, remote identity isolation, durable outbox, failures, crash uncertainty, concurrent delivery, HTTP validation, attachment download and an actual Unix socket client.

Protocol examples are in [API.md](API.md). Relevant upstream references: [SQLite FTS5](https://www.sqlite.org/fts5.html), [modernc SQLite](https://pkg.go.dev/modernc.org/sqlite), [Go HTTP server](https://pkg.go.dev/net/http#Server.Serve).

## Binary attachment storage

Attachments now live in `<database-path>.blobs/`, next to the SQLite database. SQLite stores an immutable attachment ID, account ownership, filename, MIME type, size and a SHA-256 content digest. Mail, outbox and mock-provider JSON contain metadata only; even normal cache reads no longer load attachment bytes. Identical content shares a single file while separate uploads retain separate account-scoped references and filenames.

Uploads stream through a fixed-size buffer to a private temporary file. Complete files are synced and published atomically before metadata is committed. Failed or oversized transfers remove their temporary file and publish no attachment reference. Downloads stream from an open file and support HEAD and byte ranges via Go's standard HTTP server. `Store.OpenAttachment` is also available to future provider/MIME adapters; they do not need to materialise whole files in memory. The in-process `Attachment.Data` field is only a fixture/import convenience and is excluded from JSON. Real imports can use `UploadAttachment` with a reader.

Schema version 2 automatically extracts legacy Base64 payloads from messages, queued jobs, mock incoming events and mock sent records. The metadata migration is transactional and leaves the old payloads unchanged if it fails. Empty legacy attachments are preserved. Back up the database together with its `.blobs` directory; restoring only SQLite cannot restore attachment bytes. Stop the service before a simple file-copy backup.

The cache currently retains uploaded files and detached references; automatic garbage collection is deferred so queued snapshots and retained mock events cannot lose their bytes. An interrupted metadata commit or migration can leave an unreferenced content file, and a process crash can leave a temporary upload file. These do not become visible through the API. A later collector must account for all message, outbox and provider-event references.

Added test cases cover 12 MiB binary transfer beyond the JSON limit, byte-exact download after sending/restart, metadata-only draft updates, same-content deduplication, account/message reference boundaries, failed/cancelled/oversized uploads, empty files, all four legacy payload tables, migration rollback, HEAD and Range requests. No new dependency was added.
