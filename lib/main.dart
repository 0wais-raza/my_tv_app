// =============================================================================
// IPTV PLAYER — single-file Flutter app for budget Android TV boxes
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
  SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const IptvApp());
}

// -----------------------------------------------------------------------------
// GLOBAL CONSTANTS[cite: 1]
// -----------------------------------------------------------------------------

const String kSpoofedUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

const Map<String, String> kStreamHeaders = <String, String>{
  'User-Agent': kSpoofedUserAgent,
  'Referer': 'https://www.google.com/',
};

const String kDefaultPlaylistUrl =
    'https://iptv-org.github.io/iptv/countries/pk.m3u';

// Increased timeout for low-bandwidth optimization
const Duration kStreamInitTimeout = Duration(seconds: 15);
const Duration kBannerDuration = Duration(seconds: 3);
const Duration kControlsAutoHide = Duration(seconds: 5);

// -----------------------------------------------------------------------------
// MODEL[cite: 1]
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
// M3U PARSER[cite: 1]
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
        continue;
      } else {
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
// NETWORK[cite: 1]
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
        throw Exception('Server HTTP ${response.statusCode}.');
      }
      return response.body;
    } catch (e) {
      if (e is FormatException) rethrow;
      throw Exception('Failed to load: ${e.toString()}');
    }
  }
}

