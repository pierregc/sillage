/// Light tracers (#187): a sample drawn at the count that is wanted on screen, of which only a
/// share carries the mass. The rest follow the same orbits in the field of the massive ones,
/// since in a collisionless system a massless particle drawn from the same distribution moves
/// as a massive one does, and they do not shrink the softening or the step.
extension ParticleSystem {
    /// Keeps about `massive` of the visible particles, and the same share of the dark matter,
    /// as the massive set, and makes every other visible particle a massless tracer. Laid out
    /// tracers first, `[tracers | massive visible | massive halo]`, so the tree can be built
    /// over everything after them while the visible ones stay one run.
    ///
    /// The kept particles of each galaxy carry all of its visible mass, and of its dark mass,
    /// between them. Black holes are always kept, with their own mass. Which particles are
    /// kept depends on the seed and the index only.
    public func splittingLightTracers(massive: Int, seed: UInt64) -> (
        system: ParticleSystem, tracers: Int
    ) {
        let visible = visibleCount > 0 ? visibleCount : count
        let share = min(max(Double(massive) / Double(max(visible, 1)), 0), 1)
        let hole = ParticleComponent.hole.rawValue
        let halo = ParticleComponent.halo.rawValue
        var tracers: [Int] = []
        var keptVisible: [Int] = []
        var keptHalo: [Int] = []
        tracers.reserveCapacity(Int(Double(visible) * (1 - share)) + 1024)
        for index in 0..<count {
            let kind = index < component.count ? component[index] : 0
            let kept = kind == hole || Self.unit(index, seed) < share
            if kind == halo {
                if kept { keptHalo.append(index) }
            } else if kept {
                keptVisible.append(index)
            } else {
                tracers.append(index)
            }
        }

        // What each galaxy's kept particles must weigh: all of its visible, or dark, mass.
        let galaxies = Int(galaxyIndex.max() ?? 0) + 1
        var total = [Double](repeating: 0, count: galaxies * 2)
        var held = total
        for index in 0..<count where index < mass.count && component[index] != hole {
            let slot = Int(galaxyIndex[index]) * 2 + (component[index] == halo ? 1 : 0)
            total[slot] += Double(mass[index])
        }
        for index in keptVisible + keptHalo where component[index] != hole {
            let slot = Int(galaxyIndex[index]) * 2 + (component[index] == halo ? 1 : 0)
            held[slot] += Double(mass[index])
        }

        let order = tracers + keptVisible + keptHalo
        var split = ParticleSystem(capacity: order.count)
        for (place, index) in order.enumerated() {
            var weight: Float = 0
            if place >= tracers.count, index < mass.count {
                if component[index] == hole {
                    weight = mass[index]
                } else {
                    let slot = Int(galaxyIndex[index]) * 2 + (component[index] == halo ? 1 : 0)
                    weight = held[slot] > 0 ? Float(Double(mass[index]) * total[slot] / held[slot]) : 0
                }
            }
            split.append(
                position: positions[index], velocity: velocities[index], galaxy: galaxyIndex[index],
                radius: birthRadius[index], population: population[index],
                luminosity: luminosity[index], formation: formation[index],
                component: ParticleComponent(rawValue: component[index]) ?? .star, mass: weight,
                kernelScale: kernelScale[index])
        }
        split.setVisibleCount(tracers.count + keptVisible.count)
        return (split, tracers.count)
    }

    /// The particles `range` of this system, as a system of their own.
    public func slice(_ range: Range<Int>) -> ParticleSystem {
        var part = ParticleSystem(capacity: range.count)
        for index in range {
            part.append(
                position: positions[index], velocity: velocities[index], galaxy: galaxyIndex[index],
                radius: birthRadius[index], population: population[index],
                luminosity: luminosity[index], formation: formation[index],
                component: ParticleComponent(rawValue: component[index]) ?? .star,
                mass: index < mass.count ? mass[index] : 0, kernelScale: kernelScale[index])
        }
        part.setVisibleCount(min(max(visibleCount - range.lowerBound, 0), range.count))
        return part
    }

    /// A uniform number in [0, 1) from an index and a seed.
    static func unit(_ index: Int, _ seed: UInt64) -> Double {
        var z = seed &+ UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) * 0x1p-53
    }
}
