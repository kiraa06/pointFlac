#!/usr/bin/env swift
// Builds App/Resources/OPRA/opra.json (and copies the OPRA logo) from a checkout of the OPRA project's database.
//
//     git clone https://github.com/opra-project/OPRA.git /some/scratch/dir/opra
//     git -C /some/scratch/dir/opra checkout 0b88ecd4e2bef7cf69fd5d50f1d06fb586c10865
//     swift scripts/build-opra.swift /some/scratch/dir/opra [--exclude-author <name>]...
//
// AutoEq results are never bundled (spec 4.8; only the user's own import of a ParametricEQ.txt is allowed), so every
// preset whose author contains "AutoEQ" (case-insensitive, e.g. "AutoEQ", "Rtings/AutoEQ") is dropped BY DEFAULT.
// --exclude-author additionally drops every preset by that exact author (repeatable).
//
// OPRA's data is CC BY-SA 4.0 (see App/ThirdPartyNotices.txt). The output is deterministic: presets sorted by id,
// keys sorted, one preset per line, so re-running on the same commit gives a byte-identical file.
//
// Every preset keeps its author. Presets with more than 20 bands, or with a band type the equaliser model cannot
// represent, are skipped and counted. Nothing is clamped here; values outside SoundSettings.clamped()'s ranges are
// kept as they are and counted, because the app clamps on load.

import Foundation

/// The OPRA commit the shipped JSON was built from.
let pinnedCommit = "0b88ecd4e2bef7cf69fd5d50f1d06fb586c10865"
let maxBands = 20

struct Band: Encodable {
    var type: String
    var fc: Double
    var gain: Double
    var q: Double
}

struct Preset: Encodable {
    var id: String
    var vendor: String
    var product: String
    var author: String
    var details: String
    var preampDb: Double
    var bands: [Band]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let usage = "usage: swift scripts/build-opra.swift <path-to-OPRA-checkout> [--exclude-author <name>]..."
var args = Array(CommandLine.arguments.dropFirst())
var excludedAuthors: Set<String> = []
while let i = args.firstIndex(of: "--exclude-author") {
    guard i + 1 < args.count else { fail(usage) }
    excludedAuthors.insert(args[i + 1])
    args.removeSubrange(i...(i + 1))
}
guard args.count == 1 else { fail(usage) }
let checkout = URL(fileURLWithPath: args[0], isDirectory: true)
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let outDir = repoRoot.appendingPathComponent("App/Resources/OPRA", isDirectory: true)

// The checkout must be the pinned commit, so the output is reproducible.
let git = Process()
git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
git.arguments = ["-C", checkout.path, "rev-parse", "HEAD"]
let pipe = Pipe()
git.standardOutput = pipe
try git.run()
let head = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
git.waitUntilExit()
guard head == pinnedCommit else { fail("checkout is at \(head), expected \(pinnedCommit)") }

let dump = checkout.appendingPathComponent("dist/database_v1.jsonl")
guard let data = FileManager.default.contents(atPath: dump.path) else { fail("cannot read \(dump.path)") }

// OPRA band type -> FilterType raw value. band_pass and band_stop have no counterpart in the model.
let typeMap = [
    "peak_dip": "peak", "low_shelf": "lowShelf", "high_shelf": "highShelf", "low_pass": "lowPass",
    "high_pass": "highPass",
]

var vendors: [String: String] = [:]
var products: [String: (name: String, vendor: String)] = [:]
var eqs: [(id: String, data: [String: Any])] = []

for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
    guard let obj = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
        let kind = obj["type"] as? String, let id = obj["id"] as? String, let d = obj["data"] as? [String: Any]
    else { fail("unreadable line in \(dump.lastPathComponent)") }
    switch kind {
    case "vendor": vendors[id] = d["name"] as? String
    case "product":
        if let name = d["name"] as? String, let v = d["vendor_id"] as? String { products[id] = (name, v) }
    case "eq": eqs.append((id, d))
    default: break
    }
}

var presets: [Preset] = []
var skippedTooMany = 0
var skippedType = 0
var skippedOrphan = 0
var skippedAuthor = 0
var outOfRange = 0
var outOfRangeBands = 0
var authors: [String: Int] = [:]

for (id, d) in eqs {
    guard let productId = d["product_id"] as? String, let product = products[productId],
        let vendor = vendors[product.vendor], let author = d["author"] as? String,
        let params = d["parameters"] as? [String: Any], let raw = params["bands"] as? [[String: Any]]
    else {
        skippedOrphan += 1
        continue
    }
    if excludedAuthors.contains(author) || author.range(of: "autoeq", options: .caseInsensitive) != nil {
        skippedAuthor += 1
        continue
    }
    if raw.count > maxBands {
        skippedTooMany += 1
        continue
    }
    var bands: [Band] = []
    var representable = true
    for b in raw {
        let type = (b["type"] as? String).flatMap { typeMap[$0] }
        guard let t = type, let fc = (b["frequency"] as? NSNumber)?.doubleValue else {
            representable = false
            break
        }
        let gain = (b["gain_db"] as? NSNumber)?.doubleValue ?? 0
        let q = (b["q"] as? NSNumber)?.doubleValue ?? 0.7071
        bands.append(Band(type: t, fc: fc, gain: gain, q: q))
    }
    if !representable {
        skippedType += 1
        continue
    }
    // The ranges of SoundSettings.clamped(): 20...20000 Hz, -24...24 dB, Q 0.1...20.
    let bad = bands.filter { $0.fc < 20 || $0.fc > 20_000 || abs($0.gain) > 24 || $0.q < 0.1 || $0.q > 20 }.count
    if bad > 0 {
        outOfRange += 1
        outOfRangeBands += bad
    }
    authors[author, default: 0] += 1
    presets.append(
        Preset(
            id: id, vendor: vendor, product: product.name, author: author, details: d["details"] as? String ?? "",
            preampDb: (params["gain_db"] as? NSNumber)?.doubleValue ?? 0, bands: bands))
}

presets.sort { $0.id < $1.id }

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
var out = Data("[\n".utf8)
for (i, p) in presets.enumerated() {
    out.append(try encoder.encode(p))
    out.append(Data((i == presets.count - 1 ? "\n" : ",\n").utf8))
}
out.append(Data("]\n".utf8))

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
try out.write(to: outDir.appendingPathComponent("opra.json"))

// The logo OPRA asks browsers of its database to show.
let logo = outDir.appendingPathComponent("opra_logo.png")
try? FileManager.default.removeItem(at: logo)
try FileManager.default.copyItem(at: checkout.appendingPathComponent("images/opra_logo.png"), to: logo)

print("commit \(head)")
print("presets written: \(presets.count) (\(out.count) bytes)")
print("skipped, more than \(maxBands) bands: \(skippedTooMany)")
print("skipped, unrepresentable band type: \(skippedType)")
print("skipped, no vendor/product: \(skippedOrphan)")
print("skipped, AutoEq-derived or excluded author: \(skippedAuthor)")
print("presets with values outside clamped() ranges: \(outOfRange) (\(outOfRangeBands) bands), kept as is")
for (a, n) in authors.sorted(by: { $0.key < $1.key }) { print("author \(a): \(n)") }
