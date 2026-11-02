// 页面元信息单一来源(非指南页)。
// title/description 在此维护;构建检查脚本(scripts/checks.mjs)按任务书 §9 校验:
// 唯一性、长度(title ≤60 含站名后缀,description ≤155)、og 图存在性。
// 指南页的 meta 在各自 markdown frontmatter(src/content/guides/)。
// 注意:文案事实必须符合 task-seo-website.md §0.2 左列(只写真实能力)。

export const pages = {
  '/': {
    title: 'Voice To-Do List App for iPhone | VoiceTodo',
    ogTitle: 'Say it once. See it all day.',
    description:
      'Speak your plan once — get a clean, dated checklist on your iPhone and check it off from your Lock Screen. Free to start, no account.',
    lastmod: '2026-11-02',
    changeFrequency: 'weekly',
    priority: 1.0,
  },
  '/voice-to-do-list': {
    title: 'Voice Activated To-Do List App for iPhone | VoiceTodo',
    ogTitle: 'A to-do list you can just talk to',
    description:
      'Turn speech into to-dos: say several things at once and get them split into a clean list with the right dates. No typing, no forms.',
    lastmod: '2026-11-02',
    changeFrequency: 'monthly',
    priority: 0.9,
  },
  '/lock-screen-to-do-list': {
    title: 'Lock Screen To-Do List for iPhone | VoiceTodo',
    ogTitle: 'Your list, right on your Lock Screen',
    description:
      "Put your to-do list on your iPhone Lock Screen. See what's next every time you pick up your phone, and check items off right there.",
    lastmod: '2026-11-02',
    changeFrequency: 'monthly',
    priority: 0.9,
  },
  '/iphone-to-do-widget': {
    title: 'To-Do List Widget for iPhone | VoiceTodo',
    ogTitle: 'A to-do widget you can actually check off',
    description:
      "Home Screen widgets for today's tasks: medium and large sizes, tap the circle to complete a task without opening the app.",
    lastmod: '2026-11-02',
    changeFrequency: 'monthly',
    priority: 0.9,
  },
  '/features': {
    title: 'Features, Pricing & Requirements | VoiceTodo',
    ogTitle: 'Every feature, plainly stated',
    description:
      'The complete fact sheet: what VoiceTodo does, capture methods, widgets, languages, free vs Pro limits, and device requirements.',
    lastmod: '2026-11-02',
    changeFrequency: 'monthly',
    priority: 0.8,
  },
  '/guides': {
    title: 'Guides for Remembering and Getting Things Done | VoiceTodo',
    ogTitle: 'Get things out of your head',
    description:
      'Short, practical guides on capturing tasks, keeping your list visible, and planning your day — written for people who forget things.',
    lastmod: '2026-11-02',
    changeFrequency: 'weekly',
    priority: 0.7,
  },
  '/support': {
    title: 'Support — FAQs and Contact | VoiceTodo',
    ogTitle: 'Support',
    description:
      'How to add the Lock Screen widget, fix speech recognition, restore a purchase, cancel a subscription, and where your data lives.',
    lastmod: '2026-11-02',
    changeFrequency: 'monthly',
    priority: 0.6,
  },
  '/privacy': {
    title: 'Privacy Policy | VoiceTodo',
    ogTitle: 'Privacy, plainly',
    description: 'No account, no tracking, no ads. Read exactly what data VoiceTodo handles, where it goes, and how long it is kept.',
    lastmod: '2026-11-02',
    changeFrequency: 'yearly',
    priority: 0.5,
  },
  '/about': {
    title: 'Made by One Person Who Forgets Things Too | VoiceTodo',
    ogTitle: 'Made by one person',
    description: 'VoiceTodo is built by one independent developer who forgets things too. Why it exists and the principles behind it.',
    lastmod: '2026-11-02',
    changeFrequency: 'yearly',
    priority: 0.5,
  },
  '/404': {
    title: 'Page Not Found | VoiceTodo',
    ogTitle: 'This page got lost',
    description: 'This page got lost. Head back to the homepage, or jump to the voice, Lock Screen, and guides pages.',
    lastmod: '2026-11-02',
    noindex: true,
    noSitemap: true,
  },
};

