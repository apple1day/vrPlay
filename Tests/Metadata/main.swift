import Foundation

private func bigEndian<T: FixedWidthInteger>(_ n: T) -> Data {
    withUnsafeBytes(of: n.bigEndian) { Data($0) }
}

private func box(_ type: String, _ payload: Data) -> Data {
    bigEndian(UInt32(8 + payload.count)) + Data(type.utf8) + payload
}

private func run() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let url = dir.appendingPathComponent("sample.mp4")
    let mdatSize: UInt64 = (1 << 32) + 256
    let paddingSize: UInt32 = 128 * 1024 * 1024
    let mdatHeader = bigEndian(UInt32(1)) + Data("mdat".utf8) + bigEndian(mdatSize)
    try mdatHeader.write(to: url)

    let stereo = box("st3d", Data([0, 0, 0, 0, 2]))
    let spherical = box("sv3d", box("proj", box("equi", Data(repeating: 0, count: 20))))
    let sampleEntry = box("hvc1", Data(repeating: 0, count: 78) + stereo + spherical)
    var track = box("stsd", bigEndian(UInt32(0)) + bigEndian(UInt32(1)) + sampleEntry)
    for parent in ["stbl", "minf", "mdia", "trak"] { track = box(parent, track) }

    // Leave sparse holes in mdat and a large free atom, as in a recording with a trailing moov.
    // The fixture exercises both 64-bit offsets and a moov beyond the former 128 MiB cap.
    let handle = try FileHandle(forWritingTo: url)
    do {
        defer { try? handle.close() }
        try handle.seek(toOffset: mdatSize)
        let moovSize = UInt32(8 + track.count) + paddingSize
        try handle.write(contentsOf: bigEndian(moovSize) + Data("moov".utf8))
        try handle.write(contentsOf: bigEndian(paddingSize) + Data("free".utf8))
        try handle.seek(toOffset: mdatSize + 8 + UInt64(paddingSize))
        try handle.write(contentsOf: track)
    }
    let metadata = MP4SpatialMetadata.read(from: url)
    guard metadata?.layout == .sideBySide, metadata?.projection == .sphere360 else {
        throw NSError(domain: "MetadataRegression", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Missing 360° SBS metadata after the sparse media payload"])
    }

    // The oversized child starts at a nonzero offset and cannot fit within its parent.
    let invalidChild = bigEndian(UInt32(1)) + Data("trak".utf8) + bigEndian(UInt64.max)
    let malformed = dir.appendingPathComponent("malformed.mp4")
    try box("moov", invalidChild).write(to: malformed)
    guard MP4SpatialMetadata.read(from: malformed) == nil else {
        throw NSError(domain: "MetadataRegression", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Malformed extended box produced metadata"])
    }
    print("Passed sparse >4 GiB MP4, large trailing moov, and malformed extended-size tests")
}

try run()
