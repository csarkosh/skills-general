# Settings: stop unwanted contact and emails

Cut recruiter InMail, LinkedIn's email copies of it, and calls, and control which emails
LinkedIn sends. Some of the noise has no LinkedIn setting behind it; say so plainly instead of
changing settings that won't help.

## 1. Read everything first

Read each setting below and show the user one table of where it stands today, before proposing
any change. Reading changes nothing.

| Where | URL | What to read |
|---|---|---|
| Visibility | `/mypreferences/d/categories/profile-visibility` | Share profile updates, Discoverability by email, Discoverability by phone number |
| Email visibility | `/mypreferences/d/settings/email-address-visibility` | Who can see the email address; "Allow connection to export emails" |
| Messages you receive | `/mypreferences/d/settings/who-can-message-me` | Message requests, InMail messages, Job invitation messages from recruiters |
| Data privacy | `/mypreferences/d/categories/privacy` | Job seeking preferences: "Share your profile when you click Apply", "Signal your interest to recruiters…" |
| Resumes and application data | `/jobs/application-settings/` | Saved résumés; "Allow recruiters to view your resumes" |
| Notifications → Messaging | `/mypreferences/d/notification-categories/messaging` | Messages, Message reminders, InMail, InMail reminders |
| Notifications → Searching for a job | `/mypreferences/d/notification-categories/searching-for-a-job` | Job alerts, Job recommendations, Career advice |
| Contact info | the profile's "Contact info" link | Whether a phone number or email is on the profile |
| Open to Work | the card under the profile's intro | Who it's visible to |

Each notification row opens a page with **In-app**, **Push** and **Email** switches (and an email
frequency). The Messaging rows open `/mypreferences/d/notification-subcategories/` pages named
`direct-messages`, `direct-message-reminders`, `inmail` and `inmail-reminders`. Other names
aren't guessable (a wrong one lands on `/mypreferences/page-not-found`), so open rows through the
list. The contact-info overlay URL redirects to the profile; use the "Contact info" link.

LinkedIn members can always message the user's 1st-degree connections; there is no setting for it.

## 2. Say where the noise comes from

| Noise | Source | What helps |
|---|---|---|
| Email copies of InMail | `inmail-hit-reply@linkedin.com`, one per InMail | Email off on InMail and InMail reminders |
| Email copies of replies in threads | `hit-reply@linkedin.com` | Email off on Messages and Message reminders |
| Recruiters emailing the user directly | If email visibility is "Only visible to me", not LinkedIn: scraping and contact-data tools | No LinkedIn setting. A mail filter, or opt-outs as for calls |
| Phone calls | If contact info has no phone and "Discoverability by phone number" is Nobody, not LinkedIn | No LinkedIn setting. See below |

**Calls.** Numbers usually come from contact-data services recruiters use alongside LinkedIn,
such as Apollo, ZoomInfo, ContactOut, RocketReach, Lusha and SignalHire. Each has an opt-out form.
Those forms take personal data, so fill one only with the user's explicit yes for that form.
Suggest the phone's own setting for silencing unknown callers.

**Why so many recruiters**, when the user asks. Offer these as likely causes, not certainties:
Open to Work shown to recruiters; a headline or keywords that match the outreach (for example
"founding engineer" draws early-stage startup pitches); replying to many recruiters, especially
with "glad to stay in touch", which invites follow-ups; recent profile edits.

## 3. Propose changes as choices

Every change needs the user's yes. Changes that also cut off opportunities are the user's call,
so offer them as options with the trade-off:

- **Email off, in-app and push on**, for InMail, InMail reminders, Messages and Message
  reminders. Stops the email copies; the messages still arrive on LinkedIn.
- **InMail messages off.** Strangers can't InMail the user at all, good roles included.
- **Job invitation messages from recruiters off.** Stops job-card pitches only.
- **Open to Work** visible only to the user (below).
- **Job alert and recommendation emails off.** Not recruiters, but part of the pile.

## 4. Change one setting at a time

Flip only the approved switch, then read the page again and confirm it shows the new value.

### Open to Work, without deleting it

| Trap | Do this |
|---|---|
| The only visible way off is **"Delete job preferences"**, which erases the saved titles, locations and job types | Don't use it. Edit the Open to Work card, press the **Visibility** pencil, choose **"Visible only to you"**, and Save. The recruiter signal goes; the preferences stay |
| The delete dialog's "Save as visible only to you" link may not respond | Cancel, and use the Visibility pencil instead |
| Deleting is still what the user wants | It's a delete: get its own explicit yes first |

Reload the profile and confirm the card reads "Open to work · Visible only to you". Nobody is
notified.

## Finish

Report a before/after table, what was left on and why, and anything no LinkedIn setting can fix
(direct recruiter email, calls).
