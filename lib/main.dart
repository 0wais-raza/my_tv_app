// =============================================================================
// IPTV PLAYER — single-file Flutter app for budget Android TV boxes
// (built/tested against devices like the "Wisdom Share Smart Cloud TV" box)
// =============================================================================
//
// REQUIRED SETUP (outside this file — cannot be avoided, Dart needs these):
//
// 1) pubspec.yaml — third-party packages used:
//      dependencies:
//        flutter:
//          sdk: flutter
//        video_player: ^2.9.2
//        http: ^1.2.0
//        shared_preferences: ^2.2.2
//
// 2) android/app/src/main/AndroidManifest.xml — add the INTERNET permission
//    (every stream/playlist request silently fails without this):
//      <uses-permission android:name="android.permission.INTERNET"/>
//
//    For Android TV, also declare TV support/banner (optional but recommended):
//      <uses-feature android:name="android.software.leanback" android:required="false"/>
//      <uses-feature android:name="android.hardware.touchscreen" android:required="false"/>
//
// -----------------------------------------------------------------------------
// HARDWARE KEY HANDLING — quick summary (details are inline near each handler)
// -----------------------------------------------------------------------------
// - D-Pad UP/DOWN/LEFT/RIGHT (browsing screens & full-screen player idle nav):
//   Intentionally NOT intercepted. Every focusable tile is wrapped in a
//   `Focus` widget; Flutter's `WidgetsApp` already binds arrow keys to
//   `DirectionalFocusIntent` -> `DirectionalFocusAction`, which moves focus
//   to the nearest on-screen focusable widget in the pressed direction using
//   real widget geometry. This is the standard, built-in way Flutter apps
//   support D-Pad/gamepad/keyboard navigation — no manual grid-tracking code
//   needed, and it stays correct automatically as layouts change.
// - D-Pad CENTER / ENTER: handled explicitly per-widget (`LogicalKeyboardKey
//   .select` / `.enter` / `.numpadEnter` / `.gameButtonA`) to activate
//   ("tune in") a focused tile, or to toggle the player's control overlay.
// - KEYCODE_CHANNEL_UP / KEYCODE_CHANNEL_DOWN (Android keycodes 166/167):
//   Flutter's engine maps these to `LogicalKeyboardKey.channelUp` /
//   `.channelDown`. Handled only inside the full-screen player to zap to the
//   next/previous channel instantly.
// - BACK: handled on two redundant paths for maximum device compatibility —
//   (a) `PopScope`, which intercepts Android's system back navigation
//       regardless of whether the OS ever surfaces it as a raw key event,
//       and (b) a fallback check for `LogicalKeyboardKey.goBack` / `.escape`
//       inside the player's own key handler, for boxes that deliver BACK as
//       a plain key event instead.
// =============================================================================

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // TV playback is always landscape; locking orientation avoids an
  // unnecessary relayout pass on devices that report a rotation sensor.
  SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const IptvApp());
}

// -----------------------------------------------------------------------------
// GLOBAL CONSTANTS
// -----------------------------------------------------------------------------

/// Spoofed desktop-Chrome User-Agent. Many IPTV origin servers reject the
/// default Dart/okhttp user agent with HTTP 400/403 — presenting as a real
/// browser is the single most effective fix for that class of failure.
const String kSpoofedUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/// Headers injected into every HLS/HTTP video request.
const Map<String, String> kStreamHeaders = <String, String>{
  'User-Agent': kSpoofedUserAgent,
  'Referer': 'https://www.google.com/',
};

/// Default Pakistani channels playlist URL
const String kDefaultPlaylistUrl =
    'https://iptv-org.github.io/iptv/countries/pk.m3u';

const Duration kStreamInitTimeout = Duration(seconds: 8);
const Duration kBannerDuration = Duration(seconds: 3);
const Duration kControlsAutoHide = Duration(seconds: 5);

// -----------------------------------------------------------------------------
// MODEL
// -----------------------------------------------------------------------------

@immutable
class Channel {
  final String name;
  final String group;
  final String url;
  final String logoUrl;

  const Channel({
    required this.name,
    required this.group,
    required this.url,
    this.logoUrl = '',
  });
}

