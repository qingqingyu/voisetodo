import XCTest
@testable import VoiceTodo

/// `MarqueePhase` 的纯函数测试。
///
/// 覆盖方案里列出的 6 条不变量:
/// 1. `travel == 0` 时 offset 恒 0 / opacity 恒 1(零成本路径)
/// 2. 停顿段 offset 不变(首停 = 0、末停 = -travel)
/// 3. 滚动段 offset 单调不增
/// 4. 滚动结束时 offset == -travel
/// 5. 周期性 offset(t) == offset(t + cycleDuration)、opacity 同样
/// 6. opacity 在位移归零的那一刻恰好为 0(回跳不可见)
/// 7. 边缘遮罩:起点 leading=1、滚过 fadeWidth 后=0;终点 trailing=1
/// 8. stableHash:同一字符串跨调用恒定、不同字符串分散
final class MarqueePhaseTests: XCTestCase {

    // 用一个 travel > 0 的样本做大部分断言。具体取值不影响不变量,
    // 但要够大让 fadeWidth(默认 10)的渐隐过程能体现。
    private let sample = MarqueePhase(travel: 100)
    private let tolerance: Double = 1e-9

    // MARK: - travel == 0 零成本路径

    func testZeroTravelOffsetIsAlwaysZero() {
        let phase = MarqueePhase(travel: 0)
        for t in stride(from: 0.0, through: 10.0, by: 0.1) {
            XCTAssertEqual(phase.offset(at: t), 0, accuracy: 1e-9, "t=\(t)")
        }
    }

    func testZeroTravelOpacityIsAlwaysOne() {
        let phase = MarqueePhase(travel: 0)
        for t in stride(from: 0.0, through: 10.0, by: 0.1) {
            XCTAssertEqual(phase.opacity(at: t), 1, accuracy: 1e-9, "t=\(t)")
        }
    }

    func testZeroTravelEdgeOpacitiesAreFull() {
        let phase = MarqueePhase(travel: 0)
        let edges = phase.edgeOpacities(at: 1.0)
        XCTAssertEqual(edges.leading, 1, accuracy: 1e-9)
        XCTAssertEqual(edges.trailing, 1, accuracy: 1e-9)
    }

    // MARK: - 停顿段

    func testStartPauseOffsetIsZero() {
        // [0, startPause) 内 offset = 0
        let pause = sample.startPause
        XCTAssertEqual(sample.offset(at: 0), 0, accuracy: tolerance)
        XCTAssertEqual(sample.offset(at: pause / 2), 0, accuracy: tolerance)
        XCTAssertEqual(sample.offset(at: pause - 0.01), 0, accuracy: tolerance)
    }

    func testEndPauseOffsetIsNegativeTravel() {
        // [startPause + scrollDuration, cycleDuration) 内 offset = -travel
        let scrollEnd = sample.startPause + sample.scrollDuration
        XCTAssertEqual(sample.offset(at: scrollEnd), -sample.travel, accuracy: tolerance)
        XCTAssertEqual(sample.offset(at: (scrollEnd + sample.cycleDuration) / 2),
                       -sample.travel, accuracy: tolerance)
        XCTAssertEqual(sample.offset(at: sample.cycleDuration - 0.01),
                       -sample.travel, accuracy: tolerance)
    }

    // MARK: - 滚动段单调

    func testScrollPhaseOffsetMonotonicNonIncreasing() {
        // 在滚动段内,offset 应单调不增(向负方向走)
        let scrollStart = sample.startPause
        let scrollEnd = sample.startPause + sample.scrollDuration
        var prev = sample.offset(at: scrollStart)
        let steps = 50
        let dt = (scrollEnd - scrollStart) / Double(steps)
        for i in 1...steps {
            let t = scrollStart + Double(i) * dt
            let cur = sample.offset(at: t)
            XCTAssertLessThanOrEqual(cur, prev + tolerance,
                                     "t=\(t): offset should not increase, prev=\(prev) cur=\(cur)")
            prev = cur
        }
    }

    func testScrollEndsAtNegativeTravel() {
        // 滚动结束的那一帧 offset == -travel
        let scrollEnd = sample.startPause + sample.scrollDuration
        XCTAssertEqual(sample.offset(at: scrollEnd), -sample.travel, accuracy: tolerance)
    }

    // MARK: - 周期性

    func testOffsetPeriodicity() {
        // offset(t) == offset(t + cycleDuration)
        let cycle = sample.cycleDuration
        for t in stride(from: 0.0, through: cycle, by: cycle / 20) {
            XCTAssertEqual(sample.offset(at: t), sample.offset(at: t + cycle),
                           accuracy: tolerance, "t=\(t)")
        }
    }

    func testOpacityPeriodicity() {
        let cycle = sample.cycleDuration
        for t in stride(from: 0.0, through: cycle, by: cycle / 20) {
            XCTAssertEqual(sample.opacity(at: t), sample.opacity(at: t + cycle),
                           accuracy: tolerance, "t=\(t)")
        }
    }

    // MARK: - 位移归零那一刻 opacity 为 0(回跳不可见)

    func testOpacityAtCycleBoundaryIsZero() {
        // 周期首末(t = 0, t = cycleDuration)位移归零,opacity 必须 == 0
        // 这是"淡出回头"设计成立的关键——位移瞬间归零发生在不可见帧。
        XCTAssertEqual(sample.opacity(at: 0), 0, accuracy: tolerance)
        XCTAssertEqual(sample.opacity(at: sample.cycleDuration), 0, accuracy: tolerance)
    }

