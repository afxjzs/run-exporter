import Foundation

/// Writes a standard GPX 1.1 track for one workout route.
///
/// Output is plain UTF-8 GPX 1.1 with no extensions, so it opens in Garmin Connect, Strava,
/// Gaia GPS, QGIS, gpxpy, and the rest. Points are emitted in the order given, which the caller
/// has already sorted chronologically.
enum GPXWriter {

    /// Builds the GPX document.
    ///
    /// - Parameters:
    ///   - points: chronologically ordered route points.
    ///   - trackName: `<trk><name>`, e.g. "Running 2026-07-21".
    ///   - trackType: `<trk><type>`, e.g. "running".
    ///   - creationDate: `<metadata><time>`; defaults to the first point's timestamp.
    static func document(points: [RoutePoint],
                         trackName: String,
                         trackType: String,
                         creationDate: Date? = nil) -> String {

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1"
             creator="Running Health Export"
             xmlns="http://www.topografix.com/GPX/1/1">
          <metadata>
            <time>\(Fmt.isoUTCString(creationDate ?? points.first?.timestamp))</time>
          </metadata>
          <trk>
            <name>\(escape(trackName))</name>
            <type>\(escape(trackType))</type>
            <trkseg>

        """

        for point in points {
            // Latitude/longitude use full precision — the display formatter would move the
            // point by metres.
            xml += "      <trkpt lat=\"\(Fmt.coord(point.latitude))\" lon=\"\(Fmt.coord(point.longitude))\">\n"
            // Only altitudes Core Location marked valid are emitted; an invalid <ele> would read
            // as a real elevation to any consumer.
            if let altitude = point.altitudeMeters {
                xml += "        <ele>\(Fmt.fixed(altitude, places: 2))</ele>\n"
            }
            xml += "        <time>\(Fmt.isoUTCString(point.timestamp))</time>\n"
            xml += "      </trkpt>\n"
        }

        xml += """
            </trkseg>
          </trk>
        </gpx>

        """
        return xml
    }

    static func data(points: [RoutePoint],
                     trackName: String,
                     trackType: String,
                     creationDate: Date? = nil) -> Data {
        Data(document(points: points,
                      trackName: trackName,
                      trackType: trackType,
                      creationDate: creationDate).utf8)
    }

    /// Escapes the five XML predefined entities so a source or device name can never break the
    /// document.
    static func escape(_ value: String) -> String {
        var out = value.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        return out
    }
}
