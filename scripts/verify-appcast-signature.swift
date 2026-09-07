import Foundation
import CryptoKit

// Verify the final (already stapled) archive against the key and metadata in the
// packaged app. Neither a successful signer invocation nor a nonempty XML proves it.
do {
    guard CommandLine.arguments.count == 4 else { throw Failure.invalid("usage: verify-appcast-signature.swift <appcast> <archive> <packaged Info.plist>") }
    let args = CommandLine.arguments
    let xml = try XMLDocument(contentsOf: URL(fileURLWithPath: args[1]))
    let archive = try Data(contentsOf: URL(fileURLWithPath: args[2]), options: .mappedIfSafe)
    let plistData = try Data(contentsOf: URL(fileURLWithPath: args[3]))
    guard let info = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else { throw Failure.invalid("invalid packaged plist") }
    func one(_ path: String) throws -> String {
        let nodes = try xml.nodes(forXPath: path)
        guard nodes.count == 1, let value = nodes[0].stringValue, !value.isEmpty else { throw Failure.invalid("expected exactly one \(path)") }
        return value
    }
    let item = "/rss/channel/item"
    guard try xml.nodes(forXPath: item).count == 1 else { throw Failure.invalid("expected exactly one update") }
    guard let encodedKey = info["SUPublicEDKey"] as? String, let key = Data(base64Encoded: encodedKey),
          let signature = Data(base64Encoded: try one(item + "/enclosure/@sparkle:edSignature")) else { throw Failure.invalid("invalid key or signature encoding") }
    guard try Curve25519.Signing.PublicKey(rawRepresentation: key).isValidSignature(signature, for: archive) else { throw Failure.invalid("archive signature does not match the packaged public key") }
    guard try one(item + "/enclosure/@length") == String(archive.count) else { throw Failure.invalid("archive length mismatch") }
    for (element, key) in [("version", "CFBundleVersion"), ("shortVersionString", "CFBundleShortVersionString"), ("minimumSystemVersion", "LSMinimumSystemVersion")] {
        guard try one(item + "/sparkle:" + element) == info[key] as? String else { throw Failure.invalid("appcast \(element) differs from packaged \(key)") }
    }
    print("PASS: archive signature, length, versions, and minimum macOS match the packaged app")
} catch {
    fputs("Appcast verification failed: \(error)\n", stderr)
    exit(1)
}
enum Failure: Error { case invalid(String) }
