import Foundation
@testable import GaryCore
import Testing

struct JSONTests {
    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func `a non finite number encodes as null`(_ value: Double) {
        #expect(JSON.object(["x": .number(value)]).text == #"{"x":null}"#)
    }
}
