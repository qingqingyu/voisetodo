---
title: How to Set Recurring Reminders by Voice
description: Siri handles simple repeats like "every Monday" but stumbles on Mon/Wed/Fri, every other week and monthly dates. What works, and a faster way.
pubDate: 2026-11-18
updatedDate: 2026-11-18
draft: true
---

"Gym every Monday, Wednesday and Friday." Six words, one breath — and the difference between a routine that runs itself and three reminders you re-create every week by hand.

Recurring reminders are where voice capture pays off the most, and also where it stumbles the most. This guide covers what Siri and the Reminders app do well by voice, where they get shaky, and how to check a phrase before you rely on it.

## What Siri handles well

Simple, single-dimension repeats usually land fine:

- **"Remind me to take my meds every day at 8am."** Daily at a fixed time is the best-supported shape.
- **"Remind me to take out the trash every Tuesday."** One weekday, one task.
- **"Remind me to pay rent on the 1st of every month."** A monthly date, phrased plainly.

If your repeats look like these, stay with Reminders — it's built in, and it works.

## Where it gets shaky

The patterns people report struggling with, in rough order of frequency:

- **Several weekdays at once.** "Every Monday, Wednesday and Friday" sometimes becomes every Monday only, or three reminders each firing weekly on the wrong understanding of which days you meant. Results vary by phrasing and iOS version.
- **Every other week / every N weeks.** Usually falls back to weekly, or to a one-off reminder with the sentence as its title.
- **Repeat plus a time plus an end date.** "Water the plants every Monday and Thursday at 6pm for the next month" packs three parameters into one slot each — the same one-request-one-reminder limit that merges multi-task sentences (see [adding several reminders at once](/guides/add-several-reminders-at-once-on-iphone)).
- **Times relative to the repeat.** "Remind me the night before bin day every week" needs the assistant to understand that the reminder isn't on bin day itself.

When one of these misfires, you get to open the reminder, tap Edit, scroll to Repeat, and rebuild the schedule by hand — which is exactly the tapping you were trying to avoid by speaking.

## Check a phrase before you rely on it

Before you build a routine on a phrase, see what it actually produces. [The recurring reminder checker](/tools/recurring-reminder-checker) is a free page that reads a phrase the way VoiceTodo's capture parser does and shows you the rule plus the next five dates — for example, that "every Monday, Wednesday and Friday" means Mon/Wed/Fri weekly, with the next five occurrences listed so you can eyeball them.

It runs VoiceTodo's local repeat rules — the deterministic ones, no AI involved — so it's instant, and it never creates anything. Phrasings outside that set (like "every other Tuesday") it says so plainly; in the app those go through the AI parser instead.

## The faster way: say the whole schedule in one breath

Voice-first to-do apps are built so the repeat rides along with the task:

1. **Say the task and its repeat together.** "Gym every Monday, Wednesday and Friday." "Rent on the 1st of every month." "Report to my manager every two weeks on Friday."
2. **The repeat comes out as a real rule** — specific weekdays, every-N-weeks, or a monthly date — not a sentence in a title.
3. **You see it on a review card before it's saved.** The rule is spelled out ("Every Monday, Wednesday and Friday") next to the task, so a misheard weekday is a one-tap fix, not a surprise in three weeks.
4. **End bounds work too.** "Physio every Tuesday and Thursday for the next six weeks" gives you a repeat that stops when the six weeks are up — no infinite cleanup of stale reminders.

Repeats also combine with the multi-task split: "team report every Friday, one-on-one notes every Tuesday, invoice on the 1st every month" — three tasks, three different schedules, one sentence.

## Tips for saying repeats

- **Name the days explicitly.** "Every Monday, Wednesday and Friday" beats "three times a week" — the latter has to be interpreted, the former just has to be heard.
- **Put the repeat right after the task.** "Water the plants every Monday" parses more reliably than "every Monday water the plants" when the sentence carries more than one task.
- **Say the end bound when there is one.** "…for the next 30 days", "…until the end of March." Repeats without an end are exactly that — they keep going until you delete them.
- **Check the card, always.** Speech recognition still mishears the odd weekday. Two seconds on the review card beats a month of the wrong routine.

VoiceTodo is free to start with 3 voice captures a day, and it needs an iPhone with iOS 26 or later.

## Related

- [Try the recurring reminder checker](/tools/recurring-reminder-checker) — the free browser tool that shows what a phrase creates
- [How to add several reminders at once on iPhone](/guides/add-several-reminders-at-once-on-iphone) — the sibling problem: many tasks, one sentence
- [Voice to-do list for iPhone](/voice-to-do-list) — how VoiceTodo turns speech into dated to-dos
