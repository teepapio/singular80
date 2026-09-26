# Moderation & reporting — how suggestions are handled

> **Draft.** This is the internal process document referenced by the Terms of
> Use and by the Play Console's User-Generated Content policy. It exists so the
> moderation claim in the Play listing is true, and so there is a real answer to
> a reviewer's question "how do you moderate?".
>
> Replace every `[[PLACEHOLDER]]`.

## What counts as user-generated content in Singular 80

Exactly one thing: **the text of player suggestions** sent through the in-app
dialog to the backend, plus the author name the player types.

* The suggestions are **not** shown to other players in the app.
* Only the main menu ticker shows *implemented* suggestions, and only after a
  suggestion has been built into a release.
* The app has **no** user-to-user interaction: no direct messages, no user
  profiles, no public feeds. That removes the need for an in-app blocking
  function — the Play policy requires one only for features that allow 1:1
  interaction or publicly accessible UGC.
* Photos, video, audio, precise location and contacts are never collected — the
  app requests only `INTERNET` and `VIBRATE`.

## Play's requirements and how Singular 80 meets them

| Play requirement (UGC policy) | How it is met |
|---|---|
| Users accept terms before creating/uploading UGC | The suggestion dialog links to the Terms of Use; a suggestion can only be sent after the dialog's confirmation. Screenshot of the dialog: add to the store listing documentation. |
| Terms define objectionable content and prohibit it | `legal/terms-of-use.en.md` §4 |
| Ongoing moderation, in-app reporting of content | Single-operator review queue; reporting by e-mail (`[[MODERATION_EMAIL]]`) — see the limitation below |
| In-app blocking of users | Not applicable: there is no 1:1 user interaction and no user accounts |
| Safeguards against monetisation of objectionable behaviour | The app is free, has no ads and no in-app purchases, so nothing can be monetised |
| Accurate answers in the content rating questionnaire | "User-generated content: yes — the app can receive free-form text" must be answered truthfully, see `docs/COMPLIANCE.md` |

## Known gap: reporting is not yet in-app

Play asks for an *in-app* system for reporting objectionable content. As
implemented, reporting currently happens by e-mail. Two ways to close the gap,
in order of effort:

1. **Add a "Report suggestion" affordance** — the smallest honest version: the
   dashboard that lists suggestions gains a report button, and reports land in
   the same queue as e-mail reports. This satisfies "reporting functionality"
   in the sense Play means for a moderated single-operator service, because the
   report happens where the content is.
2. **Block the feature for the first closed test.** During the closed test the
   suggestion feature is off by default (the app starts with no server address),
   so no UGC is collected at all from the general public. If the closed-test
   build ships with the suggestion feature unreachable, the UGC declaration can
   honestly be "no", and the feature can be enabled later together with the
   reporting function.

**Recommendation:** ship the closed test with the suggestion feature off (the
app already defaults to offline) and add the report function before enabling it
for the public. Document the choice in the Play Console answer.

## Process for accepted reports

1. **Acknowledgement** — the reporter gets a reply within 3 working days.
2. **Assessment** — the operator decides within 7 days whether the content
   breaks §4 of the Terms.
3. **Action** — reject (hidden from the implementation backlog), edit (only
   with the reporter's consent, noted in the record), or remove (deleted from
   the database entirely, and the author is told).
4. **Escalation** — threats, sexual content involving minors, or personal data
   of third parties are reported to the relevant authorities immediately and
   are removed before the assessment, not after.
5. **Record** — every report is logged with date, content, decision and action
   so a Play reviewer can be shown a real audit trail.

## What the operator does proactively

* The dashboard shows every incoming suggestion before it can be implemented.
* Nothing from the backlog is published without a human deciding that it is
  implemented.
* Server logs are deleted automatically on a short cycle, so connection data
  does not accumulate.
* Suggestions are never forwarded to third parties or used for advertising —
  there is no advertising.
