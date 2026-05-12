// ABOUTME: Confirms the JWT region claim drives initial host selection.
// ABOUTME: Uses the redacted JWT fixture; matches whatever claim name §0.5 captured.

import Testing
import Foundation
@testable import TapedeckCore

@Suite("SourceClient region decode")
struct SourceClientRegionTests {
    @Test func decodesEuCentral1FromRedactedJwtClaim() throws {
        let header = #"{"alg":"none"}"#.data(using: .utf8)!.base64URLEncoded()
        let payloadURL = Bundle.module.url(forResource: "Fixtures/source/jwt_payload_redacted",
                                            withExtension: "json")!
        let payload = try Data(contentsOf: payloadURL).base64URLEncoded()
        let token = "\(header).\(payload).sig"

        let host = SourceClient.hostFromJWT(token)
        #expect(host == URL(string: "https://api-euc1.plaud.ai")!)
    }

    @Test func returnsNilIfJwtLacksRegionClaim() throws {
        let header = #"{"alg":"none"}"#.data(using: .utf8)!.base64URLEncoded()
        let payload = #"{"sub":"x"}"#.data(using: .utf8)!.base64URLEncoded()
        let token = "\(header).\(payload).sig"
        #expect(SourceClient.hostFromJWT(token) == nil)
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
