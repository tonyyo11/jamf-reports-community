import SwiftUI

/// The Fleet Overview's device tiles (mobile spec M6) from the latest summary's maps. Draws
/// nothing for a summary that carries none of them.
struct FleetDeviceMapsSection: View {
    let summary: DailySummary?

    var body: some View {
        let tiles = FleetDeviceMapTile.tiles(summary)
        if !tiles.isEmpty {
            EqualHeightTileGrid(minTileWidth: 220) {
                ForEach(tiles, id: \.title) { tile in
                    Card(padding: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(title: tile.title, style: .headline)
                            ForEach(tile.rows, id: \.label) { row in
                                HStack {
                                    Text(row.label)
                                        .font(.callout)
                                        .foregroundStyle(Theme.Colors.fg2)
                                    Spacer(minLength: 8)
                                    Mono(text: "\(row.count)", color: Theme.Colors.fg)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Text(verbatim: "\(row.label): \(row.count)"))
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
    }
}