// -----------------------------------------------------------------------------
// APP ROOT[cite: 1]
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
// REUSABLE D-PAD FOCUSABLE WRAPPER[cite: 1]
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
  final TextEditingController _urlController =
      TextEditingController(text: kDefaultPlaylistUrl);

  LoadState _loadState = LoadState.idle;
  String _errorMessage = '';

  List<Channel> _allChannels = const <Channel>[];
  List<String> _baseCategories = const <String>[];
  String _selectedCategory = 'All';
  
  final Set<String> _favoriteUrls = <String>{}; 
  final Set<String> _deadUrls = <String>{}; // Dynamic unavailable tracking

  DateTime? _lastBackPressTime; // Double-tap exit logic

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
      _deadUrls.clear(); // Reset dead URLs on new load
    });
    try {
      final String raw = await PlaylistFetcher.fetch(urlToFetch);
      final List<Channel> channels = M3uParser.parse(raw);
      if (channels.isEmpty) {
        throw const FormatException('No channels found.');
      }

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
          _baseCategories = sortedCategories;
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

  List<String> get _dynamicCategories {
    final List<String> cats = ['All'];
    if (_favoriteUrls.isNotEmpty) cats.add('Favorites');
    if (_deadUrls.isNotEmpty) cats.add('Unavailable');
    cats.addAll(_baseCategories);
    return cats;
  }

  List<Channel> get _visibleChannels {
    if (_selectedCategory == 'Unavailable') {
      return _allChannels.where((c) => _deadUrls.contains(c.url)).toList();
    }
    
    // Filter dead URLs from all other lists
    final available = _allChannels.where((c) => !_deadUrls.contains(c.url));
    
    if (_selectedCategory == 'All') return available.toList();
    if (_selectedCategory == 'Favorites') {
      return available.where((c) => _favoriteUrls.contains(c.url)).toList();
    }
    return available.where((c) => c.group == _selectedCategory).toList();
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

  void _markChannelStatus(String url, bool isDead) {
    setState(() {
      if (isDead) {
        _deadUrls.add(url);
        // Move selection if current category empties out
        if (_visibleChannels.isEmpty) _selectedCategory = 'All';
      } else {
        _deadUrls.remove(url);
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
          onChannelStatusChange: _markChannelStatus,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    switch (_loadState) {
      case LoadState.idle:
      case LoadState.error:
        body = _buildSetupView(errorText: _errorMessage);
        break;
      case LoadState.loading:
        body = _buildLoadingView();
        break;
      case LoadState.loaded:
        body = _buildBrowserView();
        break;
    }

    // Double-Back to Quit logic
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        final now = DateTime.now();
        if (_lastBackPressTime == null || 
            now.difference(_lastBackPressTime!) > const Duration(seconds: 2)) {
          _lastBackPressTime = now;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Press BACK again to exit app'),
              duration: Duration(seconds: 2),
              backgroundColor: Color(0xFF00C2A8),
            )
          );
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(body: SafeArea(child: body)),
    );
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
              if (errorText != null && errorText.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                Text(errorText, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
              ],
              const SizedBox(height: 20),
              TvFocusable(
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
                    style: TextStyle(color: hasFocus ? Colors.black : Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
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
          Text('Loading channels…', style: TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }

  Widget _buildBrowserView() {
    final List<Channel> channels = _visibleChannels;
    final categories = _dynamicCategories;
    
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: <Widget>[
              const Icon(Icons.live_tv, color: Color(0xFF00C2A8), size: 20),
              const SizedBox(width: 8),
              Text('${_allChannels.length} channels total', style: const TextStyle(color: Colors.white54, fontSize: 13)),
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
                  itemCount: categories.length,
                  itemBuilder: (context, index) => _categoryTile(categories[index]),
                ),
              ),
              const VerticalDivider(width: 1, color: Color(0xFF23232B)),
              Expanded(
                child: channels.isEmpty
                    ? const Center(child: Text('No channels here', style: TextStyle(color: Colors.white54)))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        itemExtent: 70,
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
    final bool isDeadCat = category == 'Unavailable';
    
    return TvFocusable(
      onSelect: () => setState(() => _selectedCategory = category),
      builder: (context, hasFocus) {
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: hasFocus
                ? (isDeadCat ? Colors.redAccent : const Color(0xFF00C2A8))
                : (selected ? const Color(0xFF1E2A2E) : Colors.transparent),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: hasFocus ? Colors.white : Colors.transparent, width: 2),
          ),
          child: Text(
            category,
            style: TextStyle(
              color: hasFocus ? Colors.black : (isDeadCat ? Colors.redAccent : Colors.white70),
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
// CHANNEL TILE — Fixed with distinct D-Pad Focus targets for Star and Tune
// -----------------------------------------------------------------------------

class ChannelTile extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          // Favorite Star Focus Area
          TvFocusable(
            onSelect: onToggleFavorite,
            builder: (context, hasFocus) => Container(
              height: 60,
              width: 50,
              decoration: BoxDecoration(
                color: hasFocus ? Colors.amber : const Color(0xFF15151C),
                borderRadius: const BorderRadius.only(topLeft: Radius.circular(6), bottomLeft: Radius.circular(6)),
                border: Border.all(color: hasFocus ? Colors.white : Colors.transparent, width: 2),
              ),
              child: Icon(
                isFavorite ? Icons.star : Icons.star_border,
                color: hasFocus ? Colors.black : (isFavorite ? Colors.amber : Colors.white38),
              ),
            ),
          ),
          const SizedBox(width: 4),
          // Channel Title Focus Area
          Expanded(
            child: TvFocusable(
              autofocus: autofocus,
              onSelect: onTune,
              builder: (context, hasFocus) => Container(
                height: 60,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: hasFocus ? const Color(0xFF00C2A8) : const Color(0xFF15151C),
                  borderRadius: const BorderRadius.only(topRight: Radius.circular(6), bottomRight: Radius.circular(6)),
                  border: Border.all(color: hasFocus ? Colors.white : Colors.transparent, width: 2),
                ),
                child: Row(
                  children: [
                    if (channel.logoUrl.isNotEmpty) ...[
                      Image.network(
                        channel.logoUrl,
                        width: 32,
                        height: 32,
                        errorBuilder: (context, error, stackTrace) =>
                            Icon(Icons.live_tv, size: 24, color: hasFocus ? Colors.black54 : Colors.white54),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Text(
                        channel.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: hasFocus ? Colors.black : Colors.white,
                          fontSize: 15,
                          fontWeight: hasFocus ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      channel.group,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: hasFocus ? Colors.black54 : Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// PLAYER SCREEN
// -----------------------------------------------------------------------------

enum _PlayerState { initializing, playing, error }

class PlayerScreen extends StatefulWidget {
  final List<Channel> channels;
  final int initialIndex;
  final Set<String> favoriteUrls;
  final ValueChanged<Channel> onToggleFavorite;
  final Function(String, bool) onChannelStatusChange;

  const PlayerScreen({
    super.key,
    required this.channels,
    required this.initialIndex,
    required this.favoriteUrls,
    required this.onToggleFavorite,
    required this.onChannelStatusChange,
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
  Timer? _retryTimer;
  int _retryCountdown = 10;
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
    _retryTimer?.cancel();
    _controller?.dispose();
    _rootFocusNode.dispose();
    super.dispose();
  }

  Future<void> _initializePlayer(Channel channel) async {
    final int token = ++_loadToken;
    final VideoPlayerController? oldController = _controller;
    _controller = null;
    _retryTimer?.cancel();

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

      // Channel is working, recover it
      widget.onChannelStatusChange(channel.url, false);

      setState(() {
        _controller = newController;
        _state = _PlayerState.playing;
      });

      _restartBannerTimer();
      _restartControlsTimer();
    } catch (e) {
      if (token != _loadToken) return;
      await newController?.dispose();
      await oldController?.dispose();
      _handleStreamError('Stream failed: ${e.toString().split(':').first}');
    }
  }

  void _handleStreamError(String message) {
    if (!mounted) return;
    
    // Mark channel as dead
    widget.onChannelStatusChange(_currentChannel.url, true);

    setState(() {
      _state = _PlayerState.error;
      _errorText = message;
      _retryCountdown = 8; // Auto-retry every 8 seconds
    });

    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_retryCountdown > 1) {
        setState(() => _retryCountdown--);
      } else {
        timer.cancel();
        _retry();
      }
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
    Navigator.of(context).maybePop();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final LogicalKeyboardKey key = event.logicalKey;

    if (key == LogicalKeyboardKey.channelUp || key == LogicalKeyboardKey.arrowUp) {
      _switchChannel(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.channelDown || key == LogicalKeyboardKey.arrowDown) {
      _switchChannel(-1);
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (_state == _PlayerState.error) {
        _retryTimer?.cancel();
        _retry();
      } else if (_showControls) {
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
      if (_showControls || _showBanner) {
        setState(() {
          _showControls = false;
          _showBanner = false;
        });
        _controlsHideTimer?.cancel();
        _bannerTimer?.cancel();
        return KeyEventResult.handled;
      }
      _handleBack();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _rootFocusNode,
        autofocus: true,
        onKeyEvent: _handleKey,
        child: GestureDetector(
          onTap: () {
            if (_state == _PlayerState.error) {
              _retryTimer?.cancel();
              _retry();
              return;
            }
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
              const Text('LIVE', style: TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(width: 14),
              Flexible(
                child: Text(
                  _currentChannel.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 10),
              Text('· ${_currentChannel.group}', style: const TextStyle(color: Colors.white70, fontSize: 13)),
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
            colors: <Color>[Colors.black.withValues(alpha: 0.85), Colors.transparent],
          ),
        ),
        child: Row(
          children: <Widget>[
            Icon(isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled, color: Colors.white, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _currentChannel.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
            const Text('CH ▲▼ zap · OK play/pause · BACK exit', style: TextStyle(color: Colors.white54, fontSize: 12)),
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
              'Stream Unavailable',
              style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(_errorText, style: const TextStyle(color: Colors.white54, fontSize: 14)),
            const SizedBox(height: 24),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(color: Color(0xFF00C2A8), strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Text(
                  'Auto-reconnecting in $_retryCountdown seconds...',
                  style: const TextStyle(color: Colors.white70, fontSize: 15),
                ),
              ],
            ),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: () {
                _retryTimer?.cancel();
                _retry();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF00C2A8),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: const Text(
                  'RETRY NOW  (press OK)',
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
