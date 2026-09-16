---
name: linkedin-profile
description: Use when the user wants their LinkedIn profile reviewed, brought in line with a source of truth (a portfolio site, a résumé), or edited for them in their signed-in browser, especially when they want it done quietly, without posts or notifications to their network. Covers the headline, location, About and top skills, experience (including splitting one employer into several roles), projects, skills, contact-info websites, Featured, courses and followed pages.
---

# Quiet LinkedIn profile edits

The job is to make a LinkedIn profile match a source the user trusts, **without LinkedIn
announcing anything**. Most LinkedIn edit forms have a switch that shares the change with the
user's network, and several of them are **on by default** even when the account-wide setting
is off. The work is mostly spotting those switches before every save.

You need browser tools that drive the user's own signed-in browser (reading pages, clicking,
typing, screenshots, running page JavaScript). Never sign in for the user, and never type a
password.

## 1. Audit before touching anything

1. **Read the source of truth** the user named: their site, résumé or notes. Take facts only
   from there. Don't invent titles, dates, metrics or claims, and follow the source's own
   rules (for example, a site that deliberately leaves out metrics or customer names).
2. **Read the profile.** Start at `https://www.linkedin.com/in/<id>/`. Sections load lazily as
   you scroll, so scroll down before reading the page text. The full lists are at
   `/in/<id>/details/experience/`, `/details/projects/`, `/details/skills/`,
   `/details/courses/`, `/details/featured/` and `/details/interests/`. Contact info is at
   `/in/<id>/overlay/contact-info/`.
3. **Report the gaps** as a table (LinkedIn today against the source), then give recommendations
   in order of impact, with exact copy the user can paste.

Reading pages sends nothing. Opening a form without saving sends nothing.

## 2. Make it quiet, and check again before every session

- **Account-wide:** Settings, Visibility, "Share profile updates" must read **Off**
  (`https://www.linkedin.com/mypreferences/d/categories/profile-visibility`). If it's on, stop
  and ask the user to turn it off; changing account settings is their call. Check it again when
  you finish.
- **Email:** in the same Visibility page, suggest "Who can see or download your email address"
  be set to the most private option if the user doesn't want spam. That's their setting to
  change, not yours.
- **Open to work** stays on **Recruiters only** unless the user asks otherwise. "All LinkedIn
  members" adds the green #OpenToWork photo frame.

## 3. Get a clear yes, then save one form at a time

Editing a profile publishes to it. Before the first save, show the user exactly what each form
will contain (titles, dates, locations, descriptions, skills) and get a clear go-ahead. Ask
about anything the source doesn't settle, such as where each past role was located. Deleting
entries needs the same explicit yes.

Before each save, screenshot the whole form (scroll it top to bottom) and check every switch in
the table below.

## Traps, form by form

| Form | Trap | Do this |
|---|---|---|
| **Edit an existing position** | "Notify network" switch at the top | Must read **Off** |
| **Add a role** (new position) | "Share with your network" at the bottom is **On by default**, even with the account setting off | Turn it **Off** before saving |
| **Add a role** | "Update your profile headline" defaults to **replacing the headline** with the new title | Select the option marked **(current)** |
| After saving a position | "Verify you work at…" email prompt; "Connect with people you may know" | **Skip** both. Never click Connect |
| **Add skill** (Skills section) | "Follow this skill" is **checked by default** | Uncheck it |
| **Add project** | "Contributors" | Never add one; LinkedIn tells the people you tag |
| **Featured** menu | "Add a post" and "Add an article" publish content | Use only **Add a link** (or image or document) |
| **Featured** "Add a link" | Won't save without a link preview, and the preview service sometimes fails for every URL, even GitHub | Try twice at most, then leave it for later and tell the user |
| **Edit intro** | No free website field any more; the custom button is Premium | Put websites in Contact info instead |
| **Delete** anything | "This action cannot be undone" dialog | Read the item name in the dialog before confirming |
| **Unfollow** a page | Confirmation dialog | Silent; the dialog says the page isn't notified |
| Anywhere | "Create a post", "Ask for a recommendation", "Start a post" nudges | Never. Each one publishes something or sends a message |

## Splitting one employer into several roles without a "new job" announcement

LinkedIn groups positions under one company heading when each uses the same company entity (pick
it from the company typeahead). To go from one long "Software Engineer at X" entry to a
promotion history:

1. **Edit the existing current entry into the latest role**: new title, the latest role's start
   date, "currently working here" still checked. It stays the same current job, so nothing reads
   as a new position.
2. **Add each earlier role as a past position**, with "I currently work here" unchecked and an
   end date. Past roles aren't new jobs. Watch for the two "Add a role" traps above on every one.
3. Add the current role first. If you add a new current role while the old one is still current,
   LinkedIn offers to end the old one.

## Mechanics that save time

- **Typing can drop characters** in some text areas (project descriptions especially): "haven't"
  comes out as "havent", "woods" as "oods". After typing, read the value back. If it's wrong, set
  it through the element's native value setter and fire an `input` event:

  ```js
  const el = document.querySelector('textarea');
  Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(el, text);
  el.dispatchEvent(new Event('input', { bubbles: true }));
  ```

  Confirm the character counter under the field changed, which shows the form registered it. Use
  `HTMLInputElement.prototype` for a single-line input.
- **Typeaheads** (location, company, skill) only save an entity picked from the dropdown. Skill
  names are LinkedIn's canonical ones: "Python (Programming Language)", "Large Language Models
  (LLM)", "Amazon Web Services (AWS)", "Webrtc". Some tools have no skill at all (Electron comes up
  as "Electronics"); leave those out rather than pick a wrong one.
- **Coordinates shift** after every skill you add to a form. Find the "Add skill" button again
  each time instead of reusing a position. The first click on it after the page loads sometimes
  only focuses the form, so check that the input actually opened before typing.
- **Pages load slowly** and show grey placeholder cards for 10 to 20 seconds, especially right
  after a save or delete. Wait and look again; don't click into a placeholder.
- **Top skills** (up to 5) are set in the About form, not the Skills section.
- **Contact-info websites** take a type: Portfolio, Blog, Personal, Company, RSS Feed or Other.
  Leave phone, address and birthday empty unless the user asks.
- The `/details/…` paths and form URLs above were current in September 2026. LinkedIn changes
  them; if one 404s, go through the profile page's pencil and "Add section" buttons instead.

## Finish

1. Check again that "Share profile updates" is still **Off**.
2. Read back each section you changed and compare it to what the user approved.
3. Tell the user what changed, which defaults you switched off (headline swap, sharing, skill
   follows), anything you skipped and why, and what's left for them to do.