    func testOpacityIsOneDuringMiddleSteadyRegion() {
        // 中间稳定段 opacity = 1
        let midScroll = sample.startPause + sample.scrollDuration / 2
        XCTAssertEqual(sample.opacity(at: midScroll), 1, accuracy: tolerance)
    }

    // MARK: - 边缘遮罩

    func testEdgeMaskAtStartPauseLeadingIsFull() {
        // 首停期间位移 = 0,scrolled = 0,leading 应 == 1(左侧贴开头,不该虚)
        let edges = sample.edgeOpacities(at: sample.startPause / 2)
        XCTAssertEqual(edges.leading, 1, accuracy: tolerance)
    }

    func testEdgeMaskAtStartPauseTrailingIsZero() {
        // 首停期间 remaining = travel,fadeWidth=10,travel=100 → trailing = 1 - min(1, 100/10) = 0
        let edges = sample.edgeOpacities(at: sample.startPause / 2)
        XCTAssertEqual(edges.trailing, 0, accuracy: tolerance)
    }

    func testEdgeMaskAtScrollEndTrailingIsFull() {
        // 滚到尾:scrolled = travel,remaining = 0,trailing 应 == 1(右侧贴尾段,不该虚)
        let scrollEnd = sample.startPause + sample.scrollDuration
        let edges = sample.edgeOpacities(at: scrollEnd)
        XCTAssertEqual(edges.trailing, 1, accuracy: tolerance)
    }

    func testEdgeMaskAtScrollEndLeadingIsZero() {
        // 滚到尾:scrolled = travel = 100,fadeWidth = 10 → leading = 1 - min(1, 100/10) = 0
        let scrollEnd = sample.startPause + sample.scrollDuration
        let edges = sample.edgeOpacities(at: scrollEnd)
        XCTAssertEqual(edges.leading, 0, accuracy: tolerance)
    }

    func testEdgeMaskLeadingDecreasesMonotonicallyDuringScroll() {
        let scrollStart = sample.startPause
        let scrollEnd = sample.startPause + sample.scrollDuration
        var prev = sample.edgeOpacities(at: scrollStart).leading
        let steps = 30
        let dt = (scrollEnd - scrollStart) / Double(steps)
        for i in 1...steps {
            let t = scrollStart + Double(i) * dt
            let cur = sample.edgeOpacities(at: t).leading
            XCTAssertLessThanOrEqual(cur, prev + tolerance,
                                     "t=\(t): leading should not increase")
            prev = cur
        }
    }

    func testEdgeMaskTrailingIncreasesMonotonicallyDuringScroll() {
        let scrollStart = sample.startPause
        let scrollEnd = sample.startPause + sample.scrollDuration
        var prev = sample.edgeOpacities(at: scrollStart).trailing
        let steps = 30
        let dt = (scrollEnd - scrollStart) / Double(steps)
        for i in 1...steps {
            let t = scrollStart + Double(i) * dt
            let cur = sample.edgeOpacities(at: t).trailing
            XCTAssertGreaterThanOrEqual(cur, prev - tolerance,
                                        "t=\(t): trailing should not decrease")
            prev = cur
        }
    }

    // MARK: - stableHash

    func testStableHashIsDeterministicAcrossCalls() {
        // 同一字符串多次调用结果相同(跨进程稳定由算法保证,这里只验证进程内)
        let s = "by the end of this month"
        let h1 = MarqueePhase.stableHash(s)
        let h2 = MarqueePhase.stableHash(s)
        XCTAssertEqual(h1, h2)
    }

    func testStableHashDifferentForDifferentStrings() {
        // 不同字符串哈希应不同(只断言"不等",不断言具体值)
        let strings = [
            "by the end of this month",
            "this weekend",
            "around the middle of the month",
            "每个月15号下午3点",
            "tonight",
        ]
        var seen: Set<UInt64> = []
        for s in strings {
            let h = MarqueePhase.stableHash(s)
            XCTAssertFalse(seen.contains(h), "hash 冲突:\"\(s)\" 跟前面某条哈希值相同")
            seen.insert(h)
        }
    }

    func testStableHashPhaseShiftDispersesAcrossStrings() {
        // 不同文本映射到 [0, 1) 的相位偏移应分散,不全挤在一起。
        // 这是"错峰"设计成立的前提——若 100 条 hint 都映射到 0-0.1 区间,
        // 错峰效果就废了。断言:5 个不同字符串的偏移分布跨度 >= 0.4。
        let cycle = sample.cycleDuration
        guard cycle > 0 else {
            XCTFail("sample.cycleDuration 应 > 0")
            return
        }
        let strings = [
            "by the end of this month",
            "this weekend",
            "around the middle of the month",
            "每个月15号下午3点",
            "tonight",
        ]
        let offsets = strings.map { s in
            Double(MarqueePhase.stableHash(s) % 1000) / 1000
        }
        let spread = offsets.max()! - offsets.min()!
        XCTAssertGreaterThanOrEqual(spread, 0.4,
                                    "相位偏移分散度不足:spread=\(spread),offsets=\(offsets)")
    }
}
