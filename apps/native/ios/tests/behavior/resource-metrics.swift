import XCTest
import SwiftUI

struct ResourcePoint: Equatable {
    let time: Int64
    let cpuCores: Double?
    let memoryBytes: Double?
    let readBytes: Double?
    let writeBytes: Double?
    let runId: String
}

final class ResourceMetricTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor func testUnitsGapsRestartsAndSelection() {
        var points: [ResourcePoint] = []
        for minute in 0..<90 {
            let time: Int64 = 1_794_737_400_000 + Int64(minute) * 60_000
            let cpu: Double? = minute == 35 ? nil : 0.3 + abs(sin(Double(minute) / 8.0)) * 1.8
            let memory: Double = Double(450 + minute * 3) * 1_048_576.0
            let read: Double = Double(minute % 12) * 1_048_576.0
            let write: Double = Double(minute % 4) * 524_288.0
            points.append(ResourcePoint(time: time, cpuCores: cpu, memoryBytes: memory,
                                        readBytes: read, writeBytes: write,
                                        runId: minute < 60 ? "first" : "restarted"))
        }
        // Check genuine transformation behavior, including zero, unknown values,
        // byte units and gaps. No source-text or implementation-mirroring tests.
        let cpu = ResourceMetric.cpu.samples(from: points)
        XCTAssertTrue(cpu.count == 89)
        XCTAssertTrue(cpu[34].segment != cpu[35].segment, "Missing sample must break the line")
        XCTAssertTrue(cpu[58].segment != cpu[59].segment, "Restart must break the line")
        XCTAssertTrue(ResourceMetric.memory.samples(from: points).first?.value == 450)
        let sparse = [
            ResourcePoint(time: 0, cpuCores: 0, memoryBytes: nil, readBytes: 0, writeBytes: nil, runId: "a"),
            ResourcePoint(time: 180_000, cpuCores: 2, memoryBytes: nil, readBytes: 1_048_576, writeBytes: nil, runId: "a"),
            ResourcePoint(time: 240_000, cpuCores: .nan, memoryBytes: nil, readBytes: nil, writeBytes: nil, runId: "a")
        ]
        let sparseCPU = ResourceMetric.cpu.samples(from: sparse)
        XCTAssertTrue(sparseCPU.count == 2 && sparseCPU[0].value == 0)
        XCTAssertTrue(sparseCPU[0].segment != sparseCPU[1].segment)
        XCTAssertTrue(ResourceMetric.read.samples(from: sparse).last?.value == 1)
        XCTAssertTrue(ResourceMetric.memory.samples(from: sparse).isEmpty)
        let reads = ResourceMetric.read.samples(from: sparse)
        XCTAssertTrue(ResourceMetric.read.sample(at: Date(timeIntervalSince1970: 45), in: reads)?.value == 0,
                     "Disk selection must use the selected minute, not the next minute")
        XCTAssertTrue(ResourceMetric.read.sample(at: Date(timeIntervalSince1970: 90), in: reads) == nil)
        XCTAssertTrue(ResourceMetric.cpu.sample(at: Date(timeIntervalSince1970: 90), in: sparseCPU) == nil)

    }
}
