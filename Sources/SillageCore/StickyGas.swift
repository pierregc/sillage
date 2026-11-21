import Foundation

/// Gas that loses its motion against the gas around it (#401, docs/notes/gas-that-dissipates.md).
///
/// Each unformed gas particle meets the other gas of the smallest tree cell around it that holds
/// `cellGas` gas particles, and loses the speed it closes on that gas with beyond `soundSpeed`. Absent from a scene, nothing runs and the scene replays as it always did.
public struct StickyGas: Codable, Sendable, Equatable {
    /// Random motion the gas keeps, in km/s: its stand-in for pressure.
    public var soundSpeed: Float = 10
    /// E-foldings a megayear of the closing speed above the sound speed. Gentle on purpose: at
    /// four times this the gas knots, at a quarter of it nothing gathers (docs/notes/sticky-gas.md).
    public var rate: Float = 0.25
    /// E-foldings each time the particle crosses its cell at its closing speed,
    /// added to `rate`: a mean free path of one cell over this.
    public var crossing: Float = 0
    /// Gas particles a cell must hold to be a neighbourhood.
    public var cellGas: Int = 16
    /// Widest cell that counts, in kpc: past it the gas is too sparse to be met.
    public var reach: Float = 2
    /// The length dense gas is held up over, in kpc: its sound speed is never under this times
    /// the square root of G and its cell's gas density, so nothing smaller collapses under its
    /// own weight. Zero for none.
    public var jeans: Float = 2

    public init() {}

    /// `on`, or `<km/s>[:<rate>[:<crossing>[:<cell gas>[:<reach kpc>[:<jeans>]]]]]`, an empty field
    /// keeping its default.
    public init?(parsing text: String) {
        self.init()
        if text == "on" { return }
        let fields = text.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count <= 6 else { return nil }
        for (index, field) in fields.enumerated() where !field.isEmpty {
            guard let value = Float(field), value >= 0, value.isFinite else { return nil }
            switch index {
            case 0: soundSpeed = value
            case 1: rate = value
            case 2: crossing = value
            case 3: cellGas = max(Int(value), 2)
            case 4: reach = value
            default: jeans = value
            }
        }
    }

    public var description: String {
        String(format: "%g:%g:%g:%d:%g:%g", soundSpeed, rate, crossing, cellGas, reach, jeans)
    }
}
