// App Store 截图文案 — 单一事实来源
// EN 定稿来自 PROMOTION_COPY.md §2.3(01/02 是 wow 双连,顺序不许动);
// zh 为起草稿,上传前需用户过目;
// ja 为预留槽位:PROMOTION_PLAN 决策 #6「日文 Beta 内置但不投放」,过母语审后填写,
// 并把 ja 加进 render.sh 的默认 LANGS 即可一键补产。
const COPY = {
  en: {
    "01": { headline: "Say it all at once.",      caption: "One breath. Any length.",                  slug: "recording" },
    "02": { headline: "Todos, not a transcript.", caption: "Dates, times, categories — parsed for you.", slug: "confirmsheet" },
    "03": { headline: "Your month, filled in.",   caption: "Every date lands where it belongs.",       slug: "month" },
    "04": { headline: "Today, at a glance.",      caption: "What's due. What's done.",                 slug: "today" },
    "05": { headline: "Review the week.",         caption: "What got done. What's next.",              slug: "review" },
    "06": { headline: "Pro when you need more.",  caption: "7-day free trial. Fair-use daily quota.",  slug: "paywall" },
    "07": { headline: "Ready in seconds.",        caption: "No account. No setup.",                    slug: "onboarding" }
  },
  zh: {
    "01": { headline: "一口气,全说完。",       caption: "一段话,不限长度。",                slug: "recording" },
    "02": { headline: "清单,不是转写稿。",     caption: "日期、时间、分类,都已解析好。",      slug: "confirmsheet" },
    "03": { headline: "一个月,排得明明白白。",  caption: "每个日期,都落在它该在的位置。",     slug: "month" },
    "04": { headline: "今天,一眼看清。",       caption: "该做的、做完的,都在这里。",          slug: "today" },
    "05": { headline: "复盘这一周。",           caption: "完成了什么,接下来做什么。",          slug: "review" },
    "06": { headline: "需要更多,就上 Pro。",   caption: "7 天免费试用,按日公平额度。",       slug: "paywall" },
    "07": { headline: "几秒,就能开始。",       caption: "无需注册,无需设置。",                slug: "onboarding" }
  },
  ja: {
    // 未填写:日文市场第二波,先过母语审再填(勿自行机翻上线)
  }
};
