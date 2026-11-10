import Foundation
import Testing

@testable import SillageCore

@Suite("Portable SHA-256")
struct PortableSHA256Tests {
    private func hex(_ text: String) -> String {
        var hash = PortableSHA256()
        hash.update(data: Data(text.utf8))
        return hash.hex()
    }

    @Test func theStandardVectorsComeOut() {
        #expect(hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(
            hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    @Test func aMillionAsComeOutWhateverThePiecesTheyArriveIn() {
        let expected = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        for piece in [1, 7, 63, 64, 65, 4_096, 1_000_000] {
            var hash = PortableSHA256()
            var left = 1_000_000
            while left > 0 {
                let count = min(piece, left)
                hash.update(data: Data(repeating: 0x61, count: count))
                left -= count
            }
            #expect(hash.hex() == expected)
        }
    }

    @Test func integersGoInLittleEndian() {
        var whole = PortableSHA256()
        whole.update(littleEndian: UInt32(0x0403_0201))
        whole.update(littleEndian: UInt64(0x0807_0605_0403_0201))
        var bytes = PortableSHA256()
        bytes.update(data: Data([1, 2, 3, 4, 1, 2, 3, 4, 5, 6, 7, 8]))
        #expect(whole.hex() == bytes.hex())
    }
}
