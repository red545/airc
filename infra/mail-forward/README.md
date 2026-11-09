# mail-forward

Forwards mail sent to any address at aircbrowser.com (hello@ and the waitlist signups) on to the owner's
mailbox. aircbrowser.com receives through Resend; a Resend webhook on `email.received` calls
`api/resend.js`, which forwards the original message unchanged.

Deployed as its own Vercel project, `airc-mail-forward` (in the owner's Vercel team), so it doesn't depend on the
homepage going live. Its environment variables live only in Vercel:

| Variable | What |
|---|---|
| `RESEND_API_KEY` | Full-access key for the Resend team that owns aircbrowser.com (reads received mail) |
| `RESEND_WEBHOOK_SECRET` | Signing secret of the `email.received` webhook; unsigned requests get a 401 |
| `FORWARD_TO` | Where mail goes, comma-separated |

Redeploy: `cd infra/mail-forward && vercel deploy --prod --scope <owner-team>`.

Keep the project disconnected from Git. Connected, every push to main redeploys it from the repo root, which has
no `api/resend.js`: the endpoint answers 404 and mail stops forwarding (happened 2026-11-08; the missed
webhook events were replayed with `resend webhooks events replay`).
