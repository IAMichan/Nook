import XCTest
import CoreGraphics

/// The weather without a key, images for brains that can see, and model lists without
/// models that cannot chat.
final class ExtrasTests: XCTestCase {
    // MARK: Weather

    func testDefaultPlaceIsTheCityOfTheTimeZone() {
        XCTAssertEqual(Weather.defaultPlace(timeZone: TimeZone(identifier: "Europe/Amsterdam")!), "Amsterdam")
        XCTAssertEqual(Weather.defaultPlace(timeZone: TimeZone(identifier: "America/New_York")!), "New York")
    }

    func testParsesThePlace() {
        let json = #"{"results":[{"name":"Utrecht","latitude":52.09,"longitude":5.12,"admin1":"Utrecht","country":"Nederland"}]}"#
        let place = Weather.parsePlace(Data(json.utf8))
        XCTAssertEqual(place?.name, "Utrecht, Nederland")
        XCTAssertEqual(place?.latitude ?? 0, 52.09, accuracy: 0.001)
        XCTAssertNil(Weather.parsePlace(Data(#"{"generationtime_ms":0.5}"#.utf8)))
    }

    func testParsesAndWritesTheForecast() throws {
        let json = """
        {"current":{"temperature_2m":12.4,"apparent_temperature":9.6,"weather_code":3,"wind_speed_10m":18.2},
         "daily":{"time":["2026-10-18","2026-10-19"],"weather_code":[61,0],"temperature_2m_max":[14.1,16.8],
                  "temperature_2m_min":[8.2,7.5],"precipitation_probability_max":[80,5],"precipitation_sum":[4.3,0],
                  "wind_speed_10m_max":[30.0,12.0]}}
        """
        let forecast = try XCTUnwrap(Weather.parseForecast(Data(json.utf8), place: "Utrecht"))
        XCTAssertEqual(forecast.days.count, 2)
        XCTAssertEqual(forecast.days[0].rainChance, 80)
        let text = Weather.text(forecast, today: "2026-10-18")
        XCTAssertTrue(text.contains("Now: 12 °C, overcast, feels like 10 °C"), text)
        XCTAssertTrue(text.contains("Today: light rain, 8 °C to 14 °C, 80% chance of rain (4.3 mm)"), text)
        XCTAssertTrue(text.contains("2026-10-19: clear sky, 8 °C to 17 °C, 5% chance of rain, wind up to 12 km/h."), text)
    }

    func testWeatherCodes() {
        XCTAssertEqual(Weather.describe(0), "clear sky")
        XCTAssertEqual(Weather.describe(95), "thunderstorm")
        XCTAssertEqual(Weather.describe(1234), "unknown")
    }

    // MARK: Images

    private func picture(alpha: Bool) -> CGImage {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context.makeImage()!
    }

    func testPhotosBecomeJPEGAndTransparencyStaysPNG() throws {
        let photo = try XCTUnwrap(ChatImage.encode(picture(alpha: false)))
        XCTAssertEqual(photo.mediaType, "image/jpeg")
        XCTAssertEqual(Array(photo.data.prefix(2)), [0xFF, 0xD8])
        let icon = try XCTUnwrap(ChatImage.encode(picture(alpha: true)))
        XCTAssertEqual(icon.mediaType, "image/png")
        XCTAssertTrue(icon.dataURL.hasPrefix("data:image/png;base64,"))
    }

    func testImageMessageFormats() throws {
        let image = ChatImage(data: Data([1, 2, 3]), mediaType: "image/png")
        let claude = ChatImage.anthropicContent([image], text: "Wat staat hier?")
        XCTAssertEqual(claude.first?["type"] as? String, "image")
        XCTAssertEqual((claude.first?["source"] as? [String: Any])?["data"] as? String, "AQID")
        XCTAssertEqual(claude.last?["text"] as? String, "Wat staat hier?")
        let openAI = ChatImage.openAIContent([image], text: "Wat staat hier?")
        XCTAssertEqual(openAI.first?["type"] as? String, "text")
        XCTAssertEqual((openAI.last?["image_url"] as? [String: Any])?["url"] as? String, "data:image/png;base64,AQID")
    }

    func testImageFilesAreRecognized() {
        XCTAssertTrue(ChatImage.isImage(URL(fileURLWithPath: "/tmp/scherm.png")))
        XCTAssertTrue(ChatImage.isImage(URL(fileURLWithPath: "/tmp/foto.HEIC")))
        XCTAssertFalse(ChatImage.isImage(URL(fileURLWithPath: "/tmp/notitie.pdf")))
        XCTAssertTrue(ChatImage.describe(name: "a.png", recognized: "  ").contains("No readable text"))
        XCTAssertTrue(ChatImage.describe(name: "a.png", recognized: "Factuur 2026").contains("Factuur 2026"))
    }

    // MARK: Model lists

    func testModelListsKeepOnlyChatModels() {
        for id in ["nomic-embed-text:latest", "text-embedding-3-small", "bge-m3", "whisper-1", "tts-1", "dall-e-3", "gpt-image-1",
                   "omni-moderation-latest", "gpt-4o-realtime-preview"] {
            XCTAssertFalse(AIProvider.isChatModel(id), id)
        }
        for id in ["qwen3:8b", "gemma3:12b", "llama3.2-vision", "gpt-5", "claude-sonnet-5-5", "mistral-large-latest"] {
            XCTAssertTrue(AIProvider.isChatModel(id), id)
        }
    }
}
