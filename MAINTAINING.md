# Which repo do I change?

Written for Josh. Plain language, no assumed knowledge.

## The one idea everything follows from

**The iPad app is a window. The app is what's behind the window.**

MyHumans.App is a website. The iPad app is a thin frame around that website, plus one thing a
website cannot do: write with an Apple Pencil.

So the answer to "where do I change this?" is almost always **the web app**, because almost
everything *is* the web app. The iPad app has no screens of its own. It has no dashboard, no
people list, no settings — it's showing you the website.

That is deliberate. It means your work ships to everyone at once — desktop, Android, iPad — and
it means the iPad app almost never needs rebuilding.

---

## The rule of thumb

| If you're changing… | Change it in | Does the iPad need rebuilding? |
|---|---|---|
| Anything you can see and click in the app | `myhumansapp` | **No** |
| Any data, any save, any permission | `myhumansapp` | **No** |
| The writing toolbar — tips, colours, sizes, undo, delete | `myhumansapp` | **No** |
| How the Pencil canvas itself behaves — strokes, scrolling, gestures | `myhumans.app-ios` | Yes |
| The app's icon or name on the home screen | `myhumans.app-ios` | Yes |
| Adding a *new* conversation between the website and the Pencil canvas | **Both** | Yes |

Four rows out of five are "the web app, and the iPad takes care of itself."

---

## Worked examples

### 1. "I want to rearrange the dashboard"

**Where:** `myhumansapp` only. The iOS repo is irrelevant.

**What happens:** you change it, it deploys to Render, and the next time you open the app on your
iPad it's there. No rebuild. No Xcode. No plugging anything in. No App Store.

The iPad is loading `myhumans.app` the same way Safari would. If it's live on the website, it's
live in the app the moment the page reloads.

This is the case for nearly everything: new screens, new fields, renamed buttons, colour changes,
bug fixes, new features, permissions, reports.

### 2. "The pen sizes are wrong"

**Where:** `myhumansapp` only. No rebuild.

This is the one that surprises people. The writing toolbar — the tips, the colours, the four
sizes, undo, redo, delete — is drawn by the WEBSITE, sitting directly above the canvas. Only the
canvas itself is native. So changing what the buttons offer is a web change and reaches your iPad
on deploy.

### 3. "Scrolling while writing feels wrong"

**Where:** `myhumans.app-ios` only.

That screen is the one part that is genuinely a native iPad screen rather than a web page. It's
the exception the whole repo exists for.

**What happens:** the change is made, the app is rebuilt in Xcode, your iPad is plugged in, and it
reinstalls. A couple of minutes.

Also in this bucket: page length, undo behaviour, the pen-only setting, the confirmation wording,
crash recovery.

### 4. "I want the app icon changed"

**Where:** `myhumans.app-ios` only. Rebuild and reinstall.

### 5. "The writing screen should also know which person the note is about"

**Where:** **both.** This is the one case that needs coordinating.

The website and the Pencil canvas talk to each other through a deliberately tiny set of
messages — four of them, listed in `README.md`. Adding a fifth means both sides need to learn it:
the website has to send it, the app has to understand it.

**This is rare, and the design makes it safe.** Both sides are built to tolerate the other being
older or newer. A website that sends a message the app doesn't know is ignored, not crashed. An
app expecting something the website doesn't send yet carries on. So you can ship one side today
and the other next week, and nothing breaks in between.

### 6. "Something looks wrong, but only in the iPad app"

**Where:** usually `myhumansapp`. Occasionally the shell.

If a page looks squashed, or a dialog won't close, that's the website rendering inside a slightly
different browser. It's a web fix. Genuine shell problems are rare and look different — the whole
app misbehaving rather than one screen.

---

## How an update actually reaches your iPad

Two completely separate paths. Knowing which one you're on tells you what to expect.

| | Web change | iPad app change |
|---|---|---|
| What you do | Deploy to Render as usual | Rebuild in Xcode |
| What Josh does | Nothing | Plug the iPad in |
| How long | As long as your deploy takes | About two minutes |
| Apple involved? | No | No |
| How often | Constantly | Should be almost never |

**Neither path involves the App Store or app review.** The app is installed directly from your own
Mac to your own iPad. That's why there's no waiting on Apple to approve anything.

---

## "Can I keep them in sync so I only change one place?"

Mostly you already do — because there's almost nothing in the iPad repo to keep in sync. It holds
one screen and a frame. Everything else lives in the web app, once.

The only shared thing is that one small set of bridge messages — it was four when this was
written and it is more than that now, which is exactly why the count lives in README's table and
the authority lives in `Bridge.swift`, not here. They're deliberately tiny and versioned
precisely so the two repos never have to ship together. There's no build step to wire up, no
shared library to keep matched, no "deploy these at the same time."

**The honest summary: they're not really two halves of one app. It's one app, plus a small
accessory.**

---

## The one recurring chore

The app is installed with a developer certificate, and certificates expire.

- **Free Apple ID:** expires every **7 days**.
- **Paid account ($99/year):** expires every **year**.

Josh's account is paid and active, so this is annual. The current certificate runs to **13 August
2027**. When it lapses the app stops opening until it is rebuilt and reinstalled — nothing is
lost, because no data lives on the iPad.

Nothing is lost when it expires. The app stops opening until it's reinstalled; no data is on the
iPad to lose, because all of it lives in the web app.

---

## Where to look when you're stuck

| Question | File |
|---|---|
| What is this thing and why does it exist? | `README.md` |
| What's been tested, what hasn't, what not to touch | `HANDOFF.md` |
| What the website and the Pencil canvas say to each other | `README.md`, "The bridge" |
| The web-side work still to come | `web/BOLT-ON.md` |
