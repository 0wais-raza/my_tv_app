// =============================================================================
// IPTV PLAYER — Single-file Flutter app optimized for Android TV boxes
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const IptvApp());
}

// -----------------------------------------------------------------------------
// CONSTANTS & CONFIGURATION
// -----------------------------------------------------------------------------

const String kSpoofedUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

const Map<String, String> kStreamHeaders = <String, String>{
  'User-Agent': kSpoofedUserAgent,
  'Referer': 'https://www.google.com/',
};

const String kDefaultPlaylistUrl = 'https://iptv-org.github.io/iptv/countries/pk.m3u';
const Duration kStreamInitTimeout = Duration(seconds: 5);
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

// Top-level function required for background Isolate parsing via compute()
List<Channel> _parseM3uIsolate(String raw) {
  return M3uParser.parse(raw);
}

// -----------------------------------------------------------------------------
// M3U PARSER
// -----------------------------------------------------------------------------

class M3uParser {
  M3uParser._();

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
        final String attrPart = commaIndex >= 0 ? line.substring(0, commaIndex) : line;
        pendingName = (commaIndex >= 0 && commaIndex + 1 < line.length)
            ? line.substring(commaIndex + 1).trim()
            : 'Unnamed Channel';
        pendingGroup = _extractAttribute(attrPart, 'group-title') ?? 'Uncategorized';
        pendingLogo = _extractAttribute(attrPart, 'tvg-logo') ?? '';
        hasPending = true;
      } else if (!line.startsWith('#')) {
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
// NETWORK FETCH
// -----------------------------------------------------------------------------

class PlaylistFetcher {
  PlaylistFetcher._();

  static Future<String> fetch(String url) async {
    final Uri? uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) throw const FormatException('Invalid URL format.');
    final response = await http.get(uri, headers: kStreamHeaders).timeout(const Duration(seconds: 10));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}');
    }
    return response.body;
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
// D-PAD FOCUSABLE WRAPPER
// -----------------------------------------------------------------------------

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
    if (focused && mounted) {
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
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA) {
      widget.onSelect();
      return KeyEventResult.handled;
    }
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
// HOME SCREEN
// -----------------------------------------------------------------------------

