import CoreGraphics
import CoreImage
import Foundation

/// A parsed Adobe `.cube` 3D lookup table, in the exact layout `CIColorCubeWithColorSpace` wants.
///
/// The `.cube` format and Core Image agree on cell ordering — red varies fastest, then green, with
/// blue selecting the plane (the SDK header: "the columns and rows of the data are indexed by red and
/// green, respectively. Each data plane is followed by the next higher plane … indexed by blue") — so
/// parsing is a straight copy with an alpha channel interleaved, no reordering.
nonisolated struct CubeLUT {
    /// Cells per axis (`LUT_3D_SIZE`). Passed to the filter's `cubeDimension`.
    let dimension: Int
    /// `dimension³ × 4` little-endian `Float32`s, RGBA, alpha premultiplied (always 1 here).
    let data: Data
}

/// Loads `.cube` files from the app bundle and caches the parsed result.
///
/// **The cache is not an optimization, it's a requirement.** `FilmStyleGrade` is called once per
/// video frame by the live preview, and the largest LUT here is a 33³ table — 35,937 text lines,
/// which is tens of milliseconds of parsing. Reparsing per frame would stall the viewfinder.
///
/// Caching the parsed `Data` (rather than a built `CIFilter`) is deliberate: `FilmStyleGrade` has two
/// concurrent callers on different queues — `PhotoCaptureService.renderQueue` and the video data
/// output queue — and a `CIFilter` is a mutable object with no documented thread safety. `Data` is a
/// value type, so handing the same instance to a freshly built filter on each call is safe, and reusing
/// one instance also gives Core Image the chance to recognize the cube texture it already uploaded.
nonisolated enum CubeLUTStore {
    private static let lock = NSLock()
    private static var cache: [String: CubeLUT] = [:]
    /// Names that failed to load. Without this a missing or malformed file is re-read and re-parsed on
    /// every single frame, which is far worse than the missing grade itself.
    private static var failures: Set<String> = []

    /// The parsed LUT for a bundle resource basename, or nil if it's missing or malformed.
    static func lut(named name: String) -> CubeLUT? {
        lock.lock()
        if let cached = cache[name] {
            lock.unlock()
            return cached
        }
        if failures.contains(name) {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let parsed = load(name: name)

        lock.lock()
        if let parsed {
            cache[name] = parsed
        } else {
            failures.insert(name)
        }
        lock.unlock()

        return parsed
    }

    /// Parses the given LUTs off the caller's thread, so the first frame graded with a style doesn't
    /// pay for the parse on the video queue. Safe to call repeatedly — already-cached names are no-ops.
    static func prewarm(_ names: [String]) {
        DispatchQueue.global(qos: .utility).async {
            for name in names { _ = lut(named: name) }
        }
    }

    private static func load(name: String) -> CubeLUT? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "cube"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }

    /// Hand-rolled rather than pulled from a dependency, because the format is trivial and the two
    /// things that actually bite are both handled here:
    /// - **CRLF line endings.** Two of the bundled LUTs are CRLF; a trailing `\r` on the last float of
    ///   every line makes `Float(_:)` return nil and the whole table parse as empty.
    /// - **Out-of-range cells.** `Float` cells are clamped to 0…1. One bundled LUT contains values as
    ///   low as −0.47 and as high as 1.008; the filter documents its table as premultiplied RGBA,
    ///   i.e. 0…1, so out-of-range cells are undefined input rather than extra headroom.
    ///
    /// `DOMAIN_MIN`/`DOMAIN_MAX` are recognized and skipped rather than honored: Core Image's cube
    /// filters have no input-domain concept, so supporting a non-0…1 domain would mean rescaling the
    /// image before the lookup. None of the bundled LUTs declare one (they're display-referred, not
    /// log), so that work would be speculative.
    static func parse(_ text: String) -> CubeLUT? {
        var dimension: Int?
        var cells: [Float] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let first = line.first else { continue }

            // Every data line starts with a digit, a sign, or a decimal point; everything else is a
            // comment or a keyword (LUT_3D_SIZE, TITLE, DOMAIN_MIN/MAX, LUT_1D_SIZE).
            guard first.isNumber || first == "-" || first == "+" || first == "." else {
                guard line.hasPrefix("LUT_3D_SIZE") else { continue }
                guard let value = Int(line.dropFirst("LUT_3D_SIZE".count).trimmingCharacters(in: .whitespaces)),
                      value >= 2 else { return nil }
                dimension = value
                cells.reserveCapacity(value * value * value * 4)
                continue
            }

            let components = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard components.count == 3,
                  let r = Float(components[0]),
                  let g = Float(components[1]),
                  let b = Float(components[2]) else { return nil }

            cells.append(min(max(r, 0), 1))
            cells.append(min(max(g, 0), 1))
            cells.append(min(max(b, 0), 1))
            cells.append(1)
        }

        guard let dimension, cells.count == dimension * dimension * dimension * 4 else { return nil }
        let data = cells.withUnsafeBufferPointer { Data(buffer: $0) }
        return CubeLUT(dimension: dimension, data: data)
    }
}