// FAQ 内容(任务书 §4.3:页面上可见的 FAQ 与 FAQPage 结构化数据完全一致,
// 由 Faq.astro 同源渲染,检查脚本核对两边数量一致)。
// 所有回答遵守 §0.2:不写「无限次 / 完全免费 / 完全离线 / 多设备同步 / 医疗宣称」。
export const faqs = {
  home: [
    {
      q: 'Is there a to-do list app where I can just say what I need to do?',
      a: "Yes — that's exactly what VoiceTodo is for. Speak one sentence and it becomes a clean, dated checklist. Say “Call the dentist tomorrow, buy milk, and send the report by Friday” and you get three separate to-dos, each on the right day.",
    },
    {
      q: 'Can I check off tasks from my iPhone Lock Screen?',
      a: 'Yes. The rectangular Lock Screen widget shows your next few to-dos — tap to check one off right from the Lock Screen, without opening the app.',
    },
    {
      q: 'Is it free?',
      a: 'Free to start: 3 voice captures per day. Pro raises that to 100 per day and starts with a 7-day free trial. Prices vary by region and are shown in the App Store.',
    },
    {
      q: 'Do I need an account?',
      a: 'No. There is no sign-up and no sign-in — download the app and start talking. Your list stays on your iPhone.',
    },
    {
      q: 'Does it work in other languages?',
      a: 'Yes. Voice capture works in English, Chinese, and Japanese, and the app interface follows your phone’s language.',
    },
    {
      q: 'Which iPhones are supported?',
      a: 'Any iPhone running iOS 26 or later. iPad, Mac, and Android are not supported.',
    },
  ],
  voice: [
    {
      q: 'Can I create a to-do list using my voice?',
      a: 'Yes. Hold the record button and speak naturally — several tasks in one sentence are fine. VoiceTodo splits them into separate to-dos with dates.',
    },
    {
      q: 'Can I add several tasks in one sentence?',
      a: "Yes — that's the fastest way to use it. Say everything on your mind; each thing becomes its own to-do on the right day. You review and confirm before anything is saved.",
    },
    {
      q: 'Does it work with Siri?',
      a: 'Yes. Say “Add todo in VoiceTodo” to capture by voice, or “Start recording in VoiceTodo” for hands-free recording. On supported iPhones you can also assign VoiceTodo to the Action Button.',
    },
    {
      q: 'What happens without internet?',
      a: "Nothing you said is thrown away: the transcript is kept on your phone and organized into dated to-dos as soon as you're back online.",
    },
    {
      q: 'Is my voice recording uploaded?',
      a: "No. VoiceTodo never receives or stores your audio. Speech recognition runs through Apple's Speech framework; the resulting text is sent over an encrypted connection to our server and an AI provider to structure it — processed in real time, not archived, and only after you agree.",
    },
  ],
  lock: [
    {
      q: 'Is there an iPhone app that lets me check off tasks from the Lock Screen?',
      a: "Yes — that's the rectangular Lock Screen widget. It shows your next few to-dos with a checkbox on each; tap to complete one without opening the app.",
    },
    {
      q: 'How do I put my to-do list on my Lock Screen?',
      a: 'Touch and hold your Lock Screen, tap Customize, tap the area above the clock, tap Add Widgets, and choose VoiceTodo. It takes about 30 seconds — full steps with screenshots above.',
    },
    {
      q: "Does it show today's tasks only?",
      a: "It shows what's due today, plus to-dos you haven't given a date yet. Recurring tasks appear on the days they come due, and items you just completed stay visible briefly before dropping off.",
    },
    {
      q: 'Can I add tasks from the Lock Screen?',
      a: 'Not by typing on the Lock Screen — but you can add without opening the app: use Siri (“Add todo in VoiceTodo”) or the Action Button on supported iPhones to record hands-free.',
    },
  ],
  widget: [
    {
      q: 'Is there a to-do app with an interactive widget?',
      a: "Yes. VoiceTodo's medium and large Home Screen widgets are interactive: each task has a circle you can tap to mark it done, right on your Home Screen.",
    },
    {
      q: 'Can I check off tasks from the widget?',
      a: 'Yes — tap the circle next to a task to complete it. Tap the task’s title to open its details in the app.',
    },
    {
      q: 'Is there a small widget?',
      a: 'Not on the Home Screen today — it comes in medium and large. The Lock Screen offers rectangular, circular, and single-line styles.',
    },
  ],
  support: [
    {
      q: 'How do I add the Lock Screen widget?',
      a: 'Touch and hold your Lock Screen → Customize → tap the area above the clock → Add Widgets → VoiceTodo. The rectangular style shows tasks with checkboxes; circular shows a count and single-line shows your next task.',
    },
    {
      q: 'Speech recognition is not accurate. What can I do?',
      a: 'Check that the recognition language in the app matches the language you are speaking. For names and words you use often — people, projects, places — add them to your personal glossary so the recognizer favors them.',
    },
    {
      q: 'How do I restore my purchase?',
      a: 'Pro is tied to your Apple ID. Open the purchase screen in the app and tap Restore. If it still does not apply, email us below with the Apple ID you used.',
    },
    {
      q: 'How do I cancel my subscription?',
      a: 'Subscriptions are managed by Apple, like every iOS subscription: Settings app → your name → Subscriptions → VoiceTodo → Cancel Subscription.',
    },
    {
      q: 'When does my daily voice quota reset?',
      a: 'Daily counts reset on a UTC day boundary — overnight or in the morning depending on your time zone. The app shows how many captures you have left for the day.',
    },
    {
      q: 'Where is my data stored?',
      a: 'Your to-do list lives on your iPhone and stays there; nothing about your list is uploaded. See the privacy policy for exactly what leaves the device and why.',
    },
  ],
};
