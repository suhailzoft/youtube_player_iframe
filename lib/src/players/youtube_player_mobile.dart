// Copyright 2020 Sarbagya Dhaubanjar. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:developer';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import '../controller.dart';
import '../enums/player_state.dart';
import '../enums/youtube_error.dart';
import '../helpers/player_fragments.dart';
import '../meta_data.dart';
import '../player_value.dart';

/// A youtube player widget which interacts with the underlying webview inorder to play YouTube videos.
///
/// Use [YoutubePlayerIFrame] instead.
class RawYoutubePlayer extends StatefulWidget {
  /// The [YoutubePlayerController].
  final YoutubePlayerController controller;
  final bool inert;

  /// Which gestures should be consumed by the youtube player.
  ///
  /// It is possible for other gesture recognizers to be competing with the player on pointer
  /// events, e.g if the player is inside a [ListView] the [ListView] will want to handle
  /// vertical drags. The player will claim gestures that are recognized by any of the
  /// recognizers on this list.
  ///
  /// By default vertical and horizontal gestures are absorbed by the player.
  /// Passing an empty set will ignore the defaults.
  final Set<Factory<OneSequenceGestureRecognizer>>? gestureRecognizers;

  /// Creates a [RawYoutubePlayer] widget.
  const RawYoutubePlayer({
    Key? key,
    required this.controller,
    this.gestureRecognizers,
    required this.inert,
  }) : super(key: key);

  @override
  _MobileYoutubePlayerState createState() => _MobileYoutubePlayerState();
}

