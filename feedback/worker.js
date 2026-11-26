// Lensy feedback: the app's "Send Feedback…" window posts here, and the message is emailed to the developer
// through Cloudflare Email Routing. Runs at https://api.getlensy.app/feedback.
//
// Bindings (set in Cloudflare, not in this repo):
//   MAIL — send_email binding, locked to the one verified destination address
//   TO   — that same address, as a secret
import { EmailMessage } from "cloudflare:email";

const MAX_MESSAGE = 5000;
const PER_HOUR = 5;                      // per IP

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

const base64 = (text) => {
  const bytes = new TextEncoder().encode(text);
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
};

export const validEmail = (s) => s.length <= 200 && /^[^\s@<>"]+@[^\s@<>"]+\.[^\s@<>"]+$/.test(s);
const clean = (s, max) => String(s ?? "").replace(/[\r\n]+/g, " ").trim().slice(0, max);

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== "/feedback") return json({ error: "Not found" }, 404);
    if (request.method !== "POST") return json({ error: "Use POST" }, 405);

    let body;
    try { body = await request.json(); } catch { return json({ error: "Invalid request" }, 400); }
    if (body.website) return json({ ok: true });                       // honeypot: bots fill every field

    const email = String(body.email ?? "").trim();
    const message = String(body.message ?? "").trim();
    const app = clean(body.app, 120);
    if (!validEmail(email)) return json({ error: "Please enter a valid email address." }, 400);
    if (message.length < 2) return json({ error: "Please write a message." }, 400);
    if (message.length > MAX_MESSAGE) return json({ error: `Please keep it under ${MAX_MESSAGE} characters.` }, 400);

    // a gentle per-IP limit, kept in the edge cache
    const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
    const key = new Request(`https://rate.getlensy.app/${encodeURIComponent(ip)}`);
    const seen = await caches.default.match(key);
    const count = seen ? parseInt(await seen.text(), 10) || 0 : 0;
    if (count >= PER_HOUR) return json({ error: "Too many messages — please try again in an hour." }, 429);
    await caches.default.put(key, new Response(String(count + 1), { headers: { "cache-control": "max-age=3600" } }));

    const country = request.cf?.country ?? "?";
    const text = `${message}\n\n—\nFrom: ${email}\n${app}\nCountry: ${country}\n`;
    const raw = [
      `From: Lensy Feedback <feedback@getlensy.app>`,
      `To: <${env.TO}>`,
      `Reply-To: <${email}>`,
      `Subject: =?UTF-8?B?${base64(`Lensy feedback — ${email}`)}?=`,
      `Message-ID: <${crypto.randomUUID()}@getlensy.app>`,
      `Date: ${new Date().toUTCString()}`,
      `MIME-Version: 1.0`,
      `Content-Type: text/plain; charset=UTF-8`,
      `Content-Transfer-Encoding: base64`,
      ``,
      base64(text).replace(/.{76}/g, "$&\r\n"),
    ].join("\r\n");

    try {
      await env.MAIL.send(new EmailMessage("feedback@getlensy.app", env.TO, raw));
    } catch (error) {
      console.log("send failed", String(error));
      return json({ error: "Couldn’t send right now — please try again later." }, 502);
    }
    return json({ ok: true });
  },
};
