import XCTest
@testable import VoiceTodoProtocols

/// hasExplicitTimeCue 的测评集回归(任务书 docs/eval-ja-batch2-holidays-task.md §2,2026-11-27)。
///
/// 背景:`applyDueDateBasisFilter` 在 AI 标 `user_explicit` 时,只要原话里扫不到
/// 时间线索就把 dueDate 清空;而 hasExplicitTimeCue 的词表此前**只有中文和英文**,
/// 日语用户明确说了日期也会被清空。transcript 全部抄自
/// `AIProxy/eval/dataset.json` 里「golden basis = user_explicit 且 due_date 非空」
/// 的 case —— 测的是**线上保存路径**,eval 只测代理输出、测不到这里。
///
/// 表驱动:true 组 = 修复目标(修复前失败,失败数记结果文档);false 组 = 既有的
/// title_mention / 无日期判定,修复前后都必须保持 false。
final class ExplicitTimeCueDatasetRegressionTests: XCTestCase {

    /// dataset.json 里日语 user_explicit 有日期的 25 条原话(修复前全部被判无线索)。
    static let jaExplicitTranscripts: [String] = [
        "明日の午後3時に会議",                                                              // ja-001
        "明日の午前10時に会議、金曜日までに四半期レポートを出して、荷物を受け取って、毎月1日に家賃、15時と17時と19時に水を飲む", // ja-007
        "3日後に歯医者に行く",                                                             // ja-008
        "今月末までに税金の申告をする",                                                      // ja-009
        "来週の水曜日に面接がある",                                                          // ja-010
        "明日の午後3時に打ち合わせがあります",                                                // ja-015
        "銀行に行って、母の誕生日プレゼントを買って、金曜の夜にレストランを予約して",              // ja-016
        "明日、Ankiのデッキを復習する",                                                     // ja-018
        "来週の日曜日に母に電話する",                                                        // ja-019
        "明後日、田中さんに資料を送る",                                                      // ja-021
        "あさっての夜、友達と飲みに行く",                                                    // ja-022
        "しあさってまでに洗濯機の修理を頼む",                                                // ja-023
        "明々後日の午前10時に歯医者",                                                       // ja-024
        "再来週の水曜日にプレゼンがある",                                                    // ja-025
        "来月頭に車検の予約を入れる",                                                        // ja-027
        "明日の朝イチで部長にメールを返す",                                                  // ja-028
        "明日の午前中に銀行で振込をする",                                                    // ja-029
        "金曜の昼過ぎに荷物を受け取る",                                                      // ja-030
        "今日の夕方、スーパーで買い物をする",                                                // ja-031
        "今日、定時後にジムに行く",                                                         // ja-032
        "今日の25時までに原稿を仕上げる",                                                   // ja-033
        "年度末までに予算の報告書を出す",                                                    // ja-034
        "年内に健康診断を受ける",                                                            // ja-035
        "令和9年3月10日までにパスポートを更新する",                                          // ja-036
        "明後日の午前中に病院に行って、再来週の金曜までにレポートを出す",                        // ja-040
    ]

    /// 中英文里同样被词表漏掉的 3 条(任务书 §2.1 模拟结论)。
    static let zhEnExplicitTranscripts: [String] = [
        "Call mom this evening",            // en-010:词表只有 tonight 没有 this evening
        "File the expense report by the end of the month", // en-013:只有 end of (this) month
        "晚上十点半睡觉",                     // zh-017:词表有「今晚」没有「晚上」
    ]

    /// 必须保持 false 的既有判定(title_mention / 目标语义 / 无日期)。
    static let negativeTranscripts: [String] = [
        "日曜日のパーティーの準備をする",    // ja-006:曜日 + 「の準備」目标语义
        "今度歯医者に行こう",                // ja-014:无日期表达
        "Prepare for Sunday's dinner party", // en-007:prepare for 目标语义
        "为周日聚会做准备",                   // zh-014:为…准备 目标语义
    ]

    /// 修复目标:日语/漏词的明确日期原话都能扫到线索。
    func testDatasetExplicitTranscriptsHaveCue() {
        for transcript in Self.jaExplicitTranscripts {
            XCTAssertTrue(
                TodoDueDateResolver.hasExplicitTimeCue(in: transcript),
                "应识别为明确时间线索:\(transcript)"
            )
        }
        for transcript in Self.zhEnExplicitTranscripts {
            XCTAssertTrue(
                TodoDueDateResolver.hasExplicitTimeCue(in: transcript),
                "应识别为明确时间线索:\(transcript)"
            )
        }
    }

    /// 既有判定不回退:目标语义 / 无日期仍为 false。
    func testDatasetNegativeTranscriptsStayFalse() {
        for transcript in Self.negativeTranscripts {
            XCTAssertFalse(
                TodoDueDateResolver.hasExplicitTimeCue(in: transcript),
                "不应识别为时间线索:\(transcript)"
            )
        }
    }