class _MobileYoutubePlayerState extends State<RawYoutubePlayer>
    with WidgetsBindingObserver {
  late final YoutubePlayerController controller;
  late InAppWebViewController _webController;
  late final Completer<InAppWebViewController> _webControllerCompleter;
  PlayerState? _cachedPlayerState;
  bool _isPlayerReady = false;
  bool _onLoadStopCalled = false;
  late YoutubePlayerValue _value;

  @override
  void initState() {
    super.initState();
    _webControllerCompleter = Completer();
    controller = widget.controller;
    _value = controller.value;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_cachedPlayerState != null &&
            _cachedPlayerState == PlayerState.playing) {
          controller.play();
        }
        break;
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.paused:
        _cachedPlayerState = controller.value.playerState;
        controller.pause();
        break;
      default:
    }
  }

  @override
  Widget build(BuildContext context) {
    return InAppWebView(
      key: ValueKey(controller.hashCode),
      initialData: InAppWebViewInitialData(
        data: player,
        baseUrl: WebUri.uri(_baseUrl),
        encoding: 'utf-8',
        mimeType: 'text/html',
      ),
      gestureRecognizers: _gestureRecognizers,
      initialSettings: InAppWebViewSettings(
        allowsInlineMediaPlayback: true,
        mediaPlaybackRequiresUserGesture: false,
        transparentBackground: true,
        disableContextMenu: true,
        supportZoom: false,
        useShouldOverrideUrlLoading: true,
        useWideViewPort: false,
        useHybridComposition: controller.params.useHybridComposition,
        displayZoomControls: true,
        isElementFullscreenEnabled: true,
      ),
      shouldOverrideUrlLoading: _decideNavigationActionPolicy,
      onWebViewCreated: (webController) {
        _webController = webController;
        if (!_webControllerCompleter.isCompleted) {
          _webControllerCompleter.complete(webController);
        }
        controller.invokeJavascript = _callMethod;
        _addHandlers(webController);
      },
      onLoadStop: (_, __) {
        _onLoadStopCalled = true;
        if (_isPlayerReady) {
          _value = _value.copyWith(isReady: true);
          controller.add(_value);
        }
      },
      onConsoleMessage: (_, message) => log(message.message),
      onEnterFullscreen: (_) {
        _webController?.evaluateJavascript(
          source: 'document.getElementById("player").style = "position:absolute; top:0px; left:0px; bottom:0px; right:0px;  border:none; margin:0; padding:0; overflow:hidden; z-index:999999;"',
        );
        controller.onEnterFullscreen?.call();
      },
      onExitFullscreen: (_) {
        _webController?.evaluateJavascript(
          source: 'document.getElementById("player").style = "position:absolute; top:0px; left:0px; bottom:0px; right:10px;width:100%; height:100%; border:none; margin:0; padding:0; overflow:hidden; z-index:999999;"',
        );
        controller.onExitFullscreen?.call();
        },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Uri get _baseUrl {
    return Uri.parse(
      controller.params.privacyEnhanced
          ? 'https://www.youtube-nocookie.com'
          : 'https://www.youtube.com',
    );
  }

  Set<Factory<OneSequenceGestureRecognizer>> get _gestureRecognizers {
    return widget.gestureRecognizers ??
        const {
          Factory<VerticalDragGestureRecognizer>(
            VerticalDragGestureRecognizer.new,
          ),
          Factory<HorizontalDragGestureRecognizer>(
            HorizontalDragGestureRecognizer.new,
          ),
        };
  }

  Future<void> _callMethod(String methodName) async {
    final webController = await _webControllerCompleter.future;
    webController.evaluateJavascript(source: methodName);
  }

  void _addHandlers(InAppWebViewController webController) {
    webController..addJavaScriptHandler(
      handlerName: 'Ready',
      callback: (_) {
        _isPlayerReady = true;
        if (_onLoadStopCalled) {
          _value = _value.copyWith(isReady: true);
          controller.add(_value);
        }
      },
    )..addJavaScriptHandler(
      handlerName: 'StateChange',
      callback: (args) {
        switch (args.first as int) {
          case -1:
            _value = _value.copyWith(
              playerState: PlayerState.unStarted,
              isReady: true,
            );
            break;
          case 0:
            _value = _value.copyWith(playerState: PlayerState.ended);
            break;
          case 1:
            _value = _value.copyWith(
              playerState: PlayerState.playing,
              hasPlayed: true,
              error: YoutubeError.none,
            );
            break;
          case 2:
            _value = _value.copyWith(playerState: PlayerState.paused);
            break;
          case 3:
            _value = _value.copyWith(playerState: PlayerState.buffering);
            break;
          case 5:
            _value = _value.copyWith(playerState: PlayerState.cued);
            break;
          default:
            throw Exception("Invalid player state obtained.");
        }
        controller.add(_value);
      },
    )..addJavaScriptHandler(
      handlerName: 'PlaybackQualityChange',
      callback: (args) {
        _value = _value.copyWith(playbackQuality: args.first as String);
        controller.add(_value);
      },
    )..addJavaScriptHandler(
      handlerName: 'PlaybackRateChange',
      callback: (args) {
        final num rate = args.first;
        _value = _value.copyWith(playbackRate: rate.toDouble());
        controller.add(_value);
      },
    )..addJavaScriptHandler(
      handlerName: 'Errors',
      callback: (args) {
        _value = _value.copyWith(error: errorEnum(args.first as int));
        controller.add(_value);
      },
    )..addJavaScriptHandler(
      handlerName: 'VideoData',
      callback: (args) {
        _value = _value.copyWith(
          metaData: YoutubeMetaData.fromRawData(args.first),
        );
        controller.add(_value);
      },
    )..addJavaScriptHandler(
      handlerName: 'VideoTime',
      callback: (args) {
        final position = args.first * 1000;
        final num buffered = args.last;
        _value = _value.copyWith(
          position: Duration(milliseconds: position.floor()),
          buffered: buffered.toDouble(),
        );
        controller.add(_value);
      },
    );
  }

  Future<NavigationActionPolicy?> _decideNavigationActionPolicy(_,
      NavigationAction action,) async {
    final uri = action.request.url;
    if (uri == null) return NavigationActionPolicy.CANCEL;

    final params = uri.queryParameters;
    final host = uri.host;

    String? featureName;
    if (host.contains('facebook') || uri.host.contains('twitter')) {
      featureName = 'social';
    } else if (params.containsKey('feature')) {
      featureName = params['feature'];
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      return NavigationActionPolicy.ALLOW;
    }

    switch (featureName) {
      case 'emb_title':
      case 'emb_rel_pause':
      case 'emb_rel_end':
        final videoId = params['v'];
        if (videoId != null) controller.load(videoId);
        break;
      case 'emb_logo':
      case 'social':
      case 'wl_button':
        url_launcher.launchUrl(uri);
        break;
    }

    return NavigationActionPolicy.CANCEL;
  }

  String get player => '''
    <!DOCTYPE html>
    <body>
         ${youtubeIFrameTag(controller)}
        <script>
            $initPlayerIFrame
            var player;
            var timerId;
            function onYouTubeIframeAPIReady() {
                player = new YT.Player('player', {
                    events: {
                        onReady: function(event) { window.flutter_inappwebview.callHandler('Ready'); },
                        onStateChange: function(event) { sendPlayerStateChange(event.data); },
                        onPlaybackQualityChange: function(event) { window.flutter_inappwebview.callHandler('PlaybackQualityChange', event.data); },
                        onPlaybackRateChange: function(event) { window.flutter_inappwebview.callHandler('PlaybackRateChange', event.data); },
                        onError: function(error) { window.flutter_inappwebview.callHandler('Errors', error.data); }
                    },
                });
            }

            function sendPlayerStateChange(playerState) {
                clearTimeout(timerId);
                window.flutter_inappwebview.callHandler('StateChange', playerState);
                if (playerState == 1) {
                    startSendCurrentTimeInterval();
                    sendVideoData(player);
                }
            }

            function sendVideoData(player) {
                var videoData = {
                    'duration': player.getDuration(),
                    'title': player.getVideoData().title,
                    'author': player.getVideoData().author,
                    'videoId': player.getVideoData().video_id
                };
                window.flutter_inappwebview.callHandler('VideoData', videoData);
            }

            function startSendCurrentTimeInterval() {
                timerId = setInterval(function () {
                    window.flutter_inappwebview.callHandler('VideoTime', player.getCurrentTime(), player.getVideoLoadedFraction());
                }, 100);
            }

            $youtubeIFrameFunctions
        </script>
    </body>
  ''';

  String get userAgent =>
      controller.params.desktopMode
          ? 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/77.0.3865.90 Safari/537.36'
          : '';
}
