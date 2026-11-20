---
title: How to Add Several Reminders at Once on iPhone
description: Siri is built for one reminder per request, so long lists get merged or split oddly. Why it happens, the built-in workarounds, and a faster way.
pubDate: 2026-11-15
updatedDate: 2026-11-18
draft: false
---

You're walking out the door and three things land in your head at once: call the dentist tomorrow, send the report by Friday, pay rent on the 1st. You say all of it to Siri in one breath — and get back **one reminder with the whole sentence as its title**, or a handful of odd fragments, or only the last thing you said.

The short answer: **Siri and Apple's Reminders app are designed around one request → one reminder.** There are a few built-in tricks that stretch that, and they're worth knowing. But when the things you're saying each need their own date, time or repeat, you need a tool that splits the sentence for you.

This guide covers why it happens, what actually works with the built-in apps, and when to reach for something else.

## What happens when you ask Siri for several things

Results vary by phrasing and iOS version, but these are the patterns people keep reporting on Apple's own community forums and in iPhone blogs:

- **Everything merges into one reminder.** "Remind me to call the dentist tomorrow and send the report on Friday" often becomes a single reminder, with one date, holding both tasks in its title.
- **Lists get split in the wrong places.** Grocery-style requests can work — "add bread, milk and eggs to my groceries list" — but multi-word items sometimes break apart ("honey mustard sauce" becoming three items), and longer lists can collapse back into one line.
- **Behaviour changes between updates.** Some users report that a phrasing which used to produce separate items now produces one long one.

Apple's own Reminders help page only shows single-reminder examples ("Add artichokes to my groceries list"), which tells you what the feature is designed for.

## Why: one request, one reminder

Siri is matching your sentence to one action — *create a reminder* — and filling that action's slots: a title, a date, maybe a list. When you pack three tasks with three different dates into one sentence, there is only one title slot and one date slot to put them in. Something has to give, so you get the merge.

Shopping lists are the partial exception, because there the items share everything except their name: same list, no dates. Splitting "bread, milk and eggs" is a much easier problem than splitting "dentist tomorrow, report by Friday, rent every month."

## Built-in workarounds that do work

If you'd rather stay with Reminders — a perfectly good, free choice — these help:

### 1. One reminder per request

The most reliable fix is the boring one: say each task as its own Siri request. "Remind me to call the dentist tomorrow at 9." Then: "Remind me to send the report Friday." It's slower, but each reminder gets its own date.

### 2. Name the list for simple items

For undated items that belong together, name the list explicitly and keep items short: "Add bread, milk and eggs to my groceries list." Saying the list name also stops items from landing in your default list.

### 3. Split it afterwards with a shortcut

Some people dictate everything into one reminder on purpose, then run a Shortcuts automation that splits the text on commas or "and" into separate reminders. It works for plain lists, but every item still needs its date set by hand.

### 4. Make single captures faster

On iOS 26, Reminders offers a **New Reminder** control you can put on the Action Button, the Lock Screen or Control Center. It doesn't split anything, but it makes "one reminder per request" quicker to repeat.

## Where the workarounds run out

All four tricks share a limit: they help you make **more reminders faster**, not **understand one sentence that contains several tasks**. They break down exactly when each task is different:

- "Call the dentist **tomorrow at 9**" — a date and a time.
- "Send the report **by Friday**" — a deadline.
- "Pay rent **on the 1st every month**" — a repeat.
- "Drink water **at 3, 5 and 7**" — several reminders on one task.

That's four tasks, four different shapes. With the built-in tools you either make four separate requests or fix four reminders by hand afterwards.

## The faster way: let an app split the sentence

Voice-first to-do apps are built for this exact job: you say everything in one go, and the app separates the tasks and works out each one's date, time and repeat.

Here's how it works in [VoiceTodo](/voice-to-do-list):

1. **Press and hold the record button and say it all** — "Call the dentist tomorrow at 9, send the report by Friday, pay rent on the 1st every month."
2. **VoiceTodo splits it into separate to-dos.** "Tomorrow" and "by Friday" become real dates; "on the 1st every month" becomes a monthly repeat.
3. **You review before anything is saved.** Every to-do shows up on a review card — fix a date, remove one, or add them all with one tap.

It handles the shapes the built-in tools struggle with: weekly repeats on specific days ("every Monday, Wednesday and Friday"), every-other-week and monthly repeats, and several reminder times on a single task.

You can also do it through Siri: say **"Add todo in VoiceTodo"**, then speak your list. VoiceTodo splits it the same way and shows you what it added. Nothing is sent to its AI service until you've agreed in the app: if you haven't yet, VoiceTodo keeps what you said and organizes it after you open the app and give consent.

Want to see the split before installing anything? [Try the sentence splitter](/tools/add-multiple-reminders-at-once) in your browser — paste any sentence and watch it turn into a dated list. It's the same parse the app runs, and the page never creates reminders.

VoiceTodo is free to start with 3 voice captures a day, and it needs an iPhone with iOS 26 or later.

## Tips for dictating several tasks at once

Whatever tool you use, a little phrasing goes a long way:

- **Put each date right next to its task.** "Dentist tomorrow, report by Friday" is clearer than "tomorrow the dentist and also the report, Friday."
- **Use a short pause or "and then" between tasks** when they're long or similar.
- **Say repeats explicitly:** "every Monday", "on the 1st every month", "every two weeks."
- **Always glance before you save.** Speech recognition still mishears the odd name — a two-second check beats a reminder for the wrong day.

## Quick comparison

| What you need | Siri + Reminders | Voice to-do app |
| --- | --- | --- |
| One task with a date | Works well | Works well |
| A few undated list items | Usually works | Works well |
| Several tasks, each with its own date | One request per task | One sentence |
| Repeats on specific days | Often needs manual setup | Said in the same sentence |
| Review before saving | No | Yes (VoiceTodo) |
| Cost | Free, built in | Free tier, paid upgrade |

If most of your tasks are single errands, Reminders and Siri are hard to beat. If you tend to think in bursts — three or four things at once, each with its own day — splitting the sentence for you is where the time goes back into your day.

## Related

- [Try the sentence splitter](/tools/add-multiple-reminders-at-once) — the free browser tool that shows this split live
- [What Siri can't do with your to-do list](/guides/apple-reminders-vs-voice-to-do-apps) — the full honest comparison
- [How to set recurring reminders by voice](/guides/how-to-set-recurring-reminders-by-voice-on-iphone) — repeats on specific days, said in the same breath
- [Best things to put on your iPhone Action Button](/guides/fastest-way-to-capture-tasks-on-iphone) — the capture-speed case for voice on the button
- [How to stop forgetting things you need to do](/guides/stop-forgetting-things-you-need-to-do) — why effortless capture matters
- [Voice to-do list for iPhone](/voice-to-do-list) — how VoiceTodo turns speech into dated to-dos
