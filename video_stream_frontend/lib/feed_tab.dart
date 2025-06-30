import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';
import 'package:video_stream_frontend/app_video/app_video.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:video_stream_frontend/app_video/utils/preload_helpers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

class FeedTabBackup extends StatefulWidget {
  const FeedTabBackup({super.key});

  @override
  State<FeedTabBackup> createState() => _FeedTabBackupState();
}

class _FeedTabBackupState extends State<FeedTabBackup>
    with WidgetsBindingObserver {
  // Danh sách video lấy từ backend
  final List<Map<String, dynamic>> _videos = [];
  // Map lưu url video theo id
  final Map<String, String?> _videoUrls = {}; // id -> videoUrl
  // Map lưu meta data chi tiết theo id
  final Map<String, Map<String, dynamic>> _videoMeta = {}; // id -> meta
  // Trạng thái loading
  bool _isLoading = false;
  // Thông báo lỗi nếu có
  String? _errorMessage;
  // Controller cho PageView
  late final PageController _pageController;
  // Trang hiện tại
  int _currentPage = 0;
  // Tốc độ mạng đo được (Mbps)
  double? _networkSpeedMbps;
  static const _networkSpeedKey = 'network_speed_mbps';
  // Player pool (LRU cache) cho video_player
  final Map<String, VideoPlayerController> _controllerCache = {};
  late final int _thumbCacheSize;
  late final LruImageCache _thumbCache;
  Timer? _networkSpeedTimer;
  double? _lastNetworkSpeed;
  // Theo dõi tốc độ cuộn
  double _scrollVelocity = 0.0;
  Timer? _preloadDebounceTimer;
  final List<double> _velocityWindow = []; // Cửa sổ vận tốc để tính trung bình
  static const int _velocityWindowSize = 5; // Lưu 5 giá trị vận tốc gần nhất
  double? _lastScrollPosition;
  // Thêm biến đánh dấu đã dispose cache
  bool _isCacheDisposed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Adaptive thumbnail cache theo RAM thiết bị
    final ramGB =
        PlatformDispatcher.instance.views.first.physicalSize.width *
        PlatformDispatcher.instance.views.first.physicalSize.height *
        4 /
        (1024 * 1024 * 1024);
    int cacheSize = 10;
    if (ramGB < 4) {
      cacheSize = 10;
    } else {
      cacheSize = 20;
    }

    _thumbCacheSize = cacheSize;
    _thumbCache = LruImageCache(_thumbCacheSize);
    print(
      '[FeedTab] estimatedDeviceMemory: ${ramGB.toStringAsFixed(2)} GB, thumbnail cache size: $_thumbCacheSize',
    );
    // Tăng cache size để tránh evict khi cuộn nhanh
    PaintingBinding.instance.imageCache.maximumSize = 200;
    _pageController = PageController();
    _pageController.addListener(_onPageChanged);
    print('[FeedTab] initState');
    _checkNetworkSpeed(); // Đo tốc độ mạng khi khởi động
    _fetchMetaData(); // Lấy danh sách video
    // Đo lại băng thông mỗi 3 phút
    _networkSpeedTimer = Timer.periodic(const Duration(minutes: 3), (_) {
      print('[FeedTab] Timer: re-checking network speed (3 min interval)');
      _checkNetworkSpeed(force: true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _networkSpeedTimer?.cancel();
    _preloadDebounceTimer?.cancel();
    _pageController.removeListener(_onPageChanged);
    _pageController.dispose();
    _controllerCache.keys.forEach(_disposeController);
    _controllerCache.clear();
    _isCacheDisposed = true;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
        _pauseAllControllers();
        break;
      case AppLifecycleState.resumed:
        _resumeActiveController();
        break;
      default:
        break;
    }
  }

  void _disposeController(String id) {
    final controller = _controllerCache[id];
    if (controller != null && !controller.value.isPlaying) {
      print('[FeedTab] Disposing controller for id=$id');
      controller.dispose();
      _controllerCache.remove(id);
    }
  }

  Future<void> _checkNetworkSpeed({bool force = false}) async {
    print('[FeedTab][SpeedTest] Bắt đầu kiểm tra tốc độ mạng, force=$force');
    final prefs = await SharedPreferences.getInstance();
    if (!force) {
      final cached = prefs.getDouble(_networkSpeedKey);
      print('[FeedTab][SpeedTest] Cached speed: $cached');
      if (cached != null && cached > 0) {
        setState(() {
          _networkSpeedMbps = cached;
        });
        print('[FeedTab][SpeedTest] Dùng cached speed: $cached');
        return;
      }
    }
    final connectivity = await Connectivity().checkConnectivity();
    print('[FeedTab][SpeedTest] Connectivity: $connectivity');
    if (connectivity == ConnectivityResult.none) {
      setState(() {
        _networkSpeedMbps = 0;
      });
      print('[FeedTab][SpeedTest] Không có kết nối mạng');
      return;
    }
    final testFiles = [
      'https://speed.hetzner.de/1MB.bin',
      'https://speed.cloudflare.com/__down?bytes=1000000',
      'https://download.thinkbroadband.com/1MB.zip',
      'https://ipv4.download.thinkbroadband.com/1MB.zip',
      'https://google.com/images/phd/px.gif',
    ];
    List<double> speeds = [];
    for (final url in testFiles) {
      try {
        print('[FeedTab][SpeedTest] Đo url: $url');
        final stopwatch = Stopwatch()..start();
        final request = await HttpClient().getUrl(Uri.parse(url));
        final response = await request.close();
        int total = 0;
        await for (final chunk in response) {
          total += chunk.length;
        }
        stopwatch.stop();
        print(
          '[FeedTab][SpeedTest] Đã tải xong $url, bytes=$total, time=${stopwatch.elapsedMilliseconds}ms',
        );
        if (total > 0 && stopwatch.elapsedMilliseconds > 0) {
          final mb = total / (1024 * 1024);
          final sec = stopwatch.elapsedMilliseconds / 1000.0;
          final mbps = mb / sec * 8; // Mbps
          speeds.add(mbps);
          print('[FeedTab][SpeedTest] Speed $url: $mbps Mbps');
        } else {
          print('[FeedTab][SpeedTest] Không đủ dữ liệu để tính speed cho $url');
        }
      } catch (e) {
        print('[FeedTab][SpeedTest] Lỗi khi đo $url: $e');
      }
    }
    final best = speeds.isNotEmpty ? speeds.reduce(max) : 3.0;
    print('[FeedTab][SpeedTest] Kết quả cuối cùng: $best Mbps, speeds=$speeds');
    if (_lastNetworkSpeed != null &&
        (_lastNetworkSpeed! - best).abs() / (_lastNetworkSpeed! + 0.01) > 0.2) {
      print(
        '[FeedTab][SpeedTest] Network speed changed significantly: $_lastNetworkSpeed -> $best Mbps',
      );
    }
    _lastNetworkSpeed = best;
    setState(() {
      _networkSpeedMbps = best;
      print('[FeedTab] _checkNetworkSpeed: $best');
    });
    await prefs.setDouble(_networkSpeedKey, best);
  }

  Future<void> _fetchMetaData() async {
    if (_isCacheDisposed) return;
    print('[FeedTab] _fetchMetaData start');
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final response = await http.get(
        Uri.parse('http://192.168.208.108:4000/videos'),
      );
      print('[FeedTab] /videos status: ${response.statusCode}');
      if (!mounted) return;
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        setState(() {
          _videos.clear();
          _videos.addAll(data.cast<Map<String, dynamic>>());
          print('[FeedTab] Videos loaded: ${_videos.length}');
        });
        Future.microtask(() {
          for (int i = 0; i < 5 && i < _videos.length; i++) {
            _preloadThumbnail(_videos[i]);
            _fetchVideoData(_videos[i]['groupId'], _videos[i]['id']);
          }
        });
      } else {
        setState(() {
          _errorMessage = 'Failed to load videos: ${response.statusCode}';
        });
        print('[FeedTab] Error: $_errorMessage');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Error loading videos: $e';
        });
        print('[FeedTab] Exception: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        print('[FeedTab] _fetchMetaData done');
      }
    }
  }

  Future<void> _fetchVideoData(String groupId, String id) async {
    if (_isCacheDisposed) return;
    if (_videoMeta.containsKey(id) && _videoUrls.containsKey(id)) return;
    final url = 'http://192.168.208.108:4000/video/$groupId/$id/meta';
    try {
      final meta = await fetchJsonInIsolate(url);
      print('[FeedTab][META] id=$id, meta=${meta.toString()}');
      if (meta.isNotEmpty) {
        setState(() {
          _videoMeta[id] = meta;
        });
        if (meta['qualities'] != null && meta['qualities'] is List) {
          final speed = _networkSpeedMbps?.toString() ?? '3';
          String? manifestUrl;
          if (meta['qualities'].isNotEmpty) {
            String resolution = '480p';
            final s = double.tryParse(speed) ?? 3;
            if (s >= 5)
              resolution = '1080p';
            else if (s >= 1)
              resolution = '720p';
            final q = (meta['qualities'] as List).firstWhere(
              (q) => q['resolution'] == resolution,
              orElse: () => meta['qualities'].last,
            );
            manifestUrl = 'http://192.168.208.108:4000${q['hls']}';
            print(
              '[FeedTab][QUALITIES] id=$id, resolution=$resolution, manifestUrl=$manifestUrl, qualities=${meta['qualities']}',
            );
          }
          setState(() {
            _videoUrls[id] = manifestUrl;
          });
        }
      }
    } catch (e) {
      print('[FeedTab] _fetchVideoData error: $e');
    }
  }

  Future<void> _preloadThumbnail(Map<String, dynamic> video) async {
    if (_isCacheDisposed) return;
    final String? id = video['id']?.toString();
    final String? thumb = video['thumbnail']?.toString();
    if (id == null ||
        id.isEmpty ||
        thumb == null ||
        thumb.isEmpty ||
        _thumbCache[id] != null)
      return;
    final url =
        thumb.startsWith('http') ? thumb : 'http://192.168.208.108:4000$thumb';
    try {
      final bytes = await preloadImageBytesInIsolate(url);
      final image = MemoryImage(bytes);
      if (_isCacheDisposed) return;
      setState(() {
        _thumbCache.put(id, image);
      });
    } catch (e) {
      print('[FeedTab] _preloadThumbnail error: $e');
    }
  }

  void _onPageChanged() {
    if (_isCacheDisposed) return;
    final newPage = _pageController.page?.round() ?? 0;
    if (newPage != _currentPage) {
      setState(() => _currentPage = newPage);
      _schedulePreload(newPage);
    }
  }

  void _schedulePreload(int centerIndex) {
    if (_isCacheDisposed) return;
    _preloadDebounceTimer?.cancel();
    _preloadDebounceTimer = Timer(const Duration(milliseconds: 300), () {
      _preloadData(centerIndex);
    });
  }

  void _preloadData(int centerIndex) {
    if (_isCacheDisposed) return;
    final preloadRange = _getPreloadRange();
    final preloadIds = <String>{};
    for (int i = -preloadRange; i <= preloadRange; i++) {
      final index = centerIndex + i;
      if (index >= 0 && index < _videos.length) {
        final video = _videos[index];
        final id = video['id']?.toString();
        final groupId = video['groupId']?.toString();
        if (id != null && groupId != null) {
          preloadIds.add(id);
          _preloadThumbnail(video);
          _fetchVideoData(groupId, id);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    print('fastSpeed: $_networkSpeedMbps');
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollUpdateNotification) {
          _handleScrollUpdate(notification.metrics);
        }
        return true;
      },
      child:
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _errorMessage != null
              ? Center(child: Text(_errorMessage!))
              : _videos.isEmpty
              ? const Center(child: Text('No videos available'))
              : PageView.builder(
                controller: _pageController,
                scrollDirection: Axis.vertical,
                itemCount: _videos.length,
                itemBuilder: (context, index) {
                  final video = _videos[index];
                  final id = video['id']?.toString();
                  final groupId = video['groupId']?.toString();
                  final meta = id != null ? _videoMeta[id] : null;
                  final videoUrl = id != null ? _videoUrls[id] : null;
                  print('[FeedTab] FutureBuilder: id=$id, videoUrl=$videoUrl');
                  return VisibilityDetector(
                    key: Key('video-visibility-${id ?? ''}'),
                    onVisibilityChanged: (info) {
                      final isVisible = info.visibleFraction > 0.8;
                      if (isVisible) {
                        _playOnlyActiveController(id);
                      } else {
                        if (id != null) _disposeController(id);
                      }
                    },
                    child: FutureBuilder<VideoPlayerController?>(
                      key: ValueKey('$id-$videoUrl-${index == _currentPage}'),
                      future:
                          (id != null &&
                                  videoUrl != null &&
                                  _controllerCache.containsKey(id))
                              ? Future.value(_controllerCache[id])
                              : (id != null && videoUrl != null)
                              ? _getOrCreateController(
                                videoUrl,
                                id,
                                autoPlay: index == _currentPage,
                              )
                              : Future.value(null),
                      builder: (context, snapshot) {
                        final controller = snapshot.data;
                        final isReady =
                            controller != null &&
                            controller.value.isInitialized &&
                            !controller.value.hasError;
                        print(
                          '[FeedTab] TikTokVideoItem: id=$id, isActive=${index == _currentPage}, controller=$controller',
                        );
                        return TikTokVideoItem(
                          video: video,
                          isActive: index == _currentPage,
                          controller: isReady ? controller : null,
                          meta: meta,
                          preload: () {
                            if (groupId != null && id != null) {
                              _fetchVideoData(groupId, id);
                              _preloadThumbnail(video);
                            }
                          },
                          thumbProvider: id != null ? _thumbCache[id] : null,
                          showLoading: !isReady,
                        );
                      },
                    ),
                  );
                },
              ),
    );
  }

  Future<VideoPlayerController?> _getOrCreateController(
    String videoUrl,
    String id, {
    bool autoPlay = false,
  }) async {
    if (_isCacheDisposed) return null;
    // Luôn chỉ giữ controller cho video đang active
    if (_controllerCache.containsKey(id)) {
      final controller = _controllerCache[id]!;
      if (controller.value.hasError || !controller.value.isInitialized) {
        _controllerCache.remove(id);
      } else {
        return controller;
      }
    }
    // Nếu không phải video active, không tạo controller
    final isActive = _videos[_currentPage]['id']?.toString() == id;
    if (!isActive) return null;
    try {
      final controller = VideoPlayerController.networkUrl(Uri.parse(videoUrl));
      await controller.initialize();
      if (_isCacheDisposed) {
        controller.dispose();
        return null;
      }
      _controllerCache[id] = controller;
      if (autoPlay) await controller.play();
      return controller;
    } catch (e) {
      print('Controller init error: $e');
      return null;
    }
  }

  void _handleScrollUpdate(ScrollMetrics metrics) {
    final scrollPosition = metrics.pixels;
    final maxScroll = metrics.maxScrollExtent;
    final velocity =
        (scrollPosition - (_lastScrollPosition ?? scrollPosition)) /
        (maxScroll > 0 ? maxScroll : 1);
    _lastScrollPosition = scrollPosition;
    _velocityWindow.add(velocity.abs());
    if (_velocityWindow.length > _velocityWindowSize) {
      _velocityWindow.removeAt(0);
    }
    _scrollVelocity =
        _velocityWindow.isNotEmpty
            ? _velocityWindow.reduce((a, b) => a + b) / _velocityWindow.length
            : 0;
  }

  void _pauseAllControllers() {
    _controllerCache.forEach((_, controller) {
      if (controller.value.isPlaying) controller.pause();
    });
  }

  void _resumeActiveController() {
    final activeId = _videos[_currentPage]['id']?.toString();
    if (activeId != null) {
      _playOnlyActiveController(activeId);
    }
  }

  // Tính toán phạm vi preload dựa trên tốc độ cuộn
  int _getPreloadRange() {
    final absVelocity = _scrollVelocity.abs();
    if (_networkSpeedMbps != null && _networkSpeedMbps! < 1) return 0;
    if (absVelocity < 300) return 3;
    if (absVelocity < 1000) return 1;
    return 0;
  }

  void _playOnlyActiveController(String? activeId) {
    _controllerCache.forEach((id, controller) {
      if (id == activeId && controller.value.isInitialized) {
        if (!controller.value.isPlaying) {
          controller.play();
        }
      } else {
        if (controller.value.isPlaying) {
          controller.pause();
        }
      }
    });
  }
}