enum LoadState { idle, loading, loaded, error }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _urlController = TextEditingController(text: kDefaultPlaylistUrl);
  LoadState _loadState = LoadState.idle;
  String _errorMessage = '';

  List<Channel> _allChannels = [];
  List<String> _categories = [];
  String _selectedCategory = 'All';

  Set<String> _favoriteUrls = {};
  Set<String> _deadUrls = {};
  String? _lastWatchedUrl;
  bool _isCheckingHealth = false;

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

  Future<void> _checkFirstRunAndLoad() async {
    setState(() => _loadState = LoadState.loading);
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      String? savedUrl = prefs.getString('saved_m3u_url');
      if (savedUrl == null || savedUrl.trim().isEmpty) {
        savedUrl = kDefaultPlaylistUrl;
        await prefs.setString('saved_m3u_url', kDefaultPlaylistUrl);
      }
      _urlController.text = savedUrl;
      _favoriteUrls = (prefs.getStringList('favorite_urls') ?? []).toSet();
      _deadUrls = (prefs.getStringList('dead_urls') ?? []).toSet();
      _lastWatchedUrl = prefs.getString('last_watched_url');

      await _loadPlaylist(targetUrl: savedUrl);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadState = LoadState.error;
          _errorMessage = e.toString();
        });
      }
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
      
      // Compute Isolate background parsing to prevent UI freeze
      final List<Channel> channels = await compute(_parseM3uIsolate, raw);

      if (channels.isEmpty) throw const FormatException('No channels found in playlist.');

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_m3u_url', urlToFetch);

      final Set<String> categorySet = {};
      for (final c in channels) {
        categorySet.add(c.group);
      }
      final List<String> sortedCategories = categorySet.toList()..sort();

      if (mounted) {
        setState(() {
          _allChannels = channels;
          _categories = ['All', 'Favorites', 'Unavailable', ...sortedCategories];
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

  // Health check dead channels in parallel
  Future<void> _refreshDeadChannels() async {
    if (_isCheckingHealth || _deadUrls.isEmpty) return;
    setState(() => _isCheckingHealth = true);

    final Set<String> recovered = {};
    final List<String> toCheck = _deadUrls.toList();

    await Future.wait(toCheck.map((url) async {
      try {
        final uri = Uri.parse(url);
        final response = await http.get(uri, headers: kStreamHeaders).timeout(const Duration(seconds: 4));
        if (response.statusCode >= 200 && response.statusCode < 400) {
          recovered.add(url);
        }
      } catch (_) {}
    }));

    if (recovered.isNotEmpty) {
      setState(() => _deadUrls.removeAll(recovered));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('dead_urls', _deadUrls.toList());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restored ${recovered.length} channels back to the main list!')),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No offline channels recovered yet.')),
        );
      }
    }
    if (mounted) setState(() => _isCheckingHealth = false);
  }

  List<Channel> get _visibleChannels {
    if (_selectedCategory == 'Unavailable') {
      return _allChannels.where((c) => _deadUrls.contains(c.url)).toList();
    }
    final aliveChannels = _allChannels.where((c) => !_deadUrls.contains(c.url)).toList();
    if (_selectedCategory == 'All') return aliveChannels;
    if (_selectedCategory == 'Favorites') return aliveChannels.where((c) => _favoriteUrls.contains(c.url)).toList();
    return aliveChannels.where((c) => c.group == _selectedCategory).toList();
  }

  Future<void> _toggleFavorite(Channel channel) async {
    setState(() {
      if (_favoriteUrls.contains(channel.url)) {
        _favoriteUrls.remove(channel.url);
      } else {
        _favoriteUrls.add(channel.url);
      }
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('favorite_urls', _favoriteUrls.toList());
  }

  void _openPlayer(Channel channel) {
    final List<Channel> list = _visibleChannels;
    int startIndex = list.indexOf(channel);
    if (startIndex < 0) startIndex = 0;

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          channels: list,
          initialIndex: startIndex,
          favoriteUrls: _favoriteUrls,
          onToggleFavorite: _toggleFavorite,
          onChannelDead: (deadUrl) async {
            setState(() => _deadUrls.add(deadUrl));
            final prefs = await SharedPreferences.getInstance();
            await prefs.setStringList('dead_urls', _deadUrls.toList());
          },
          onLastWatchedChanged: (lastUrl) async {
            setState(() => _lastWatchedUrl = lastUrl);
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('last_watched_url', lastUrl);
          },
        ),
      ),
    );
  }

  void _openSettingsDialog() {
    final TextEditingController settingsUrlController = TextEditingController(text: _urlController.text);

    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF15151C),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: const Row(
            children: [
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
              children: [
                const Text('M3U Playlist URL:', style: TextStyle(color: Colors.white70, fontSize: 14)),
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
                  onSelect: () => settingsUrlController.text = kDefaultPlaylistUrl,
                  builder: (context, hasFocus) => Container(
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                    decoration: BoxDecoration(
                      color: hasFocus ? Colors.amber : const Color(0xFF23232B),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: hasFocus ? Colors.white : Colors.transparent, width: 1.5),
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
          actions: [
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
                  border: Border.all(color: hasFocus ? Colors.white : Colors.transparent, width: 1.5),
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
      case LoadState.loading:
        body = const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Color(0xFF00C2A8)),
              SizedBox(height: 16),
              Text('Initializing Channels & Storage...', style: TextStyle(color: Colors.white70)),
            ],
          ),
        );
        break;
      case LoadState.error:
        body = _buildErrorSetupView();
        break;
      case LoadState.loaded:
        body = _buildBrowserView();
        break;
    }
    return Scaffold(body: SafeArea(child: body));
  }

  Widget _buildErrorSetupView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
            const SizedBox(height: 12),
            Text(_errorMessage, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
            const SizedBox(height: 20),
            TvFocusable(
              autofocus: true,
              onSelect: () => _loadPlaylist(),
              builder: (context, hasFocus) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  color: hasFocus ? const Color(0xFF00C2A8) : const Color(0xFF1E2A2E),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('RETRY LOADING', style: TextStyle(color: hasFocus ? Colors.black : Colors.white)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBrowserView() {
    final channels = _visibleChannels;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              const Icon(Icons.live_tv, color: Color(0xFF00C2A8), size: 20),
              const SizedBox(width: 8),
              Text('${_allChannels.length} total channels', style: const TextStyle(color: Colors.white54, fontSize: 13)),
              const Spacer(),
              if (_deadUrls.isNotEmpty)
                TvFocusable(
                  onSelect: _refreshDeadChannels,
                  builder: (context, hasFocus) => Container(
                    margin: const EdgeInsets.only(right: 10),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: hasFocus ? Colors.amber : const Color(0xFF15151C),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: hasFocus ? Colors.white : Colors.white24, width: 1.5),
                    ),
                    child: _isCheckingHealth
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                        : Text('Refresh Health (${_deadUrls.length})', style: TextStyle(color: hasFocus ? Colors.black : Colors.white70, fontSize: 12)),
                  ),
                ),
              TvFocusable(
                onSelect: _openSettingsDialog,
                builder: (context, hasFocus) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: hasFocus ? const Color(0xFF00C2A8) : const Color(0xFF15151C),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: hasFocus ? Colors.white : Colors.white24, width: 1.5),
                  ),
                  child: Text('Settings', style: TextStyle(color: hasFocus ? Colors.black : Colors.white70, fontSize: 12)),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFF23232B)),
        Expanded(
          child: Row(
            children: [
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
                    ? const Center(child: Text('No channels in this category', style: TextStyle(color: Colors.white54)))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        itemExtent: 66,
                        itemCount: channels.length,
                        itemBuilder: (context, index) {
                          final channel = channels[index];
                          final isLastWatched = channel.url == _lastWatchedUrl;
                          return ChannelTile(
                            channel: channel,
                            isFavorite: _favoriteUrls.contains(channel.url),
                            autofocus: isLastWatched || (index == 0 && _lastWatchedUrl == null),
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
            color: hasFocus ? const Color(0xFF00C2A8) : (selected ? const Color(0xFF1E2A2E) : Colors.transparent),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: hasFocus ? Colors.white : Colors.transparent, width: 2),
          ),
          child: Text(
            category,
            style: TextStyle(
              color: hasFocus ? Colors.black : Colors.white70,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        );
      },
    );
  }
}

