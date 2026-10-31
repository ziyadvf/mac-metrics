import Foundation

struct SaturationAlert {
    private var began: TimeInterval?
    private var lastSample: TimeInterval?
    private(set) var isActive = false

    mutating func sample(_ value: Double?, at time: TimeInterval, maximumGap: TimeInterval) {
        if let lastSample, time - lastSample > maximumGap || time < lastSample {
            began = nil
        }
        lastSample = time
        guard let value, value.isFinite, value.rounded() >= 100 else {
            began = nil
            isActive = false
            return
        }
        if began == nil { began = time }
        isActive = time - (began ?? time) >= 10
    }
}
