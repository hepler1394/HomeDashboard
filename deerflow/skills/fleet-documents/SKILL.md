---
name: fleet-documents
description: >-
  Write a document and put it on one of Cory's Windows PCs — MainPC,
  MyMediaCenter, Laptop, or PlexServer. Use this whenever he asks for something
  to be written, saved, or placed "on my desktop", "on MainPC", or on any
  machine by name. There is a dedicated tool for it; you do not need a shell and
  do not have one. See [home-fleet] for the machines and account names.
license: private
---

# Putting a document on one of Cory's PCs

**When he asks for a document on a machine, call `deliver_document_to_pc` and
deliver it. Do not ask permission first, do not offer to save it locally
instead, and do not paste the document into chat and stop there.** The delivery
works; it is a normal, reversible action he explicitly asked for. Write the
content, call the tool, then report the path it confirms.

You have no shell here, and you do not need one — the tool does the whole job.
Nothing about the absence of a shell should make you hesitate to deliver.

## The tool

`deliver_document_to_pc(markdown, filename, agent, dest_dir, title)`

It renders your markdown as a real Word document, hands it to the
HomeDashboard, waits for the target PC to pull it down, and then lists the
destination folder to confirm the file is actually there. It returns either a
verified path or a specific reason it failed.

- `markdown` — the document body. Headings, bullets, numbered items, `**bold**`
  and `*italic*` all work. Write the full document; do not summarize.
- `filename` — must end in `.docx`, no spaces. `Q3-Review.docx`, not
  `Q3 Review.docx`. The tool refuses spaces because the dashboard's staging URL
  is not encoded and a space makes the download 404.
- `agent` — `mainpc`, `mymediacenter`, `laptop`, or `plexserver`. Defaults to
  `mainpc`.
- `dest_dir` — optional. Leave empty for that machine's Desktop. MainPC's is
  `C:\Users\Cory\Desktop`; note the account is `Cory`, not `BigBory`.
- `title` — optional cover title at the top of the document.

Typical use, after researching the topic:

    deliver_document_to_pc(
        markdown="## Summary\n\nThe rest of the document...",
        filename="Market-Notes.docx",
        agent="mainpc",
        title="Market Notes",
    )

## What to tell Cory

The tool verifies delivery itself. Repeat its answer honestly:

- On success it returns the confirmed path — quote that path back to him.
- On failure it says why (machine offline, bad filename, delivery job failed).
  Report the actual reason. **Never claim a file arrived unless the tool
  confirmed it**, and never describe a document you only drafted in chat as
  having been saved.

If he asks for a machine with no recorded Desktop, ask him for the folder
rather than guessing a path.

## Limits

The tool writes a document to a folder and nothing else — it cannot run
programs, open applications, change settings, or read files from his PCs. If a
request genuinely needs more than that, say what is missing and let him decide.

This is a deliberate boundary, not a malfunction: the container is trusted by
the dashboard, so a general shell would carry far more authority over his
machines than saving a file requires. Delivering a document is fully within
what you should just go ahead and do.
