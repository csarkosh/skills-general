# Profile: audit and quiet edits

Make a LinkedIn profile match a source the user trusts **without LinkedIn announcing anything**.
Most edit forms have a switch that shares the change with the user's network, and several are **on
by default** even when the account-wide setting is off. The work is mostly spotting those switches
before every save.

## 1. Audit before touching anything

1. **Read the source of truth** the user named: their site, résumé or notes. Take facts only from
   there, and follow the source's own rules (for example, a site that leaves out metrics or
   customer names).
2. **Read the profile** at `https://www.linkedin.com/in/<id>/`. Sections load as you scroll. Full
   lists are at `/in/<id>/details/experience/`, `/details/projects/`, `/details/skills/`,
   `/details/courses/`, `/details/featured/` and `/details/interests/`; contact info at
   `/in/<id>/overlay/contact-info/`.
3. **Report the gaps** as a table (LinkedIn today against the source), then recommendations in
   order of impact, with exact copy the user can paste.

## 2. Make it quiet, and check again before every session

- **Account-wide:** Settings, Visibility, "Share profile updates" must read **Off**
  (`https://www.linkedin.com/mypreferences/d/categories/profile-visibility`). If it's on, stop and
  ask the user to turn it off. Check it again when you finish.
- **Email:** suggest "Who can see or download your email address" be set to the most private
  option. That is the user's setting to change.
- **Open to work:** ask whether the user still wants to signal recruiters; don't keep it on by
  default. Never set "All LinkedIn members" unless asked: it adds the green #OpenToWork photo
  frame. To turn it off without deleting the saved preferences, follow
  `references/settings.md`.

## 3. Show each form's contents, then save one form at a time

Before the first save, show exactly what each form will contain (titles, dates, locations,
descriptions, skills) and get a clear yes. Ask about anything the source doesn't settle. Before
each save, screenshot the whole form and check every switch below.

## Traps, form by form

| Form | Trap | Do this |
|---|---|---|
| **Edit an existing position** | "Notify network" switch at the top | Must read **Off** |
| **Add a role** | A sharing switch, "Share with your network" at the bottom or "Notify network" at the top depending on the form version, can be **On by default** even with the account setting off | Make sure it reads **Off** |
| **Add a role** | "Update your profile headline" defaults to **replacing the headline** with the new title | Select the option marked **(current)** |
| **Add a role** | "I currently work here" is **checked by default** | Uncheck it for a past role, then set the end date |
| **Add a role** | A renamed company appears in the typeahead under its new name only | Pick the entry with the same logo as the existing position, so the roles group under one heading |
| After saving a position | "Verify you work at…" email prompt; "Connect with people you may know" | **Skip** both |
| **Add skill** | "Follow this skill" is **checked by default** | Uncheck it |
| **Add project** | Contributors | Never add one; LinkedIn tells the people you tag |
| **Featured** menu | "Add a post" and "Add an article" publish | Use only **Add a link** (or image or document) |
| **Featured** "Add a link" | Won't save without a link preview, and the preview service sometimes fails for every URL | Try twice at most, then leave it for later |
| **Edit intro** | No free website field; the custom button is Premium | Put websites in Contact info |
| After saving the intro or About | A Premium upsell dialog, or "tell us more about these top skills" | Close the upsell with its X, never the offer button; press **Done** on the skills prompt |
| **Top skills** (About form) | A skill not yet on the profile appears under "Additional skills"; picking it also adds it to Skills | Pick LinkedIn's own entry; removing a top skill leaves it in Skills |
| **Delete** anything | "This action cannot be undone", so it needs its own explicit yes | Get that explicit yes, then read the item name in the dialog before confirming |
| **Unfollow** a page | Confirmation dialog | Silent; the page isn't notified |

## Splitting one employer into several roles without a "new job" announcement

LinkedIn groups positions under one company heading when each uses the same company entity (pick
it from the company typeahead).

1. **Edit the existing current entry into the latest role**: new title, that role's start date,
   "currently working here" still checked. It stays the same current job.
2. **Add each earlier role as a past position**, with "I currently work here" unchecked and an end
   date. Watch for the two "Add a role" traps on every one.
3. Add the current role first; adding a new current role while the old one is current makes
   LinkedIn offer to end the old one.

## Profile-specific details

- Skill names are LinkedIn's canonical ones: "Python (Programming Language)", "Large Language
  Models (LLM)", "Amazon Web Services (AWS)", "Webrtc". Some tools have no skill at all; leave those
  out rather than pick a wrong one.
- **Top skills** (up to 5) are set in the About form, not the Skills section.
- **Contact-info websites** take a type: Portfolio, Blog, Personal, Company, RSS Feed or Other.
  Leave phone, address and birthday empty unless the user asks.
- In the Add skill form, the first click on "Add skill" after the page loads sometimes only focuses
  the form; check the input opened before typing.

## See the profile as others do

When the user wants to check their profile from a recruiter's perspective, or just wants the link:

1. **Give them their own profile link.** Read it from the profile page's "Public profile & URL"
   panel or from contact info: `https://www.linkedin.com/in/<id>/`. While signed in,
   `https://www.linkedin.com/in/me/` redirects to it.
2. **The public, signed-out view:** the user opens that link in a private or incognito window,
   where they aren't signed in. Never sign the user out to show it. For a preview without a second
   window, `https://www.linkedin.com/public-profile/settings` shows the public view next to the
   settings that control what's in it.
3. **Be clear about the recruiter view.** A recruiter signed in to LinkedIn sees roughly what any
   member outside the user's network sees, plus signals only recruiters get, such as "Open to work"
   set to recruiters only. LinkedIn has no page that shows exactly that view, so say the public view
   is the closest check, not an exact copy. The signed-out public view can also show **less** than a
   signed-in recruiter sees: public-visibility settings hide some sections only from signed-out
   viewers.

## Finish

1. Check "Share profile updates" is still **Off**.
2. Read back each changed section and compare it to what the user approved.
3. Report what changed, which defaults you switched off (headline swap, sharing, skill follows),
   anything skipped and why, and what's left.
