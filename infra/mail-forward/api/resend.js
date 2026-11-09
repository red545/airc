// Forwards every email received at aircbrowser.com to the owner's mailbox. Resend calls this webhook on
// email.received; the forward passes the original message through untouched, attachments included.
// Environment (Vercel, never in the repo): RESEND_API_KEY (full access, reads received mail),
// RESEND_WEBHOOK_SECRET (the webhook's signing secret), FORWARD_TO (comma-separated addresses).

import { Resend } from "resend";

const FROM = "Airc <hello@aircbrowser.com>";
const resend = new Resend(process.env.RESEND_API_KEY);

export async function POST(request) {
  const payload = await request.text();
  let event;
  try {
    event = resend.webhooks.verify({
      payload,
      headers: {
        id: request.headers.get("svix-id") ?? "",
        timestamp: request.headers.get("svix-timestamp") ?? "",
        signature: request.headers.get("svix-signature") ?? "",
      },
      webhookSecret: process.env.RESEND_WEBHOOK_SECRET,
    });
  } catch {
    return new Response("bad signature", { status: 401 });
  }
  if (event.type !== "email.received") return new Response("ignored");

  const to = process.env.FORWARD_TO.split(",").map((s) => s.trim()).filter(Boolean);
  const emailId = event.data.email_id;
  // Resend retries a webhook that fails; the idempotency key keeps a retry from sending a second copy.
  const { error } = await resend.emails.receiving.forward(
    { emailId, to, from: FROM },
    { idempotencyKey: `forward-${emailId}` },
  );
  if (error) {
    console.error("forward", emailId, error);
    return new Response("forward failed", { status: 500 });
  }
  return new Response("forwarded");
}
