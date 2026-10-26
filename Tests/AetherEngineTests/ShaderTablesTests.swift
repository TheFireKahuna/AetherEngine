import Foundation
import Metal
import Testing
@testable import AetherEngine

/// What the Metal sources state as numbers, each equal to what it is derived from, and the finisher's functions as the
/// shipped library declares them.
struct ShaderTablesTests {

    /// The text of `constant ... name... = <value>;` in `source`: the braces' contents for a table.
    static func value(of name: String, in source: String) throws -> String {
        let start = try #require(source.range(of: " \(name)"), "no constant \(name)")
        let assign = try #require(source.range(of: "=", range: start.upperBound..<source.endIndex))
        let end = try #require(source.range(of: ";", range: assign.upperBound..<source.endIndex))
        return source[assign.upperBound..<end.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: " \n{}"))
    }

    /// A table's entries: each `float2(...)`, or each number.
    static func entries(of name: String, in source: String) throws -> [String] {
        let text = try value(of: name, in: source)
        let pattern = text.contains("float2") ? #"float2\([^)]*\)"# : #"[-0-9a-fx.p+]+f?"#
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range, in: text)!])
        }
    }

    /// A value as the nearest float and the nearest float to the remainder, in hex.
    static func split(_ v: Double) -> String {
        let hi = Float(v)
        return "float2(\(String(format: "%a", Double(hi)))f, \(String(format: "%a", Double(Float(v - Double(hi)))))f)"
    }

    @Test("the finisher's double-float constants and exp2 / log2 tables are the values computed in double")
    func finisherTables() throws {
        let source = try ShaderFiles.finisher()
        let ln2 = log(2.0)
        let constants: [(String, Double)] = [("PF_LN2", ln2), ("PF_LOG2E", 1 / ln2), ("PF_INV3", 1.0 / 3), ("PF_INV5", 1.0 / 5),
                                             ("PF_INV6", 1.0 / 6), ("PF_INV12", 1.0 / 12), ("PF_INV24", 1.0 / 24),
                                             ("PF_INV120", 1.0 / 120)]
        for (name, value) in constants { #expect(try Self.value(of: name, in: source) == Self.split(value), "\(name)") }
        // 2^(j / 64), j = -32 ... 32.
        #expect(try Self.entries(of: "PF_EXP2_T[65]", in: source) == (-32...32).map { Self.split(pow(2, Double($0) / 64)) })
        // c_i ~ 1 / x for x in [1 + i / 128, 1 + (i + 1) / 128), and log2(1 / c_i) of that float c_i.
        let c = (0..<128).map { Float(1 / (1 + (Double($0) + 0.5) / 128)) }
        #expect(try Self.entries(of: "PF_LOG_C[128]", in: source) == c.map { String(format: "%af", Double($0)) })
        #expect(try Self.entries(of: "PF_LOG_L[128]", in: source) == c.map { Self.split(-log2(Double($0))) })
    }

    @Test("film grain's buffer layout and header words are the CPU's")
    func filmGrainLayout() throws {
        typealias S = FilmGrainSynthesis
        let source = try ShaderFiles.filmGrain()
        func number(_ name: String) throws -> Int {
            try #require(Int(try Self.value(of: name, in: source).trimmingCharacters(in: CharacterSet(charactersIn: "u"))))
        }
        #expect(try number("FG_TEMPLATES") == S.templatesOffset)
        #expect(try number("FG_SCALING") == S.scalingOffset)
        #expect(try number("FG_SCALING_STRIDE") == S.scalingStride)
        #expect(try number("FG_OFFSETS") == S.offsetsOffset)
        #expect(try number("FG_TW") == S.templateWidth)
        #expect(try number("FG_TH") == S.templateHeight)
        #expect(try number("FG_SUB_TW") == S.subTemplateWidth)
        #expect(try number("FG_SUB_TH") == S.subTemplateHeight)
        let words: [(String, S.Header)] = [
            ("FG_H_SCALING_SHIFT", .scalingShift), ("FG_H_MIN_VALUE", .minValue), ("FG_H_MAX_LUMA", .maxLuma),
            ("FG_H_MAX_CHROMA", .maxChroma), ("FG_H_OVERLAP", .overlap), ("FG_H_CHROMA_SCALING_FROM_LUMA", .chromaScalingFromLuma),
            ("FG_H_ACTIVE_Y", .activeY), ("FG_H_ACTIVE_CB", .activeCb), ("FG_H_ACTIVE_CR", .activeCr),
            ("FG_H_CB_MULT", .cbMult), ("FG_H_CR_MULT", .crMult), ("FG_H_CB_LUMA_MULT", .cbLumaMult),
            ("FG_H_CR_LUMA_MULT", .crLumaMult), ("FG_H_CB_OFFSET", .cbOffset), ("FG_H_CR_OFFSET", .crOffset),
            ("FG_H_BLOCK_COLUMNS", .blockColumns), ("FG_H_BIT_DEPTH_MINUS_8", .bitDepthMinus8),
        ]
        for (name, word) in words { #expect(try number(name) == word.rawValue, "\(name)") }
    }

    @Test("film grain's LFSR jumps are the step's powers")
    func filmGrainJumps() throws {
        // The 16-bit LFSR's step, a linear map over GF(2): column b is what the state bit b alone becomes. Its 2^j-th
        // powers, j = 0 ... 12 (a template's 5,986 draws).
        func step(_ r: UInt32) -> UInt32 {
            let bit = (r ^ (r >> 1) ^ (r >> 3) ^ (r >> 12)) & 1
            return (r >> 1) | (bit << 15)
        }
        func apply(_ columns: [UInt16], _ v: UInt16) -> UInt16 {
            var out: UInt16 = 0
            for b in 0..<16 where v & (1 << b) != 0 { out ^= columns[b] }
            return out
        }
        var powers: [[UInt16]] = [(0..<16).map { UInt16(step(UInt32(1) << $0)) }]
        for _ in 1..<13 {
            let m = powers.last!
            powers.append(m.map { apply(m, $0) })
        }
        let shader = try Self.entries(of: "FG_JUMP[13][16]", in: ShaderFiles.filmGrain()).compactMap { UInt16($0) }
        #expect(shader == powers.flatMap { $0 })
    }

    @Test("the finisher's functions without constants are those the library declares none for",
          .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
    func unspecialisedFunctions() throws {
        let library = try EngineShaders.library(for: try #require(MTLCreateSystemDefaultDevice()))
        let finisher = library.functionNames.filter { $0.hasPrefix("pf_") || $0.hasPrefix("fg_") }
        let plain = try finisher.filter { name in
            try #require(library.makeFunction(name: name)).functionConstantsDictionary.isEmpty
        }
        #expect(Set(plain) == PlanarFrameFinisher.unspecialised)
    }
}
