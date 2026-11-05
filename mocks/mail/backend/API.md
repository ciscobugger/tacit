# Mock mail API v1

Transport: HTTP/JSON over a Unix domain socket. No TCP port. Use `http://localhost` as the HTTP URL with your socket transport. JSON mutation bodies must be a single object with `Content-Type: application/json`; unknown fields are rejected. JSON requests are limited to 8 MiB. Attachment uploads use raw binary bodies instead, with a separate 256 MiB limit per file. Browser Origin headers are rejected.

## Routes

| Method | Path | Behaviour |
| --- | --- | --- |
| GET | `/v1/health` | Status and API version |
| GET | `/v1/accounts` | Seeded accounts: `work`, `personal` |
| GET | `/v1/messages` | `account_id`, `mailbox`, `q`, `limit` (default 50, max 100), `offset` |
| GET | `/v1/messages/{id}` | Message with attachment metadata |
| PATCH | `/v1/messages/{id}` | Optional `unread`, `flagged`, `mailbox` |
| GET | `/v1/conversations/{id}?account_id=work` | All messages in chronological order |
| POST | `/v1/accounts/{account_id}/attachments?filename=report.pdf` | Raw binary upload; Content-Type identifies the file; returns metadata, 201 |
| GET / HEAD | `/v1/messages/{id}/attachments/{attachment_id}` | Stream original bytes; supports HTTP Range (206) |
| POST | `/v1/drafts` | Create draft; returns 201 |
| PUT | `/v1/drafts/{id}` | Replace draft; returns 200 |
| POST | `/v1/send` | `draft_id`, `idempotency_key`; returns durable job, 202 |
| GET | `/v1/outbox/{id}` | Job state, attempts and last error |
| POST | `/v1/outbox/{id}/retry` | `{}`; retry `failed` or `uncertain` job |
| POST | `/v1/sync` | `account_id`; receive one batch (up to 100 events) |
| POST | `/v1/mock/incoming` | `account_id`, `message`; append a mock remote event, 201 |
| POST | `/v1/mock/fail-next-send` | `account_id`; simulate one delivery failure |
| POST | `/v1/mock/flush` | `{}`; synchronously process queued sends |

Errors: 400 invalid input, 404 unknown resource, 409 incompatible state/key reuse, 413 attachment too large, 415 wrong content type, 500 internal failure. The error body is plain text. Successful response bodies are JSON except attachment bytes. Lists return `{messages,total,limit,offset}`. Conversation and account responses are arrays. Repeated sync calls are needed while `has_more` is true.

Job states: `queued` → `sending` → `sent` or `failed`. Restart changes interrupted `sending` jobs to `uncertain`. Only explicit retry requeues a failed/uncertain job. “Sent” is mock delivery only.

`Message` uses snake_case fields. Core fields: `id`, `account_id`, `remote_id`, `conversation_id`, `from:{name,email}`, `to`, `cc`, `bcc`, `subject`, `body_text`, `body_html`, `mailbox`, `unread`, `flagged`, `date` (RFC3339), `attachments`. Optional threading fields: `message_id`, `in_reply_to`, `references`. Attachment response fields: `id`, `filename`, `media_type`, `size`. IDs are opaque. Upload a file first, then use `attachments:[{"id":"RETURNED_ATTACHMENT_ID"}]` in a draft or mock incoming message. References must belong to the same account. Supplied metadata is resolved from the stored reference. For draft updates provide the whole draft with the IDs to retain; omitted attachments are detached. Inline `data` in JSON is rejected. Attachment references and their bytes are immutable, so replacing a file means uploading a new reference. From defaults to the account identity; sending as another identity is rejected. Empty draft bodies/recipients are allowed while editing, but sending requires a recipient.

Folder patches accept `Inbox`, `Archive`, `Trash`, `Junk`; queued drafts cannot be moved. Incoming events require a stable non-empty `remote_id` and valid sender. Their supplied local ID is ignored. Updates to an existing remote ID replace cached content while retaining local read/flag/folder state.

## Try it

Run the daemon with the explicit development paths in BACKEND.md, then:

```sh
socket=/tmp/tacit-mail-dev/mail.sock
curl --unix-socket "$socket" http://localhost/v1/health
curl --unix-socket "$socket" 'http://localhost/v1/messages?account_id=work&q=palette'
curl --unix-socket "$socket" 'http://localhost/v1/conversations/review?account_id=work'
```

Receive an additional mock message (inject first, sync second):

```sh
curl --unix-socket "$socket" -H 'Content-Type: application/json' \
  -d '{"account_id":"work","message":{"remote_id":"demo-1","conversation_id":"demo-thread","from":{"name":"Alex","email":"alex@example.com"},"to":[{"email":"lorenz@tacit.example"}],"subject":"Hello from the mock provider","body_text":"Ready for a local reply.","unread":true}}' \
  http://localhost/v1/mock/incoming
curl --unix-socket "$socket" -H 'Content-Type: application/json' \
  -d '{"account_id":"work"}' http://localhost/v1/sync
```

Create a draft. Copy its returned `id` into the send request:

```sh
curl --unix-socket "$socket" -H 'Content-Type: application/json' \
  -d '{"account_id":"work","conversation_id":"demo-thread","to":[{"email":"alex@example.com"}],"subject":"Re: Hello","body_text":"The local backend works."}' \
  http://localhost/v1/drafts
curl --unix-socket "$socket" -H 'Content-Type: application/json' \
  -d '{"draft_id":"REPLACE_WITH_DRAFT_ID","idempotency_key":"demo-send-1"}' \
  http://localhost/v1/send
```

Poll `/v1/outbox/REPLACE_WITH_JOB_ID`. With the default worker it becomes `sent` shortly. With `--worker-interval=0`, call `/v1/mock/flush` with `{}`. To demonstrate failure, arm `/v1/mock/fail-next-send` before queueing, then inspect the failed job and explicitly retry it.

## Attach a file without Base64

```sh
curl --unix-socket "$socket" \
  -H 'Content-Type: application/pdf' \
  --data-binary @report.pdf \
  'http://localhost/v1/accounts/work/attachments?filename=report.pdf'
```

Use the returned attachment ID when creating or updating a draft:

```sh
curl --unix-socket "$socket" -H 'Content-Type: application/json' \
  -d '{"account_id":"work","to":[{"email":"alex@example.com"}],"subject":"Report","body_text":"Attached.","attachments":[{"id":"REPLACE_WITH_ATTACHMENT_ID"}]}' \
  http://localhost/v1/drafts
```

Download through the message to which it is attached:

```sh
curl --unix-socket "$socket" \
  'http://localhost/v1/messages/REPLACE_WITH_MESSAGE_ID/attachments/REPLACE_WITH_ATTACHMENT_ID' \
  -o report-copy.pdf
curl --unix-socket "$socket" -H 'Range: bytes=0-1023' \
  'http://localhost/v1/messages/REPLACE_WITH_MESSAGE_ID/attachments/REPLACE_WITH_ATTACHMENT_ID'
```

Percent-encode filenames in the upload URL. Directory paths, control characters and filenames longer than 255 bytes are rejected. Empty files are supported. There is no automatic preview generation yet.
