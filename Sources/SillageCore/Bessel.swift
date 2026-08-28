import Foundation

/// Modified Bessel functions, needed for the rotation curve of an exponential disk and for
/// nothing else here.
///
/// Polynomial approximations from Abramowitz and Stegun 9.8.1 to 9.8.8, good to about one
/// part in ten million, which is far past what a rotation curve made of sampled particles
/// can tell apart. The large-argument branches carry their exponential factor separately so
/// the product I(x)K(x) the disk needs never forms exp(x) on its own.
enum Bessel {
    /// exp(-x) I0(x), which stays bounded where I0 itself overflows.
    static func scaledI0(_ x: Double) -> Double {
        if x < 3.75 {
            let t = x / 3.75
            let t2 = t * t
            let series =
                1 + t2
                * (3.5156229 + t2
                    * (3.0899424 + t2
                        * (1.2067492 + t2 * (0.2659732 + t2 * (0.0360768 + t2 * 0.0045813)))))
            return exp(-x) * series
        }
        let t = 3.75 / x
        let series =
            0.39894228 + t
            * (0.01328592 + t
                * (0.00225319 + t
                    * (-0.00157565 + t
                        * (0.00916281 + t
                            * (-0.02057706 + t
                                * (0.02635537 + t * (-0.01647633 + t * 0.00392377)))))))
        return series / x.squareRoot()
    }

    /// exp(-x) I1(x).
    static func scaledI1(_ x: Double) -> Double {
        if x < 3.75 {
            let t = x / 3.75
            let t2 = t * t
            let series =
                0.5 + t2
                * (0.87890594 + t2
                    * (0.51498869 + t2
                        * (0.15084934 + t2
                            * (0.02658733 + t2 * (0.00301532 + t2 * 0.00032411)))))
            return exp(-x) * x * series
        }
        let t = 3.75 / x
        let series =
            0.39894228 + t
            * (-0.03988024 + t
                * (-0.00362018 + t
                    * (0.00163801 + t
                        * (-0.01031555 + t
                            * (0.02282967 + t
                                * (-0.02895312 + t * (0.01787654 + t * (-0.00420059))))))))
        return series / x.squareRoot()
    }

    /// exp(x) K0(x).
    static func scaledK0(_ x: Double) -> Double {
        guard x > 0 else { return .infinity }
        if x <= 2 {
            let t = x / 2
            let t2 = t * t
            let series =
                -0.57721566 + t2
                * (0.42278420 + t2
                    * (0.23069756 + t2
                        * (0.03488590 + t2
                            * (0.00262698 + t2 * (0.00010750 + t2 * 0.0000074)))))
            let i0 = exp(x) * scaledI0(x)
            return exp(x) * (-log(x / 2) * i0 + series)
        }
        let t = 2 / x
        let series =
            1.25331414 + t
            * (-0.07832358 + t
                * (0.02189568 + t
                    * (-0.01062446 + t
                        * (0.00587872 + t * (-0.00251540 + t * 0.00053208)))))
        return series / x.squareRoot()
    }

    /// exp(x) K1(x).
    static func scaledK1(_ x: Double) -> Double {
        guard x > 0 else { return .infinity }
        if x <= 2 {
            let t = x / 2
            let t2 = t * t
            let series =
                1 + t2
                * (0.15443144 + t2
                    * (-0.67278579 + t2
                        * (-0.18156897 + t2
                            * (-0.01919402 + t2 * (-0.00110404 + t2 * (-0.00004686))))))
            let i1 = exp(x) * scaledI1(x)
            return exp(x) * (log(x / 2) * i1 + series / x)
        }
        let t = 2 / x
        let series =
            1.25331414 + t
            * (0.23498619 + t
                * (-0.03655620 + t
                    * (0.01504268 + t
                        * (-0.00780353 + t * (0.00325614 + t * (-0.00068245))))))
        return series / x.squareRoot()
    }
}