// -----------------------------------------------------------------------------
// M3U PARSER — lightweight, single-pass, zero external dependencies
// -----------------------------------------------------------------------------

class M3uParser {
  M3uParser._();

  /// Parses raw M3U/M3U8 text into a flat list of [Channel]s.
  /// Only reads `#EXTINF` metadata + the following URL line; every other
  /// directive (`#EXTM3U`, `#EXTGRP`, `#EXTVLCOPT`, comments, ...) is
  /// skipped. This keeps parsing O(n) over the raw text with no regex work
  /// outside of attribute extraction on `#EXTINF` lines themselves.
  static List<Channel> parse(String raw) {
    final List<Channel> result = <Channel>[];
    if (raw.trim().isEmpty) return result;

    final List<String> lines = const LineSplitter().convert(raw);

    String pendingName = '';
    String pendingGroup = 'Uncategorized';
    String pendingLogo = '';
    bool hasPending = false;

    for (final String rawLine in lines) {
      final String line = rawLine.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#EXTINF')) {
        final int commaIndex = line.indexOf(',');
        final String attrPart =
            commaIndex >= 0 ? line.substring(0, commaIndex) : line;
        pendingName = (commaIndex >= 0 && commaIndex + 1 < line.length)
            ? line.substring(commaIndex + 1).trim()
            : 'Unnamed Channel';
        pendingGroup =
            _extractAttribute(attrPart, 'group-title') ?? 'Uncategorized';
        pendingLogo = _extractAttribute(attrPart, 'tvg-logo') ?? '';
        hasPending = true;
      } else if (line.startsWith('#')) {
        continue; // ignore other directives
      } else {
        // Non-comment, non-empty line following an #EXTINF is the stream URL.
        if (hasPending) {
          result.add(Channel(
            name: pendingName.isEmpty ? 'Unnamed Channel' : pendingName,
            group: pendingGroup.isEmpty ? 'Uncategorized' : pendingGroup,
            url: line,
            logoUrl: pendingLogo,
          ));
          hasPending = false;
          pendingName = '';
          pendingGroup = 'Uncategorized';
          pendingLogo = '';
        }
      }
    }
    return result;
  }

  static String? _extractAttribute(String source, String key) {
    final String needle = '$key="';
    final int start = source.indexOf(needle);
    if (start == -1) return null;
    final int valueStart = start + needle.length;
    final int valueEnd = source.indexOf('"', valueStart);
    if (valueEnd == -1) return null;
    return source.substring(valueStart, valueEnd);
  }
}

// -----------------------------------------------------------------------------
// NETWORK — fetch the playlist (Cross-Platform HTTP client for Web & Android)
// -----------------------------------------------------------------------------

class PlaylistFetcher {
  PlaylistFetcher._();

  static Future<String> fetch(String url) async {
    final Uri? uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) {
      throw const FormatException('That does not look like a valid URL.');
    }

    try {
      final http.Response response = await http
          .get(uri, headers: kStreamHeaders)
          .timeout(kStreamInitTimeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
            'Playlist server returned HTTP ${response.statusCode}.');
      }

      return response.body;
    } catch (e) {
      if (e is FormatException) rethrow;
      throw Exception('Failed to load playlist: ${e.toString()}');
    }
  }
}

// -----------------------------------------------------------------------------
// APP ROOT
// -----------------------------------------------------------------------------

class IptvApp extends StatelessWidget {
  const IptvApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IPTV Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0A0F),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00C2A8),
          brightness: Brightness.dark,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

// -----------------------------------------------------------------------------
// REUSABLE D-PAD FOCUSABLE WRAPPER
// -----------------------------------------------------------------------------

/// Wraps any widget with TV-remote focus handling: visual focus state via
/// [builder], SELECT/ENTER activation via [onSelect], and auto-scroll into
/// view when placed inside a scrollable list. Arrow keys are deliberately
/// left unhandled here — see the file header comment for why.
class TvFocusable extends StatefulWidget {
  final Widget Function(BuildContext context, bool hasFocus) builder;
  final VoidCallback onSelect;
  final bool autofocus;

  const TvFocusable({
    super.key,
    required this.builder,
    required this.onSelect,
    this.autofocus = false,
  });

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _hasFocus = false;

