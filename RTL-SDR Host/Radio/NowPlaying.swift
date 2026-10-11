//
//  NowPlaying.swift
//  RTL-SDR Host
//
//  Shows the radio on the Lock Screen and in Control Center, and handles
//  their buttons: play / pause, and next / previous favorite.
//

import MediaPlayer
import UIKit

final class NowPlaying {

    struct Commands {
        var play: () -> Void
        var pause: () -> Void
        var next: () -> Void
        var previous: () -> Void
    }

    private lazy var artwork = NowPlaying.makeArtworkItem()

    func setUp(_ commands: Commands) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in commands.play(); return .success }
        center.pauseCommand.addTarget { _ in commands.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { _ in
            let playing = (MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0) > 0
            playing ? commands.pause() : commands.play()
            return .success
        }
        center.nextTrackCommand.addTarget { _ in commands.next(); return .success }
        center.previousTrackCommand.addTarget { _ in commands.previous(); return .success }

        // A live stream: nothing to seek, skip or rate.
        for command in [center.changePlaybackPositionCommand, center.skipForwardCommand,
                        center.skipBackwardCommand, center.seekForwardCommand,
                        center.seekBackwardCommand, center.changePlaybackRateCommand] {
            command.isEnabled = false
        }
    }

    /// Title and subtitle, e.g. the station name and its radio text. Next /
    /// previous are offered only with favorites to switch between.
    func update(title: String, subtitle: String, playing: Bool, hasFavorites: Bool) {
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = hasFavorites
        center.previousTrackCommand.isEnabled = hasFavorites

        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: subtitle,
            MPMediaItemPropertyArtwork: artwork,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
    }

    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// MediaPlayer asks for the image on a background thread, so neither
    /// this closure nor the drawing may be tied to the main actor.
    nonisolated private static func makeArtworkItem() -> MPMediaItemArtwork {
        let image = makeArtwork()
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// A radio symbol on the accent colour.
    nonisolated private static func makeArtwork() -> UIImage {
        let size = CGSize(width: 600, height: 600)
        let background = UIColor(named: "AccentColor") ?? .systemBlue
        let symbol = UIImage(systemName: "radio",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 260, weight: .medium))?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        return UIGraphicsImageRenderer(size: size).image { _ in
            background.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            if let symbol {
                let origin = CGPoint(x: (size.width - symbol.size.width) / 2,
                                     y: (size.height - symbol.size.height) / 2)
                symbol.draw(at: origin)
            }
        }
    }
}
