import CryptoKit
import Foundation

/// The catalogue is a security boundary: a GGUF is parsed by ggml inside the
/// process that holds Accessibility over every app on the Mac, so the size and
/// digest recorded for each entry are what decide whether arbitrary bytes get
/// that far.
///
/// These lock in the shape of every entry. Given a downloaded model, they also
/// check the real thing — run with a path to the Models directory, or let the
/// default find it, and any file present is hashed against its catalogue entry.

var failures = 0
@MainActor func check(_ label: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL") \(label)")
    if !condition { failures += 1 }
}

// MARK: Shape

for spec in ModelRepository.catalogue {
    // 64 lowercase hex characters, or it is not a SHA-256 and was typed by
    // hand. This is the cheap guard against a digest pasted short.
    let digest = spec.sha256
    check("\(spec.id) digest is 64 characters", digest.count == 64)
    check("\(spec.id) digest is lowercase hex",
          digest.allSatisfy { $0.isHexDigit && !$0.isUppercase })

    // A size that is a round binary number is the signature of a guess, which
    // is exactly how 768 MiB came to stand in for Gemma 3 1B.
    check("\(spec.id) size is not a suspiciously round number",
          spec.sizeBytes % (1024 * 1024) != 0)
    check("\(spec.id) has a plausible size", spec.sizeBytes > 100_000_000)

    check("\(spec.id) downloads over https", spec.url.scheme == "https")
    check("\(spec.id) downloads from huggingface.co", spec.url.host() == "huggingface.co")
}

let digests = ModelRepository.catalogue.map(\.sha256)
check("no two entries share a digest", Set(digests).count == digests.count)
let ids = ModelRepository.catalogue.map(\.id)
check("no two entries share an id", Set(ids).count == ids.count)

// MARK: The real files, when they are here

let directory = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FreeTypist/Models")

func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

var checked = 0
for spec in ModelRepository.catalogue {
    let file = directory.appendingPathComponent(spec.file)
    guard FileManager.default.fileExists(atPath: file.path) else { continue }
    checked += 1

    let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
    let size = (attributes?[.size] as? Int64) ?? 0
    check("\(spec.file) on disk is the size the catalogue claims", size == spec.sizeBytes)
    check("\(spec.file) on disk hashes to the digest the catalogue claims",
          (try? sha256(of: file)) == spec.sha256)
}
print(checked == 0
      ? "\nNOTE  no models downloaded; shape checked, contents not"
      : "\nchecked \(checked) downloaded model(s) against the catalogue")

print(failures == 0 ? "All catalogue cases passed." : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