  void _onFocusChange(bool focused) {
    setState(() => _hasFocus = focused);
    if (focused) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Scrollable.ensureVisible(
            context,
            alignment: 0.5,
            duration: const Duration(milliseconds: 150),
          );
        }
      });
    }
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA) {
      widget.onSelect();
      return KeyEventResult.handled;
    }
    // Returning `ignored` lets arrow keys bubble up to Flutter's built-in
    // directional focus traversal (see file header comment).
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: _onFocusChange,
      onKeyEvent: _handleKey,
      child: widget.builder(context, _hasFocus),
    );
  }
}

// -----------------------------------------------------------------------------
// HOME SCREEN — playlist load, category filter, channel browser, settings
// -----------------------------------------------------------------------------

enum LoadState { idle, loading, loaded, error }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _urlController =
      TextEditingController(text: kDefaultPlaylistUrl);

  LoadState _loadState = LoadState.idle;
  String _errorMessage = '';

  List<Channel> _allChannels = const <Channel>[];
  List<String> _categories = const <String>[];
  String _selectedCategory = 'All';
  final Set<String> _favoriteUrls = <String>{}; // in-memory favorites store

  @override
  void initState() {
    super.initState();
    _checkFirstRunAndLoad();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  /// Checks local SharedPreferences. If empty, saves default Pakistan URL and auto-loads.
  Future<void> _checkFirstRunAndLoad() async {
    setState(() {
      _loadState = LoadState.loading;
    });
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      String? savedUrl = prefs.getString('saved_m3u_url');
      if (savedUrl == null || savedUrl.trim().isEmpty) {
        savedUrl = kDefaultPlaylistUrl;
        await prefs.setString('saved_m3u_url', kDefaultPlaylistUrl);
      }
      _urlController.text = savedUrl;
      await _loadPlaylist(targetUrl: savedUrl);
    } catch (e) {
      setState(() {
        _loadState = LoadState.error;
        _errorMessage = e.toString();
      });
    }
  }

  Future<void> _loadPlaylist({String? targetUrl}) async {
    final String urlToFetch = (targetUrl ?? _urlController.text).trim();
    setState(() {
      _loadState = LoadState.loading;
      _errorMessage = '';
    });
    try {
      final String raw = await PlaylistFetcher.fetch(urlToFetch);
      final List<Channel> channels = M3uParser.parse(raw);
      if (channels.isEmpty) {
        throw const FormatException('No channels were found in that playlist.');
      }

      // Persist successfully loaded URL locally
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_m3u_url', urlToFetch);

      final Set<String> categorySet = <String>{};
      for (final Channel c in channels) {
        categorySet.add(c.group);
      }
      final List<String> sortedCategories = categorySet.toList()..sort();
      if (mounted) {
        setState(() {
          _allChannels = channels;
          _categories = <String>['All', 'Favorites', ...sortedCategories];
          _selectedCategory = 'All';
          _loadState = LoadState.loaded;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadState = LoadState.error;
          _errorMessage = e.toString();
        });
      }
    }
  }

  List<Channel> get _visibleChannels {
    if (_selectedCategory == 'All') return _allChannels;
    if (_selectedCategory == 'Favorites') {
      return _allChannels
          .where((Channel c) => _favoriteUrls.contains(c.url))
          .toList(growable: false);
    }
    return _allChannels
        .where((Channel c) => c.group == _selectedCategory)
        .toList(growable: false);
  }

  void _toggleFavorite(Channel channel) {
    setState(() {
      if (_favoriteUrls.contains(channel.url)) {
        _favoriteUrls.remove(channel.url);
      } else {
        _favoriteUrls.add(channel.url);
      }
    });
  }

  void _openPlayer(Channel channel) {
    final List<Channel> list = _visibleChannels;
    final int startIndex = list.indexOf(channel);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          channels: list,
          initialIndex: startIndex < 0 ? 0 : startIndex,
          favoriteUrls: _favoriteUrls,
          onToggleFavorite: _toggleFavorite,
        ),
      ),
    );
  }

  void _openSettingsDialog() {
    final TextEditingController settingsUrlController =
        TextEditingController(text: _urlController.text);

    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF15151C),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: const Row(
            children: <Widget>[
              Icon(Icons.settings, color: Color(0xFF00C2A8)),
              SizedBox(width: 10),
              Text('Playlist Settings', style: TextStyle(color: Colors.white)),
            ],
          ),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Text(
                  'M3U Playlist URL:',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: settingsUrlController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: const Color(0xFF0A0A0F),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Colors.white24),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFF00C2A8)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TvFocusable(
                  onSelect: () {
                    settingsUrlController.text = kDefaultPlaylistUrl;
                  },
                  builder: (context, hasFocus) => Container(
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                    decoration: BoxDecoration(
                      color: hasFocus ? Colors.amber : const Color(0xFF23232B),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: hasFocus ? Colors.white : Colors.transparent, width: 1.5),
                    ),
                    child: Text(
                      'Reset to Pakistan Default Playlist',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: hasFocus ? Colors.black : Colors.amber,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TvFocusable(
              onSelect: () => Navigator.of(dialogContext).pop(),
              builder: (context, hasFocus) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: hasFocus ? Colors.white24 : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text('CANCEL', style: TextStyle(color: Colors.white70)),
              ),
            ),
            TvFocusable(
              onSelect: () {
                final String newUrl = settingsUrlController.text.trim();
                if (newUrl.isNotEmpty) {
                  _urlController.text = newUrl;
                  Navigator.of(dialogContext).pop();
                  _loadPlaylist(targetUrl: newUrl);
                }
              },
              builder: (context, hasFocus) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: hasFocus ? const Color(0xFF00C2A8) : const Color(0xFF1E2A2E),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                      color: hasFocus ? Colors.white : Colors.transparent, width: 1.5),
                ),
                child: Text(
                  'SAVE & LOAD',
                  style: TextStyle(
                    color: hasFocus ? Colors.black : Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    switch (_loadState) {
      case LoadState.idle:
        body = _buildSetupView();
        break;
      case LoadState.loading:
        body = _buildLoadingView();
        break;
      case LoadState.error:
        body = _buildSetupView(errorText: _errorMessage);
        break;
      case LoadState.loaded:
        body = _buildBrowserView();
        break;
    }
    return Scaffold(body: SafeArea(child: body));
  }

  Widget _buildSetupView({String? errorText}) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Icon(Icons.live_tv, size: 56, color: Color(0xFF00C2A8)),
              const SizedBox(height: 12),
              const Text(
                'IPTV Player',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _urlController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'M3U Playlist URL',
                  labelStyle: const TextStyle(color: Colors.white54),
                  filled: true,
                  fillColor: const Color(0xFF15151C),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              if (errorText != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(errorText,
                    style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: TvFocusable(
                      autofocus: true,
                      onSelect: () => _loadPlaylist(),
                      builder: (context, hasFocus) => Container(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        decoration: BoxDecoration(
                          color: hasFocus ? const Color(0xFF00C2A8) : const Color(0xFF1E2A2E),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: hasFocus ? Colors.white : Colors.transparent, width: 2),
                        ),
                        child: Text(
                          'LOAD PLAYLIST',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: hasFocus ? Colors.black : Colors.white,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.1,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  TvFocusable(
                    onSelect: () {
                      _urlController.text = kDefaultPlaylistUrl;
                      _loadPlaylist();
                    },
                    builder: (context, hasFocus) => Container(
                      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                      decoration: BoxDecoration(
                        color: hasFocus ? Colors.amber : const Color(0xFF23232B),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: hasFocus ? Colors.white : Colors.transparent, width: 2),
                      ),
                      child: Text(
                        'RESET DEFAULT',
                        style: TextStyle(
                          color: hasFocus ? Colors.black : Colors.amber,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingView() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CircularProgressIndicator(color: Color(0xFF00C2A8)),
          SizedBox(height: 16),
          Text('Loading Pakistani channels…', style: TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }

  Widget _buildBrowserView() {
    final List<Channel> channels = _visibleChannels;
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: <Widget>[
              const Icon(Icons.live_tv, color: Color(0xFF00C2A8), size: 20),
              const SizedBox(width: 8),
              Text('${_allChannels.length} channels',
                  style: const TextStyle(color: Colors.white54, fontSize: 13)),
              const Spacer(),
              TvFocusable(
                onSelect: _openSettingsDialog,
                builder: (context, hasFocus) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: hasFocus ? const Color(0xFF00C2A8) : const Color(0xFF15151C),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: hasFocus ? Colors.white : Colors.white24, width: 1.5),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.settings,
                          size: 14, color: hasFocus ? Colors.black : Colors.white70),
                      const SizedBox(width: 6),
                      Text(
                        'Settings & Playlist',
                        style: TextStyle(
                            color: hasFocus ? Colors.black : Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFF23232B)),
        Expanded(
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 220,
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  itemCount: _categories.length,
                  itemBuilder: (context, index) => _categoryTile(_categories[index]),
                ),
              ),
              const VerticalDivider(width: 1, color: Color(0xFF23232B)),
              Expanded(
                child: channels.isEmpty
                    ? const Center(
                        child: Text('No channels in this category',
                            style: TextStyle(color: Colors.white54)),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        itemExtent: 66,
                        itemCount: channels.length,
                        itemBuilder: (context, index) {
                          final Channel channel = channels[index];
                          return ChannelTile(
                            channel: channel,
                            isFavorite: _favoriteUrls.contains(channel.url),
                            autofocus: index == 0,
                            onTune: () => _openPlayer(channel),
                            onToggleFavorite: () => _toggleFavorite(channel),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _categoryTile(String category) {
    final bool selected = category == _selectedCategory;
    return TvFocusable(
      onSelect: () => setState(() => _selectedCategory = category),
      builder: (context, hasFocus) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: hasFocus
                ? const Color(0xFF00C2A8)
                : (selected ? const Color(0xFF1E2A2E) : Colors.transparent),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: hasFocus ? Colors.white : Colors.transparent, width: 2),
          ),
          child: Text(
            category,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: hasFocus ? Colors.black : Colors.white70,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              fontSize: 16,
            ),
          ),
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------
// CHANNEL TILE — standalone focusable item with favorite shortcut
// -----------------------------------------------------------------------------

class ChannelTile extends StatefulWidget {
  final Channel channel;
  final bool isFavorite;
  final VoidCallback onTune;
  final VoidCallback onToggleFavorite;
  final bool autofocus;

  const ChannelTile({
    super.key,
    required this.channel,
    required this.isFavorite,
    required this.onTune,
    required this.onToggleFavorite,
    this.autofocus = false,
  });

  @override
  State<ChannelTile> createState() => _ChannelTileState();
}

class _ChannelTileState extends State<ChannelTile> {
  bool _hasFocus = false;

  void _onFocusChange(bool focused) {
    setState(() => _hasFocus = focused);
    if (focused) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Scrollable.ensureVisible(
            context,
            alignment: 0.5,
            duration: const Duration(milliseconds: 150),
          );
        }
      });
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final LogicalKeyboardKey key = event.logicalKey;

    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA) {
      widget.onTune();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.contextMenu || key == LogicalKeyboardKey.keyM) {
      widget.onToggleFavorite();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: _onFocusChange,
      onKeyEvent: _onKey,
      child: Container(
        height: 60,
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: _hasFocus ? const Color(0xFF00C2A8) : const Color(0xFF15151C),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: _hasFocus ? Colors.white : Colors.transparent, width: 2),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              widget.isFavorite ? Icons.star : Icons.star_border,
              size: 18,
              color: widget.isFavorite
                  ? (_hasFocus ? Colors.black : Colors.amber)
                  : (_hasFocus ? Colors.black45 : Colors.white38),
            ),
            const SizedBox(width: 10),
            
            // LOGO DISPLAY ADDED HERE
            if (widget.channel.logoUrl.isNotEmpty) ...[
              Image.network(
                widget.channel.logoUrl,
                width: 32,
                height: 32,
                errorBuilder: (context, error, stackTrace) =>
                    Icon(Icons.live_tv, size: 24, color: _hasFocus ? Colors.black54 : Colors.white54),
              ),
              const SizedBox(width: 10),
            ] else ...[
              Icon(Icons.live_tv, size: 24, color: _hasFocus ? Colors.black54 : Colors.white54),
              const SizedBox(width: 10),
            ],

            Expanded(
              child: Text(
                widget.channel.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _hasFocus ? Colors.black : Colors.white,
                  fontSize: 15,
                  fontWeight: _hasFocus ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              widget.channel.group,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _hasFocus ? Colors.black54 : Colors.white38,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// PLAYER SCREEN — full-screen playback + anti-failure engine + remote control
// -----------------------------------------------------------------------------

enum _PlayerState { initializing, playing, error }

class PlayerScreen extends StatefulWidget {
  final List<Channel> channels;
  final int initialIndex;
  final Set<String> favoriteUrls;
  final ValueChanged<Channel> onToggleFavorite;

  const PlayerScreen({
    super.key,
    required this.channels,
    required this.initialIndex,
    required this.favoriteUrls,
    required this.onToggleFavorite,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late int _currentIndex;
  VideoPlayerController? _controller;
  _PlayerState _state = _PlayerState.initializing;
  String _errorText = '';
  bool _showControls = true;
  bool _showBanner = true;

  Timer? _controlsHideTimer;
  Timer? _bannerTimer;

  int _loadToken = 0;

  final FocusNode _rootFocusNode = FocusNode(debugLabel: 'PlayerRoot');

  Channel get _currentChannel => widget.channels[_currentIndex];

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.channels.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, widget.channels.length - 1);
    _initializePlayer(_currentChannel);
  }

  @override
  void dispose() {
    _controlsHideTimer?.cancel();
    _bannerTimer?.cancel();
    _controller?.dispose();
    _rootFocusNode.dispose();
    super.dispose();
  }

  Future<void> _initializePlayer(Channel channel) async {
    final int token = ++_loadToken;
    final VideoPlayerController? oldController = _controller;
    _controller = null;

    setState(() {
      _state = _PlayerState.initializing;
      _errorText = '';
    });

    VideoPlayerController? newController;
    try {
      final Uri uri = Uri.parse(channel.url);
      newController = VideoPlayerController.networkUrl(
        uri,
        httpHeaders: kStreamHeaders,
      );

      await newController.initialize().timeout(kStreamInitTimeout);

      if (token != _loadToken) {
        await newController.dispose();
        await oldController?.dispose();
        return;
      }

      await oldController?.dispose();
      if (!mounted) {
        await newController.dispose();
        return;
      }

      await newController.setVolume(1.0);
      await newController.play();

      setState(() {
        _controller = newController;
        _state = _PlayerState.playing;
      });

      _restartBannerTimer();
      _restartControlsTimer();
    } on TimeoutException {
      if (token != _loadToken) return;
      await newController?.dispose();
      await oldController?.dispose();
      _handleStreamError('Connection timed out while loading the stream.');
    } catch (e) {
      if (token != _loadToken) return;
      await newController?.dispose();
      await oldController?.dispose();
      _handleStreamError(_describeError(e));
    }
  }

  String _describeError(Object e) {
    final String msg = e.toString();
    if (msg.contains('400')) return 'Stream rejected the request (HTTP 400).';
    if (msg.contains('403')) return 'Access denied by server (HTTP 403).';
    if (msg.contains('404')) return 'Stream not found (HTTP 404).';
    if (msg.contains('500')) return 'Server error (HTTP 500).';
    return 'Stream Unavailable.';
  }

  void _handleStreamError(String message) {
    if (!mounted) return;
    setState(() {
      _state = _PlayerState.error;
      _errorText = message;
    });
  }

  void _retry() => _initializePlayer(_currentChannel);

  void _restartBannerTimer() {
    _bannerTimer?.cancel();
    setState(() => _showBanner = true);
    _bannerTimer = Timer(kBannerDuration, () {
      if (mounted) setState(() => _showBanner = false);
    });
  }

  void _restartControlsTimer() {
    _controlsHideTimer?.cancel();
    setState(() => _showControls = true);
    _controlsHideTimer = Timer(kControlsAutoHide, () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _switchChannel(int delta) {
    final int total = widget.channels.length;
    if (total == 0) return;
    final int nextIndex = (_currentIndex + delta) % total;
    setState(() {
      _currentIndex = nextIndex;
      _showBanner = true;
    });
    _restartBannerTimer();
    _initializePlayer(_currentChannel);
  }

  void _togglePlayPause() {
    final VideoPlayerController? controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    setState(() {
      if (controller.value.isPlaying) {
        controller.pause();
      } else {
        controller.play();
      }
    });
    _restartControlsTimer();
  }

  void _handleBack() {
    if (_state == _PlayerState.error || (!_showControls && !_showBanner)) {
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {
      _showControls = false;
      _showBanner = false;
    });
    _controlsHideTimer?.cancel();
    _bannerTimer?.cancel();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final LogicalKeyboardKey key = event.logicalKey;

    // KEYCODE_CHANNEL_UP / KEYCODE_CHANNEL_DOWN (Remote CH+ / CH- buttons)
    if (key == LogicalKeyboardKey.channelUp) {
      _switchChannel(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.channelDown) {
      _switchChannel(-1);
      return KeyEventResult.handled;
    }

    // D-Pad UP/DOWN zapping
    if (key == LogicalKeyboardKey.arrowUp) {
      _switchChannel(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _switchChannel(-1);
      return KeyEventResult.handled;
    }

    // D-Pad CENTER / ENTER
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA) {
      if (_state == _PlayerState.error) {
        _retry();
      } else if (_showControls) {
        _togglePlayPause();
      } else {
        _restartControlsTimer();
      }
      return KeyEventResult.handled;
    }

    // Favorite toggle
    if (key == LogicalKeyboardKey.contextMenu || key == LogicalKeyboardKey.keyM) {
      widget.onToggleFavorite(_currentChannel);
      setState(() {});
      return KeyEventResult.handled;
    }

    // BACK BUTTON
    if (key == LogicalKeyboardKey.goBack || key == LogicalKeyboardKey.escape) {
      _handleBack();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _state == _PlayerState.error || (!_showControls && !_showBanner),
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        _handleBack();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _rootFocusNode,
          autofocus: true,
          onKeyEvent: _handleKey,
          child: GestureDetector(
            onTap: () {
              if (_state == _PlayerState.error) return;
              if (_showControls) {
                _togglePlayPause();
              } else {
                _restartControlsTimer();
              }
            },
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _buildVideoLayer(),
                if (_showBanner) _buildChannelBanner(),
                if (_showControls) _buildControlsOverlay(),
                if (_state == _PlayerState.error) _buildErrorOverlay(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVideoLayer() {
    if (_state == _PlayerState.initializing) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF00C2A8)));
    }
    final VideoPlayerController? controller = _controller;
    if (_state != _PlayerState.playing || controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    return Center(
      child: AspectRatio(
        aspectRatio: controller.value.aspectRatio == 0 ? 16 / 9 : controller.value.aspectRatio,
        child: VideoPlayer(controller),
      ),
    );
  }

  Widget _buildChannelBanner() {
    final bool isFav = widget.favoriteUrls.contains(_currentChannel.url);
    return Positioned(
      top: 24,
      left: 24,
      right: 24,
      child: AnimatedOpacity(
        opacity: _showBanner ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 300),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              const Text('LIVE',
                  style: TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(width: 14),
              Flexible(
                child: Text(
                  _currentChannel.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 10),
              Text('· ${_currentChannel.group}',
                  style: const TextStyle(color: Colors.white70, fontSize: 13)),
              if (isFav) ...<Widget>[
                const SizedBox(width: 10),
                const Icon(Icons.star, color: Colors.amber, size: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControlsOverlay() {
    final VideoPlayerController? controller = _controller;
    final bool isPlaying = controller?.value.isPlaying ?? false;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: <Color>[Colors.black.withValues(alpha: 0.75), Colors.transparent],
          ),
        ),
        child: Row(
          children: <Widget>[
            Icon(isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                color: Colors.white, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _currentChannel.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
            const Text('CH ▲▼ zap · OK play/pause · BACK exit',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorOverlay() {
    return Container(
      color: Colors.black87,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.wifi_tethering_error_rounded, color: Colors.redAccent, size: 48),
            const SizedBox(height: 12),
            const Text(
              'Stream Unavailable - Retrying...',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(_errorText, style: const TextStyle(color: Colors.white54, fontSize: 13)),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: _retry,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF00C2A8),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: const Text(
                  'RETRY  (press OK)',
                  style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}