class TikTokVideoItem extends StatefulWidget {
  final Map<String, dynamic> video;
  final bool isActive;
  final VideoPlayerController? controller;
  final Map<String, dynamic>? meta;
  final VoidCallback? preload;
  final ImageProvider? thumbProvider;
  final bool showLoading;

  const TikTokVideoItem({
    super.key,
    required this.video,
    required this.isActive,
    this.controller,
    this.meta,
    this.preload,
    this.thumbProvider,
    this.showLoading = false,
  });

  @override
  State<TikTokVideoItem> createState() => _TikTokVideoItemState();
}

class _TikTokVideoItemState extends State<TikTokVideoItem>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final id = widget.video['id']?.toString() ?? '';
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.controller != null && !widget.controller!.value.hasError)
          RepaintBoundary(
            child: AppVideo(
              key: ValueKey('video-$id-${widget.isActive}'),
              controller: widget.controller!,
              thumbnail: widget.thumbProvider,
              isActive: widget.isActive,
            ),
          )
        else
          Positioned.fill(
            child: Stack(
              children: [
                if (widget.thumbProvider != null)
                  Image(
                    image: widget.thumbProvider!,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    height: double.infinity,
                  ),
                const Center(child: CircularProgressIndicator()),
              ],
            ),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: RepaintBoundary(child: VideoInfoOverlay(meta: widget.meta)),
        ),
      ],
    );
  }
}

