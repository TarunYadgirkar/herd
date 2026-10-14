import Foundation
import Testing
@testable import Herd

@Suite struct SortOrderTests {
    private let cpuDown = [KeyPathComparator(\TableRowItem.cpu, order: .reverse)]

    @Test func newNumberColumnStartsLargestFirst() {
        let clicked = [KeyPathComparator(\TableRowItem.memory, order: .forward)]
        let result = TableRowBuilder.largestFirstOnNewColumn(clicked, previous: cpuDown)
        #expect(result.first?.keyPath == \TableRowItem.memory)
        #expect(result.first?.order == .reverse)
    }

    @Test func secondClickOnSameColumnStillFlips() {
        let flipped = [KeyPathComparator(\TableRowItem.cpu, order: .forward)]
        #expect(TableRowBuilder.largestFirstOnNewColumn(flipped, previous: cpuDown).first?.order == .forward)
    }

    @Test func nameColumnKeepsAlphabeticalOrder() {
        let byName = [KeyPathComparator(\TableRowItem.title, order: .forward)]
        #expect(TableRowBuilder.largestFirstOnNewColumn(byName, previous: cpuDown).first?.order == .forward)
    }
}