// -----------------------------------------------------------------------------
// CHANNEL TILE WIDGET
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
    if (focused && mounted) {
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
    final key = event.logicalKey;
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
          children: [
            Icon(
              widget.isFavorite ? Icons.star : Icons.star_border,
              size: 18,
              color: widget.isFavorite ? (_hasFocus ? Colors.black : Colors.amber) : (_hasFocus ? Colors.black45 : Colors.white38),
            ),
            const SizedBox(width: 10),
            if (widget.channel.logoUrl.isNotEmpty)
              Image.network(
                widget.channel.logoUrl,
                width: 32,
                height: 32,
                errorBuilder: (c, e, s) => Icon(Icons.live_tv, size: 24, color: _hasFocus ? Colors.black54 : Colors.white54),
              )
            else
              Icon(Icons.live_tv, size: 24, color: _hasFocus ? Colors.black54 : Colors.white54),
            const SizedBox(width: 10),
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
            Text(
              widget.channel.group,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: _hasFocus ? Colors.black54 : Colors.white38, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// PLAYER SCREEN
// -----------------------------------------------------------------------------

class PlayerScreen extends StatefulWidget {
  final List<Channel> channels;
  final int initialIndex;
  final Set<String> favoriteUrls;
  final ValueChanged<Channel> onToggleFavorite;
  final ValueChanged<String> onChannelDead;
  final ValueChanged<String> onLastWatchedChanged;

  const PlayerScreen({
    super.key,
    required this.channels,
    required this.initialIndex,
    required this.favoriteUrls,
    required this.onToggleFavorite,
    required this.onChannelDead,
    required this.onLastWatchedChanged,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late int _currentIndex;
  VideoPlayerController? _controller;
  bool _showControls = true, _showBanner = true;
  Timer? _controlsHideTimer, _bannerTimer, _reconnectTimer;
  int _loadToken = 0, _retryCount = 0;

  final FocusNode _rootFocusNode = FocusNode(debugLabel: 'PlayerRoot');

  Channel get _currentChannel => widget.channels[_currentIndex];

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.channels.isEmpty ? 0 : widget.initialIndex.clamp(0, widget.channels.length - 1);
    _initializePlayer(_currentChannel);
  }

  @override
  void dispose() {
    _controlsHideTimer?.cancel();
    _bannerTimer?.cancel();
    _reconnectTimer?.cancel();
    _controller?.removeListener(_videoListener);
    _controller?.dispose();
    _rootFocusNode.dispose();
    super.dispose();
  }

  // Silent auto-reconnect logic on video stream drop
  void _videoListener() {
    if (!mounted || _controller == null) return;
    if (_controller!.value.hasError && _reconnectTimer == null) {
      _reconnectTimer = Timer(const Duration(seconds: 2), () {
        _reconnectTimer = null;
        if (_retryCount < 3) {
          _retryCount++;
          _initializePlayer(_currentChannel, silentRetry: true);
        } else {
          widget.onChannelDead(_currentChannel.url);
          _switchChannel(1); // Auto zap to next channel if completely offline
        }
      });
    }
  }

  Future<void> _initializePlayer(Channel channel, {bool silentRetry = false}) async {
    final int token = ++_loadToken;
    final oldController = _controller;
    _controller = null;
    if (!silentRetry) _retryCount = 0;

    widget.onLastWatchedChanged(channel.url);

    VideoPlayerController? newController;
    try {
      newController = VideoPlayerController.networkUrl(Uri.parse(channel.url), httpHeaders: kStreamHeaders);
      newController.addListener(_videoListener);

      await newController.initialize().timeout(kStreamInitTimeout);

      if (token != _loadToken) {
        await newController.dispose();
        await oldController?.dispose();
        return;
      }

      oldController?.removeListener(_videoListener);
      await oldController?.dispose();

      if (!mounted) {
        await newController.dispose();
        return;
      }

      await newController.setVolume(1.0);
      await newController.play();

      setState(() {
        _controller = newController;
        _retryCount = 0;
      });
      _restartBannerTimer();
      _restartControlsTimer();
    } catch (e) {
      if (token != _loadToken) return;
      await newController?.dispose();
      await oldController?.dispose();

      if (_retryCount < 3) {
        _retryCount++;
        Future.delayed(const Duration(seconds: 2), () => _initializePlayer(channel, silentRetry: true));
      } else {
        widget.onChannelDead(channel.url);
        _switchChannel(1);
      }
    }
  }

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
    if (widget.channels.isEmpty) return;
    setState(() {
      _currentIndex = (_currentIndex + delta) % widget.channels.length;
      if (_currentIndex < 0) _currentIndex = widget.channels.length - 1;
      _showBanner = true;
    });
    _restartBannerTimer();
    _initializePlayer(_currentChannel);
  }

  void _togglePlayPause() {
    if (_controller == null || !_controller!.value.isInitialized) return;
    setState(() {
      if (_controller!.value.isPlaying) {
        _controller!.pause();
      } else {
        _controller!.play();
      }
    });
    _restartControlsTimer();
  }

  void _handleBack() {
    if (!_showControls && !_showBanner) {
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
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.channelUp || key == LogicalKeyboardKey.arrowUp) {
      _switchChannel(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.channelDown || key == LogicalKeyboardKey.arrowDown) {
      _switchChannel(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.gameButtonA) {
      if (_showControls) {
        _togglePlayPause();
      } else {
        _restartControlsTimer();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.contextMenu || key == LogicalKeyboardKey.keyM) {
      widget.onToggleFavorite(_currentChannel);
      setState(() {});
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.goBack || key == LogicalKeyboardKey.escape) {
      _handleBack();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: (!_showControls && !_showBanner),
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _rootFocusNode,
          autofocus: true,
          onKeyEvent: _handleKey,
          child: GestureDetector(
            onTap: () {
              if (_showControls) {
                _togglePlayPause();
              } else {
                _restartControlsTimer();
              }
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_controller != null && _controller!.value.isInitialized)
                  Center(
                    child: AspectRatio(
                      aspectRatio: _controller!.value.aspectRatio == 0 ? 16 / 9 : _controller!.value.aspectRatio,
                      child: VideoPlayer(_controller!),
                    ),
                  )
                else
                  const Center(child: CircularProgressIndicator(color: Color(0xFF00C2A8))),
                if (_showBanner) _buildChannelBanner(),
                if (_showControls) _buildControlsOverlay(),
              ],
            ),
          ),
        ),
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
          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(8)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 8, height: 8, decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              const Text('LIVE', style: TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(width: 14),
              Flexible(child: Text(_currentChannel.name, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold))),
              const SizedBox(width: 10),
              Text('· ${_currentChannel.group}', style: const TextStyle(color: Colors.white70, fontSize: 13)),
              if (isFav) const Padding(padding: EdgeInsets.only(left: 10), child: Icon(Icons.star, color: Colors.amber, size: 16)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControlsOverlay() {
    final bool isPlaying = _controller?.value.isPlaying ?? false;
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
          children: [
            Icon(isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled, color: Colors.white, size: 32),
            const SizedBox(width: 12),
            Expanded(child: Text(_currentChannel.name, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 15))),
            const Text('CH ▲▼ zap · OK play/pause · BACK exit', style: TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