class VideoInfoOverlay extends StatelessWidget {
  final Map<String, dynamic>? meta;

  const VideoInfoOverlay({super.key, this.meta});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black54, Colors.black87],
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundImage:
                          meta?['avatar'] != null
                              ? NetworkImage(meta?['avatar'])
                              : null,
                      backgroundColor: Colors.grey[700],
                    ),
                    const SizedBox(width: 8),
                    Text(
                      meta?['author']?.toString() ?? 'User',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.redAccent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Text(
                        'Follow',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  meta?['title']?.toString() ?? '',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
                if (meta?['description']?.toString().isNotEmpty ?? false)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      meta?['description']?.toString() ?? '',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                const SizedBox(height: 12),
              ],
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildAction(Icons.favorite, meta?['likeCount'], 'Like'),
              const SizedBox(height: 18),
              _buildAction(Icons.comment, meta?['commentCount'], 'Comment'),
              const SizedBox(height: 18),
              _buildAction(Icons.share, meta?['shareCount'], 'Share'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAction(IconData icon, dynamic count, String label) {
    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.black45,
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.all(8),
          child: Icon(icon, color: Colors.white, size: 32),
        ),
        const SizedBox(height: 4),
        Text(
          '${count ?? 0}',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
      ],
    );
  }
}

class Skeleton extends StatelessWidget {
  const Skeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(color: Colors.black12),
    );
  }
}

class LruImageCache {
  final int maxSize;
  final _cache = <String, ImageProvider>{};
  final _order = <String>[];

  LruImageCache(this.maxSize);

  ImageProvider? operator [](String key) => _cache[key];

  void put(String key, ImageProvider value) {
    if (_cache.containsKey(key)) {
      _order.remove(key);
    } else if (_cache.length >= maxSize) {
      final removeKey = _order.removeLast();
      _cache.remove(removeKey);
    }
    _cache[key] = value;
    _order.insert(0, key);
  }

  void keepOnly(Set<String> keys) {
    _cache.removeWhere((k, v) => !keys.contains(k));
    _order.removeWhere((k) => !_cache.containsKey(k));
  }
}