    /// 日语星期单独出现(无目标语义)→ true;「の準備 / のため / 用の」目标语义 → false。
    func testJapaneseWeekdayCueAndTargetSemantics() {
        XCTAssertTrue(TodoDueDateResolver.hasExplicitTimeCue(in: "金曜日までにレポートを出す"))
        XCTAssertTrue(TodoDueDateResolver.hasExplicitTimeCue(in: "月曜に歯医者"))
        XCTAssertTrue(TodoDueDateResolver.hasExplicitTimeCue(in: "日曜日に映画を見る"))
        XCTAssertFalse(TodoDueDateResolver.hasExplicitTimeCue(in: "月曜日の会議のための資料"))
        XCTAssertFalse(TodoDueDateResolver.hasExplicitTimeCue(in: "金曜日の発表用のスライド"))
    }

    /// 营业日 / 週明け / 来月 / 年内 / 年度末 / 令和 / X月X日 / 时段词 → true。
    func testJapaneseSupplementWords() {
        XCTAssertTrue(TodoDueDateResolver.hasExplicitTimeCue(in: "翌営業日までに返信する"))
        XCTAssertTrue(TodoDueDateResolver.hasExplicitTimeCue(in: "週明けに見積もりを送る"))
        XCTAssertTrue(TodoDueDateResolver.hasExplicitTimeCue(in: "今週中に企画書を仕上げる"))
        XCTAssertTrue(TodoDueDateResolver.hasExplicitTimeCue(in: "3月10日に歯医者")) // X月X日(无年号)
        XCTAssertTrue(TodoDueDateResolver.hasExplicitTimeCue(in: "昼に母に電話する"))
        XCTAssertTrue(TodoDueDateResolver.hasExplicitTimeCue(in: "夜に本を読む"))
    }

    /// 中英文补词:这周内 / 本周之内 / 工作日 / this week / end of the week / business days。
    func testChineseEnglishSupplementWords() {
        XCTAssertTrue(TodoDueDateResolver.hasExplicitTimeCue(in: "这周内把方案写完"))
        XCTAssertTrue(TodoDueDateResolver.hasExplicitTimeCue(in: "本周之内去趟银行"))
        XCTAssertTrue(TodoDueDateResolver.hasExplicitTimeCue(in: "三个工作日内交付"))
        XCTAssertTrue(TodoDueDateResolver.hasExplicitTimeCue(in: "Finish the deck sometime this week"))
        XCTAssertTrue(TodoDueDateResolver.hasExplicitTimeCue(in: "Clean the garage by the end of the week"))
        XCTAssertTrue(TodoDueDateResolver.hasExplicitTimeCue(in: "Ship it within three business days"))
    }

    /// 第二批(节假日/营业日/今週中,dataset ja-041~052 等价原话,2026-11-27 总审补):
    /// 祝日名指定必须算有线索 —— 注入表支持全部法定祝日名,词表缺名(ja-048
    /// スポーツの日)曾导致端上清空日期,这里逐名钉住。営業日/週明け/今週中
    /// 已由补充词覆盖,一并回归。
    func testBatch2HolidayAndBizDayTranscriptsHaveCue() {
        // dataset 原话(user_explicit 且 due 非空的第二批 case)
        for transcript in [
            "週明けに見積もりを送る",                       // ja-041
            "来週明けに部長に報告する",                     // ja-042
            "翌営業日までに先方に返信する",                 // ja-043
            "3営業日以内に議事録を共有する",                // ja-044
            "5営業日後に検品結果を連絡する",                // ja-045
            "15営業日以内に契約書を返送する",               // ja-046(due null 但仍是明确日期意向)
            "勤労感謝の日に実家に帰る",                     // ja-047
            "スポーツの日に市民マラソンに出る",             // ja-048 —— 总审修复点
            "今週中に企画書を仕上げて、今週末は部屋を片付ける", // ja-051(今週中在前半)
            "週明けに取引先に電話して、見積もりを送る",     // ja-052
        ] {
            XCTAssertTrue(
                TodoDueDateResolver.hasExplicitTimeCue(in: transcript),
                "第二批原话应识别为明确时间线索:\(transcript)"
            )
        }
        // 法定祝日名逐个钉住(与注入表 16 祝日对齐;未被 dataset 用到的名字也必须有线索)
        for name in [
            "元日", "成人の日", "建国記念の日", "天皇誕生日", "春分の日", "昭和の日",
            "憲法記念日", "みどりの日", "こどもの日", "海の日", "山の日", "敬老の日",
            "秋分の日", "スポーツの日", "文化の日", "勤労感謝の日",
        ] {
            XCTAssertTrue(
                TodoDueDateResolver.hasExplicitTimeCue(in: "\(name)に予定を入れる"),
                "祝日名应识别为明确时间线索:\(name)"
            )
        }
    }
}
