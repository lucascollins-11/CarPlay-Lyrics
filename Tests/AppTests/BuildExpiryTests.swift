import XCTest
@testable import CarPlayLyrics

final class BuildExpiryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 24 * 3600

    /// A provisioning profile shaped like the real thing: binary CMS bytes around an XML plist.
    func profile(expiring date: Date) -> Data {
        let formatter = ISO8601DateFormatter()
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>AppIDName</key><string>CarPlay Lyrics</string>
            <key>CreationDate</key><date>\(formatter.string(from: date.addingTimeInterval(-7 * day)))</date>
            <key>ExpirationDate</key><date>\(formatter.string(from: date))</date>
            <key>TimeToLive</key><integer>7</integer>
        </dict>
        </plist>
        """
        var data = Data([0x30, 0x80, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02, 0xa0, 0x80, 0x00, 0xff])
        data.append(Data(plist.utf8))
        data.append(Data([0x00, 0x00, 0xa0, 0x82, 0x0b, 0x3c, 0x30, 0x82, 0x04, 0x22, 0x30, 0x82, 0x03, 0x0a]))
        return data
    }

    func testReadsExpirationDateFromProfile() throws {
        let expires = now.addingTimeInterval(7 * day)
        let date = try XCTUnwrap(BuildExpiry.expirationDate(fromProfile: profile(expiring: expires)))
        XCTAssertEqual(date.timeIntervalSince1970, expires.timeIntervalSince1970, accuracy: 1)
    }

    func testUnreadableProfilesGiveNoDate() {
        XCTAssertNil(BuildExpiry.expirationDate(fromProfile: Data()))
        XCTAssertNil(BuildExpiry.expirationDate(fromProfile: Data([0x30, 0x80, 0x00])))
        XCTAssertNil(BuildExpiry.expirationDate(fromProfile: Data("<?xml version=\"1.0\"?><plist><dict>".utf8)))
        let noDate = Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Name</key><string>x</string></dict></plist>".utf8)
        XCTAssertNil(BuildExpiry.expirationDate(fromProfile: noDate))
    }

    func testStatus() {
        XCTAssertEqual(BuildExpiry.status(expiration: nil, now: now), .unknown)
        let inAWeek = now.addingTimeInterval(7 * day)
        XCTAssertEqual(BuildExpiry.status(expiration: inAWeek, now: now), .valid(expires: inAWeek))
        let inTwoDays = now.addingTimeInterval(2 * day)
        XCTAssertEqual(BuildExpiry.status(expiration: inTwoDays, now: now), .expiringSoon(expires: inTwoDays, daysLeft: 2))
        let inAnHour = now.addingTimeInterval(3600)
        XCTAssertEqual(BuildExpiry.status(expiration: inAnHour, now: now), .expiringSoon(expires: inAnHour, daysLeft: 1))
        XCTAssertEqual(BuildExpiry.status(expiration: now, now: now), .expired(on: now))
        let yesterday = now.addingTimeInterval(-day)
        XCTAssertEqual(BuildExpiry.status(expiration: yesterday, now: now), .expired(on: yesterday))
    }

    func testTestBundleHasNoProfile() {
        // Simulator builds carry no embedded.mobileprovision.
        XCTAssertEqual(BuildExpiry.current(bundle: Bundle(for: Self.self), now: now), .unknown)
    }
}
