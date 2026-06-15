# Mira — Privacy Policy

**DRAFT — needs review by a licensed attorney before publication.** This is an
engineering-accurate starting point describing what the app actually does (mapped
from the codebase), not legal advice. Fill the bracketed placeholders, have
counsel review, then host it at a stable URL and link it from the app + App Store
/ download page.

**Effective date:** [DATE]
**Provider:** [LEGAL ENTITY NAME] ("Mira", "we", "us")
**Contact:** [PRIVACY CONTACT EMAIL]

---

## 1. Overview
Mira is a macOS assistant that sees your screen, listens for voice commands, and
helps you act across your apps. Because it works by observing your screen and
audio and sending relevant context to AI services, this policy explains exactly
what is collected, where it goes, and your choices.

## 2. What we collect

**You provide / we capture to operate the assistant:**
- **Screen captures** — images of your screen, taken when you ask for on-screen
  guidance (Point-and-Ask, lessons) or use voice with screen context. Used to
  locate UI elements and answer questions about what's visible.
- **Microphone audio / voice** — captured while you hold push-to-talk or use a
  voice session, to transcribe speech and respond.
- **Text you type** — prompts, chat messages, and lesson input.
- **App/context data** — calendar events (via macOS EventKit), the active
  browser tab (via Apple Events), and content from apps you connect (below),
  used only to fulfill your request.

**Account & billing:**
- **Account data** — email and authentication credentials, managed by our auth
  provider (Supabase). Plan/subscription status. [If/when payments ship: handled
  by Stripe; we do not store full card numbers.]

**Automatically collected:**
- **Product analytics** — feature usage events and, if you are signed in, your
  user id, email, and name, via PostHog. Used to understand usage and improve the
  product. (See §6 for opt-out.)
- **Diagnostic logs** — local logs for troubleshooting.

**Stored locally on your Mac (not sent to us):**
- Your learning journal / lesson progress, telemetry, and skill bundles, in
  `~/Library/Application Support/Mira/`.

## 3. How we use it
To provide on-screen guidance and answers; transcribe and respond to voice; run
agents and connected-app actions you request; maintain your account and plan;
secure and rate-limit the service; and improve the product via aggregate
analytics. We do **not** sell your personal information. We do **not** use your
prompts, audio, or screen captures to train our own models.

## 4. AI and integration sub-processors
To function, Mira sends the minimum necessary content to:
- **Anthropic** (Claude) — text + screenshots for reasoning and guidance.
- **OpenAI** — voice (Realtime) and text chat.
- **AssemblyAI** — speech-to-text transcription.
- **Composio** — brokers connections to third-party apps you choose to connect
  (e.g. Gmail, Google Calendar, Slack, GitHub, Notion). You authorize each via
  that provider's own OAuth; you can disconnect any at any time in Settings.
- **Supabase** — account/auth and backend services.
- **PostHog** — product analytics.

Each processes data under its own terms and privacy policy. We route AI requests
through our backend so that only the content needed for your request is sent.

## 5. Permissions Mira requests (macOS)
- **Screen Recording** — to see your screen for guidance. Captures occur for the
  specific request; we exclude Mira's own windows.
- **Microphone** — for voice sessions.
- **Accessibility** — to locate on-screen elements precisely.
- **Calendars** — to show and reference your events.
- **Apple Events / Automation** — to read the active browser tab and assist
  across apps.
You can grant or revoke each in System Settings → Privacy & Security. Revoking a
permission disables the related feature.

## 6. Your choices and rights
- **Analytics opt-out** — [describe the in-app toggle / mechanism].
- **Disconnect integrations** — Settings → Integrations → Disconnect.
- **Delete your account/data** — contact [PRIVACY CONTACT EMAIL]; we will delete
  account and server-side data we hold. Local data is removed by deleting
  `~/Library/Application Support/Mira/` (or uninstalling).
- **Access/correction & regional rights** — depending on your location (e.g.
  GDPR/EEA, UK, CCPA/California), you may have rights to access, correct, delete,
  or port your data, and to object to certain processing. Contact us to exercise
  them.

## 7. Data retention
Account and plan data: kept while your account is active. Analytics: [retention
window]. Server-side request metering: [retention window]; we do **not** store
the content of your AI requests server-side beyond what's needed to fulfill them.
Local data: until you delete it.

## 8. Security
Secrets and provider API keys are held server-side, not in the app. Traffic is
encrypted in transit (TLS). Access to backend data is restricted. No system is
perfectly secure; we work to protect your data and will notify you of breaches as
required by law.

## 9. Children
Mira is not directed to children under [13/16] and we do not knowingly collect
their data.

## 10. International transfers
Your data may be processed in the United States and other countries where we or
our sub-processors operate, with appropriate safeguards where required.

## 11. Changes
We may update this policy; material changes will be notified in-app or by email,
and the effective date above will change.

## 12. Contact
[LEGAL ENTITY NAME], [ADDRESS]. Questions: [PRIVACY CONTACT EMAIL].
