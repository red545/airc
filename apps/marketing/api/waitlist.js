// Waitlist signups. The form on aircbrowser.com posts here; each signup is emailed to hello@aircbrowser.com
// through Resend, with Reply-To set to the person, so the list lives in that inbox. RESEND_API_KEY is a
// send-only key scoped to aircbrowser.com (Vercel environment variable, never in the repo).

const INBOX = "hello@aircbrowser.com";
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export async function POST(request) {
  const form = await request.formData();
  const email = String(form.get("email") ?? "").trim().toLowerCase();

  // A filled hidden field means a bot: say yes and do nothing.
  if (form.get("website")) return redirect("/thanks");
  if (email.length > 254 || !EMAIL.test(email)) return redirect("/try-again");

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${process.env.RESEND_API_KEY}`,
      "Content-Type": "application/json",
      "Idempotency-Key": `waitlist-${email}`,
    },
    body: JSON.stringify({
      from: `Airc waitlist <${INBOX}>`,
      to: INBOX,
      reply_to: email,
      subject: `Waitlist: ${email}`,
      text: email,
    }),
  });
  if (!res.ok) {
    console.error("waitlist: resend", res.status, await res.text());
    return redirect("/try-again");
  }
  return redirect("/thanks");
}

function redirect(location) {
  return new Response(null, { status: 303, headers: { Location: location } });
}
