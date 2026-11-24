import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 站点配置。
/// 原主域 huangguoai.com 已失效（DNS 指向 199.59.150.39 / face:b00c:0:25de），
/// 默认改用仍可用的备用域，省掉首页每次 10 秒超时空等。
///
/// 这类站点换域名是常态，所以地址不再写成编译期常量：App 内「设置」页可以改，
/// 值存在 SharedPreferences 的 kBaseKey 里，重启后仍然生效。
const String kDefaultBase = 'https://ctb09.ir95e08v.cc';
const String kBaseKey = 'custom_base_url';

/// 当前生效的站点根地址，启动时由 loadBaseOverride() 覆盖。
String gBase = kDefaultBase;

/// 归一化用户输入的地址：补协议、去尾部斜杠。
String normalizeBase(String raw) {
  String s = raw.trim();
  if (s.isEmpty) return kDefaultBase;
  if (!s.startsWith('http://') && !s.startsWith('https://')) {
    s = 'https://' + s;
  }
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// 启动时读取用户保存的域名；读不到就用默认值，不影响启动。
Future<void> loadBaseOverride() async {
  try {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String saved = (prefs.getString(kBaseKey) ?? '').trim();
    if (saved.isNotEmpty) gBase = normalizeBase(saved);
  } catch (_) {
    // 配置损坏时静默回退默认域名。
  }
}

/// 保存域名；传空串表示恢复默认。
Future<void> saveBaseOverride(String raw) async {
  final String v = raw.trim();
  gBase = v.isEmpty ? kDefaultBase : normalizeBase(v);
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  if (v.isEmpty) {
    await prefs.remove(kBaseKey);
  } else {
    await prefs.setString(kBaseKey, gBase);
  }
}
const String kUserAgent =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1';

const int kHttpTimeout = 12;
const String kAppVer = 'v1.2a';

int intOf(dynamic v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(strOf(v)) ?? fallback;
}

double dblOf(dynamic v, [double fallback = 0]) {
  if (v is num) return v.toDouble();
  return double.tryParse(strOf(v)) ?? fallback;
}

String strOf(dynamic v) => v == null ? '' : v.toString();

/// GET 一个 JSON 接口，返回 body 里的 data 映射；失败返回 null。
Future<Map<String, dynamic>?> fetchApi(
  String path, [
  Map<String, String>? query,
]) async {
  try {
    final Uri uri = Uri.parse(gBase + path).replace(
      queryParameters: (query == null || query.isEmpty) ? null : query,
    );
    final http.Response res = await http.get(
      uri,
      headers: <String, String>{
        'Accept': 'application/json',
        'User-Agent': kUserAgent,
        'Referer': gBase + '/',
      },
    ).timeout(const Duration(seconds: kHttpTimeout));
    if (res.statusCode != 200) return null;
    // 服务端没声明 charset 时 http 包会按 latin1 解码，中文会乱码，必须走 bodyBytes。
    final dynamic decoded = json.decode(
      utf8.decode(res.bodyBytes, allowMalformed: true),
    );
    if (decoded is! Map) return null;
    if (intOf(decoded['status']) != 1) return null;
    final dynamic data = decoded['data'];
    if (data is Map) return Map<String, dynamic>.from(data);
    return null;
  } catch (_) {
    return null;
  }
}

/// 图片 CDN（七牛）与视频域用的是较新的根证书，旧 Android 系统根库里没有，
/// 表现就是「浏览器能看图、App 一片灰」。这里只对自家域名放宽校验。
class LenientHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..badCertificateCallback = (X509Certificate cert, String host, int port) {
        const List<String> allow = <String>[
          'qnlycc.cn',
          'tjyyjk.cn',
          'ir95e08v.cc',
          'huangguoai.com',
        ];
        for (final String d in allow) {
          if (host == d || host.endsWith('.' + d)) return true;
        }
        return false;
      };
  }
}

/// 封面图是 AES-128-CBC 加密的二进制，协议在站点 crypto-image-protocol.js 里公开：
///   window.CryptoImageProtocol = { decryptKey: 'f5d965df75336270', decryptIV: '97b60394abc2fbe1' }
/// 直接 HTTP 拿到的不是 JPEG（首字节随机），浏览器也要先解密再塞 blob，所以
/// Image.network 必然报 Invalid image data。这里按同一协议解出明文再渲染。
const String kImgKey = 'f5d965df75336270';
const String kImgIv = '97b60394abc2fbe1';

final Map<String, Uint8List> _coverCache = <String, Uint8List>{};

/// 判断下载到的是不是已经解密的图片。
bool looksLikeImage(Uint8List b) {
  if (b.length < 12) return false;
  if (b[0] == 0xFF && b[1] == 0xD8) return true; // jpeg
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return true; // png
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return true; // gif
  if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46) return true; // riff/webp
  if (b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70) return true; // ftyp/heif
  if (b[0] == 0x42 && b[1] == 0x4D) return true; // bmp
  return false;
}

/// AES-128-CBC + PKCS7 解密；密钥与 IV 都是 16 个 ASCII 字符。
Uint8List aesDecrypt(Uint8List data) {
  try {
    final int len = data.length - (data.length % 16);
    if (len <= 0) return data;
    final Uint8List key = Uint8List.fromList(kImgKey.codeUnits);
    final Uint8List iv = Uint8List.fromList(kImgIv.codeUnits);
    final pc.CBCBlockCipher cipher = pc.CBCBlockCipher(pc.AESEngine());
    cipher.init(
      false,
      pc.ParametersWithIV<pc.KeyParameter>(pc.KeyParameter(key), iv),
    );
    final Uint8List out = Uint8List(len);
    for (int off = 0; off < len; off += 16) {
      cipher.processBlock(data, off, out, off);
    }
    int pad = out[len - 1];
    if (pad < 1 || pad > 16) pad = 0;
    if (pad > len) pad = 0;
    return Uint8List.sublistView(out, 0, len - pad);
  } catch (_) {
    return data;
  }
}

/// 拉一张封面：直连 -> 识别 -> 需要时解密 -> 内存缓存。
Future<Uint8List?> fetchCover(String url) async {
  if (url.isEmpty) return null;
  final Uint8List? hit = _coverCache[url];
  if (hit != null) return hit;
  final String u = url.startsWith('http') ? url : gBase + url;
  try {
    final HttpClient client = HttpClient();
    client.connectionTimeout = const Duration(seconds: kHttpTimeout);
    final HttpClientRequest req = await client.getUrl(Uri.parse(u));
    req.headers.set('User-Agent', kUserAgent);
    req.headers.set('Referer', gBase + '/');
    final HttpClientResponse res = await req.close();
    if (res.statusCode != 200) {
      client.close();
      return null;
    }
    final List<int> buf = <int>[];
    await for (final List<int> chunk in res) {
      buf.addAll(chunk);
    }
    client.close();
    Uint8List bytes = Uint8List.fromList(buf);
    if (bytes.isEmpty) return null;
    if (!looksLikeImage(bytes)) bytes = aesDecrypt(bytes);
    if (bytes.isEmpty) return null;
    if (_coverCache.length > 150) _coverCache.clear();
    _coverCache[url] = bytes;
    return bytes;
  } catch (_) {
    return null;
  }
}

class CoverImage extends StatefulWidget {
  const CoverImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.placeholder,
  });

  final String url;
  final BoxFit fit;
  final double? width;
  final Widget? placeholder;

  @override
  State<CoverImage> createState() => CoverImageState();
}

class CoverImageState extends State<CoverImage> {
  Future<Uint8List?>? _fut;

  @override
  void initState() {
    super.initState();
    _fut = fetchCover(widget.url);
  }

  @override
  void didUpdateWidget(CoverImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _fut = fetchCover(widget.url);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _fut,
      builder: (BuildContext c, AsyncSnapshot<Uint8List?> s) {
        final Uint8List? b = s.data;
        if (b != null && b.isNotEmpty) {
          return Image.memory(
            b,
            width: widget.width ?? double.infinity,
            fit: widget.fit,
            gaplessPlayback: true,
            errorBuilder: (BuildContext c2, Object e, StackTrace? st) {
              return Container(
                color: Colors.grey[850],
                child: Center(
                  child: widget.placeholder ?? const Icon(Icons.movie),
                ),
              );
            },
          );
        }
        final bool done = s.connectionState == ConnectionState.done;
        return Container(
          color: Colors.grey[850],
          child: Center(
            child: done
                ? (widget.placeholder ??
                    const Icon(Icons.movie, color: Colors.white38))
                : const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
          ),
        );
      },
    );
  }
}

Map<String, String> imgHeaders() {
  return <String, String>{
    'User-Agent': kUserAgent,
    'Referer': gBase + '/',
  };
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  HttpOverrides.global = LenientHttpOverrides();
  await loadBaseOverride();
  runApp(const HuangguoVIPApp());
}

class HuangguoVIPApp extends StatelessWidget {
  const HuangguoVIPApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '黄果短剧',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.amber),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const HomePage(),
    );
  }
}

// ---------------------------------------------------------------------------
// 首页
// ---------------------------------------------------------------------------

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int _page = 1;
  int _pages = 1;
  int _total = 0;
  String _filterStatus = 'all';
  String _filterSort = 'hot';
  bool _isVIP = true;

  @override
  void initState() {
    super.initState();
    _loadVip();
    _load(reset: true);
  }

  Future<void> _loadVip() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _isVIP = prefs.getBool('isVIP') ?? true);
  }

  Future<void> _load({bool reset = false, bool more = false}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
        _page = 1;
        _items.clear();
      });
    } else if (more) {
      setState(() => _loadingMore = true);
    }

    final Map<String, String> query = <String, String>{'page': _page.toString()};
    if (_filterSort == 'hot' || _filterSort == 'new') {
      query['sort'] = _filterSort;
    }
    if (_filterStatus == 'completed') query['is_finished'] = '1';
    if (_filterStatus == 'unfinished') query['is_finished'] = '0';

    final Map<String, dynamic>? data = await fetchApi('/api/videos', query);
    if (!mounted) return;

    if (data == null) {
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = '接口无响应：检查网络，或站点已更换域名';
      });
      return;
    }

    final dynamic rawItems = data['items'];
    final List<dynamic> items = rawItems is List ? rawItems : const <dynamic>[];
    final dynamic pg = data['pagination'];
    final Map<dynamic, dynamic> pgMap =
        pg is Map ? pg : const <dynamic, dynamic>{};

    setState(() {
      for (final dynamic raw in items) {
        if (raw is Map) {
          _items.add(Map<String, dynamic>.from(raw));
        }
      }
      _pages = intOf(pgMap['pages'], 1);
      _total = intOf(pgMap['total'], _items.length);
      _loading = false;
      _loadingMore = false;
      _error = null;
    });
  }

  void _nextPage() {
    if (_loadingMore || _page >= _pages) return;
    _page += 1;
    _load(more: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: <Widget>[
            Text('黄果短剧 ' + kAppVer),
            if (_isVIP)
              Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.amber,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'VIP',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            const SizedBox(width: 8),
            if (_total > 0)
              Text(
                _total.toString() + ' 部',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
          ],
        ),
        actions: <Widget>[
          IconButton(
            tooltip: '筛选',
            icon: const Icon(Icons.filter_list),
            onPressed: _showFilterDialog,
          ),
          IconButton(
            tooltip: '观看历史',
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (BuildContext ctx) => const HistoryPage(),
              ),
            ),
          ),
          IconButton(
            tooltip: '设置站点地址',
            icon: const Icon(Icons.settings),
            onPressed: () async {
              final dynamic changed = await Navigator.push<dynamic>(
                context,
                MaterialPageRoute<dynamic>(
                  builder: (BuildContext ctx) => const SettingsPage(),
                ),
              );
              if (changed == true) {
                _load(reset: true);
              }
            },
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.wifi_off, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => _load(reset: true),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: GridView.builder(
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: 3 / 4.6,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        itemCount: _items.length + 1,
        itemBuilder: (BuildContext ctx, int index) {
          if (index == _items.length) return _buildFooter();
          final Map<String, dynamic> drama = _items[index];
          return DramaCard(
            drama: drama,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (BuildContext c) =>
                    DetailPage(dramaId: intOf(drama['id'])),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildFooter() {
    if (_page >= _pages) {
      return const Center(
        child: Text('没有更多了', style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }
    if (_loadingMore) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return Center(
      child: ElevatedButton(
        onPressed: _nextPage,
        child: Text('加载更多 ' + _page.toString() + '/' + _pages.toString()),
      ),
    );
  }

  void _showFilterDialog() {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('筛选条件'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('状态'),
            Wrap(
              spacing: 8,
              children: <Widget>[
                ChoiceChip(
                  label: const Text('全部'),
                  selected: _filterStatus == 'all',
                  onSelected: (_) => setState(() => _filterStatus = 'all'),
                ),
                ChoiceChip(
                  label: const Text('已完结'),
                  selected: _filterStatus == 'completed',
                  onSelected: (_) => setState(() => _filterStatus = 'completed'),
                ),
                ChoiceChip(
                  label: const Text('连载中'),
                  selected: _filterStatus == 'unfinished',
                  onSelected: (_) =>
                      setState(() => _filterStatus = 'unfinished'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('排序'),
            Wrap(
              spacing: 8,
              children: <Widget>[
                ChoiceChip(
                  label: const Text('热门'),
                  selected: _filterSort == 'hot',
                  onSelected: (_) => setState(() => _filterSort = 'hot'),
                ),
                ChoiceChip(
                  label: const Text('最新'),
                  selected: _filterSort == 'new',
                  onSelected: (_) => setState(() => _filterSort = 'new'),
                ),
              ],
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _load(reset: true);
            },
            child: const Text('应用'),
          ),
        ],
      ),
    );
  }
}

class DramaCard extends StatelessWidget {
  const DramaCard({super.key, required this.drama, required this.onTap});

  final Map<String, dynamic> drama;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final String cover = strOf(drama['cover']);
    final int episodes = intOf(drama['episode_count'], 1);
    final bool finished =
        drama['is_finished'] == true || intOf(drama['is_finished']) == 1;
    final String scoreText = dblOf(drama['score']).toStringAsFixed(1);
    final String epText =
        (finished ? '全' : '更新至') + episodes.toString() + '集';

    return GestureDetector(
      onTap: onTap,
      child: Card(
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: CoverImage(
                url: cover,
                width: double.infinity,
                fit: BoxFit.cover,
                placeholder: const Icon(Icons.movie),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    strOf(drama['title']),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: <Widget>[
                      Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.amber,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          scoreText,
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.black,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          epText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 10, color: Colors.grey),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 详情页：直接走 JSON 接口，不再解析 HTML
// ---------------------------------------------------------------------------

class DetailPage extends StatefulWidget {
  const DetailPage({super.key, required this.dramaId});

  final int dramaId;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  Map<String, dynamic>? _data;
  List<int> _episodes = <int>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final Map<String, dynamic>? data =
        await fetchApi('/api/videos/' + widget.dramaId.toString());
    if (!mounted) return;

    if (data == null) {
      setState(() {
        _loading = false;
        _error = '详情加载失败：接口无响应，或该剧已下架';
      });
      return;
    }

    final dynamic rawEps = data['episodes'];
    final List<int> eps = <int>[];
    if (rawEps is List) {
      for (final dynamic e in rawEps) {
        if (e is Map) {
          final int n = intOf(e['ep_num']);
          if (n > 0) eps.add(n);
        }
      }
    }
    eps.sort();
    if (eps.isEmpty) {
      final int totalEp =
          intOf(data['total_episodes'], intOf(data['episode_count'], 1));
      for (int i = 1; i <= totalEp; i++) {
        eps.add(i);
      }
    }

    setState(() {
      _data = data;
      _episodes = eps;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? d = _data;
    return Scaffold(
      appBar: AppBar(title: Text(d == null ? '加载中...' : strOf(d['title']))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : d == null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(_error ?? '加载失败'),
                      const SizedBox(height: 12),
                      ElevatedButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : _buildDetail(d),
    );
  }

  Widget _buildDetail(Map<String, dynamic> d) {
    final String title = strOf(d['title']);
    final String cover = strOf(d['cover']);
    final int totalEp = intOf(d['total_episodes'], _episodes.length);
    final String scoreText = dblOf(d['score']).toStringAsFixed(1);
    final bool finished = d['is_finished'] == true;
    final String authorName =
        d['author'] is Map ? strOf((d['author'] as Map)['name']) : '';
    final List<dynamic> tags =
        d['tags'] is List ? d['tags'] as List<dynamic> : const <dynamic>[];

    return RefreshIndicator(
      onRefresh: () => _load(),
      child: ListView(
        padding: EdgeInsets.zero,
        children: <Widget>[
          AspectRatio(
            aspectRatio: 16 / 9,
            child: CoverImage(url: cover, fit: BoxFit.cover),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Text(
                      finished ? '已完结' : '连载中',
                      style: const TextStyle(color: Colors.amber),
                    ),
                    const SizedBox(width: 16),
                    Text('全' + totalEp.toString() + '集'),
                    const SizedBox(width: 16),
                    Text(scoreText + ' 分'),
                  ],
                ),
                if (authorName.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '作者：' + authorName,
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: tags
                      .map(
                        (dynamic tag) => Chip(
                          label: Text(strOf(tag)),
                          backgroundColor: Colors.amber.withOpacity(0.2),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 16),
                Text(
                  strOf(d['description']),
                  style: const TextStyle(height: 1.5),
                ),
                const SizedBox(height: 24),
                Text(
                  '剧集列表（' + _episodes.length.toString() + '）',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _episodes
                      .map(
                        (int ep) => ElevatedButton(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (BuildContext c) => PlayerPage(
                                dramaId: widget.dramaId,
                                episode: ep,
                                dramaTitle: title,
                              ),
                            ),
                          ),
                          child: Text('第' + ep.toString() + '集'),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 播放页：WebView 跑完站点 JS 取真实地址；取不到就退化为网页内播放
// ---------------------------------------------------------------------------

enum PlayMode { resolving, native, web }

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.dramaId,
    required this.episode,
    required this.dramaTitle,
  });

  final int dramaId;
  final int episode;
  final String dramaTitle;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  static const String _jsTemplate = '''
(function () {
  try {
    function collect() {
      try {
        var ps = document.querySelectorAll('video');
        for (var p = 0; p < ps.length; p++) {
          try { ps[p].click(); } catch (e1) {}
          try { ps[p].muted = true; ps[p].play(); } catch (e2) {}
        }
        var bs = document.querySelectorAll('[class*="play-btn"], [class*="playBtn"], .xgplayer-start');
        for (var b = 0; b < bs.length && b < 2; b++) {
          try { bs[b].click(); } catch (e3) {}
        }
      } catch (e0) {}
      var urls = [];
      var vs = document.querySelectorAll('video');
      for (var i = 0; i < vs.length; i++) {
        var s = vs[i].getAttribute('src');
        if (s) urls.push(s);
        var ss = vs[i].querySelectorAll('source');
        for (var j = 0; j < ss.length; j++) {
          var u = ss[j].getAttribute('src');
          if (u) urls.push(u);
        }
      }
      for (var k = 0; k < urls.length; k++) {
        if (urls[k].indexOf('http') === 0) return urls[k];
      }
      try {
        var rs = performance.getEntriesByType('resource');
        for (var q = 0; q < rs.length; q++) {
          var nm = rs[q].name || '';
          if (nm.indexOf('.m3u8') >= 0 && nm.indexOf('http') === 0) return nm;
        }
      } catch (e) {}
      var html = document.documentElement.outerHTML || '';
      var at = html.indexOf('.m3u8');
      if (at > 0) {
        var start = html.lastIndexOf('http', at);
        var end = at + 5;
        var stop = ['"', "'", ' ', '>', '<'];
        while (end < html.length && stop.indexOf(html.charAt(end)) < 0) end++;
        var cut = html.substring(start, end).split('&amp;').join('&');
        if (cut.indexOf('http') === 0) return cut;
      }
      var el = document.getElementById('videoInitialData');
      if (el) {
        try {
          var d = JSON.parse(el.textContent || '');
          var srcs = d.epPlaySrcs || (d.data && d.data.epPlaySrcs);
          if (srcs) {
            var ks = Object.keys(srcs);
            for (var m = 0; m < ks.length; m++) {
              var v = srcs[ks[m]];
              if (v && typeof v === 'object') v = v.url || v.src || v.m3u8;
              if (typeof v === 'string' && v.indexOf('http') === 0) return v;
            }
          }
        } catch (e) {}
      }
      return '';
    }
    return collect();
  } catch (e) { return ''; }
})()
''';

  late final WebViewController _web;
  VideoPlayerController? _video;
  Player? _mp;
  VideoController? _vc;
  PlayMode _mode = PlayMode.resolving;
  bool _resolved = false;
  String? _hint;
  Timer? _timeout;
  Timer? _progress;
  int _tries = 0;
  String _diag = '';

  @override
  void initState() {
    super.initState();

    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(kUserAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            if (mounted) {
              setState(() {
                _diag = '页面开始加载';
              });
            }
          },
          onPageFinished: (String url) async {
            for (int i = 0; i < 12; i++) {
              await _tryExtract();
              if (_resolved) return;
              await Future<void>.delayed(const Duration(milliseconds: 1600));
            }
            if (!_resolved && mounted) {
              await _noteDiag('12 次重试均失败');
            }
          },
          onWebResourceError: (WebResourceError error) {
            if (!mounted || _resolved) return;
            setState(() => _hint = '网页加载异常：' + error.description);
          },
        ),
      )
      ..loadRequest(
        Uri.parse(
          gBase +
              '/video/' +
              widget.dramaId.toString() +
              '/ep-' +
              widget.episode.toString() +
              '/',
        ),
      );

    _timeout = Timer(const Duration(seconds: 30), () {
      _fallbackToWeb('30 秒内未取到播放地址');
    });
  }

  String get _extractJs => _jsTemplate;

  /// WebView 桥的返回值可能带一层 JSON 引号与转义，统一还原成原始文本。
  String _unwrapRaw(Object raw) {
    final String t = raw.toString().trim();
    if (t.isEmpty) return '';
    try {
      final dynamic d = json.decode(t);
      if (d is String) return d;
      if (d is Map || d is List) return t;
    } catch (_) {}
    return t;
  }

  /// 从 epPlaySrcs 里挑出本集地址。
  /// 兼容 Map（键从 1 起或从 0 起）、List、单一 URL、以及值是对象的情况。
  String _pickUrl(dynamic srcs, int ep) {
    dynamic v;
    if (srcs is Map) {
      final List<String> keys = <String>[
        ep.toString(),
        (ep - 1).toString(),
        '0' + ep.toString(),
        (ep + 1).toString(),
      ];
      for (final String k in keys) {
        if (srcs.containsKey(k) && srcs[k] != null) {
          v = srcs[k];
          break;
        }
      }
      if (v == null && srcs.isNotEmpty) {
        for (final dynamic k in srcs.keys) {
          if (k.toString() == ep.toString()) {
            v = srcs[k];
            break;
          }
        }
      }
    } else if (srcs is List) {
      if (ep - 1 >= 0 && ep - 1 < srcs.length) v = srcs[ep - 1];
      if (v == null && ep < srcs.length) v = srcs[ep];
    } else if (srcs is String) {
      v = srcs;
    }
    if (v is Map) {
      v = v['url'] ?? v['src'] ?? v['play_url'] ?? v['m3u8'];
    }
    final String s = v == null ? '' : v.toString();
    return s.startsWith('http') ? s : '';
  }

  Future<void> _tryExtract() async {
    if (_resolved || !mounted) return;
    _tries += 1;
    try {
      final Object raw = await _web.runJavaScriptReturningResult(_extractJs);
      final String text = _unwrapRaw(raw);
      if (text.isEmpty) {
        await _noteDiag('第 ' + _tries.toString() + ' 次：页面没有给出地址');
        return;
      }
      if (text.startsWith('http')) {
        _resolved = true;
        await _playNative(text);
        return;
      }
      dynamic parsed;
      try {
        parsed = json.decode(text);
      } catch (_) {
        parsed = text;
      }
      final String url = _pickUrl(parsed, widget.episode);
      if (url.isEmpty) {
        await _noteDiag('第 ' + _tries.toString() + ' 次：返回了但挑不出本集地址');
        return;
      }
      _resolved = true;
      await _playNative(url);
    } catch (e) {
      final String m = e.toString();
      final int cut = m.indexOf('\n');
      await _noteDiag(
        '第 ' + _tries.toString() + ' 次异常：' + (cut > 0 ? m.substring(0, cut) : m),
      );
    }
  }

  /// 记录一次失败现场：页面标题、video/source 数量、videoInitialData 里几集有源。
  Future<void> _noteDiag(String head) async {
    final String probe = await _probePage();
    if (!mounted) return;
    setState(() {
      _diag = head + '｜' + probe;
    });
  }

  Future<String> _probePage() async {
    const String js = '''
(function () {
  try {
    var t = (document.title || '').slice(0, 24);
    var v = document.querySelectorAll('video').length;
    var s = document.querySelectorAll('source').length;
    var n = -1;
    var el = document.getElementById('videoInitialData');
    if (el && el.textContent) {
      var d = JSON.parse(el.textContent);
      if (d.epPlaySrcs) n = Object.keys(d.epPlaySrcs).length;
    }
    var html = document.documentElement.outerHTML || '';
    var hit = html.indexOf('.m3u8') >= 0 ? 1 : 0;
    return 'title=' + t + ' video=' + v + ' source=' + s + ' eps=' + n + ' htmlM3u8=' + hit;
  } catch (e) {
    return 'probe-error ' + e;
  }
})()
''';
    try {
      final Object raw = await _web.runJavaScriptReturningResult(js);
      return _unwrapRaw(raw);
    } catch (e) {
      return 'probe-fail';
    }
  }

  /// 优先用 libmpv 播（软解 HEVC，规避 ExoPlayer 在部分机型上的
  /// MediaCodecVideoRenderer 失败），拿不到画面再退回系统播放器。
  Future<void> _playNative(String url) async {
    final bool ok = await _playMpv(url);
    if (ok) return;
    await _playNativeVp(url);
  }

  Future<bool> _playMpv(String url) async {
    Player? p;
    try {
      p = Player();
      final VideoController c = VideoController(p);
      await p.open(
        Media(
          url,
          httpHeaders: <String, String>{
            'User-Agent': kUserAgent,
            'Referer': gBase + '/',
          },
        ),
        play: true,
      );
      final Stopwatch sw = Stopwatch()..start();
      while (sw.elapsed < const Duration(seconds: 10)) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        if (p.state.error.isNotEmpty) break;
        if (p.state.width > 0) break;
        if (!mounted) break;
      }
      if (p.state.error.isNotEmpty || p.state.width <= 0) {
        await p.dispose();
        return false;
      }
      if (!mounted) {
        await p.dispose();
        return false;
      }
      setState(() {
        _video?.dispose();
        _video = null;
        _mp?.dispose();
        _mp = p;
        _vc = c;
        _mode = PlayMode.native;
        _hint = null;
      });
      _timeout?.cancel();
      return true;
    } catch (e) {
      try {
        await p?.dispose();
      } catch (_) {}
      return false;
    }
  }

  Future<void> _playNativeVp(String url) async {
    final VideoPlayerController controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: <String, String>{
        'User-Agent': kUserAgent,
        'Referer': gBase + '/',
        'Accept': '*/*',
      },
    );
    try {
      await controller.initialize();
    } catch (e) {
      final String m = e.toString();
      final int cut = m.indexOf('\n');
      await controller.dispose();
      _fallbackToWeb('播放器初始化失败：' + (cut > 0 ? m.substring(0, cut) : m));
      return;
    }
    if (!mounted) {
      await controller.dispose();
      return;
    }
    await controller.play();
    await _restoreProgress(controller);

    setState(() {
      _video?.dispose();
      _video = controller;
      _mode = PlayMode.native;
      _hint = null;
    });
    _timeout?.cancel();
    _startProgressTimer();
  }

  Future<void> _restoreProgress(VideoPlayerController controller) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String key = 'progress_' +
          widget.dramaId.toString() +
          '_' +
          widget.episode.toString();
      final double? saved = prefs.getDouble(key);
      if (saved != null && saved > 3) {
        await controller.seekTo(Duration(seconds: saved.toInt()));
      }
    } catch (_) {}
  }

  void _startProgressTimer() {
    _progress?.cancel();
    _progress = Timer.periodic(const Duration(seconds: 5), (Timer t) async {
      final VideoPlayerController? c = _video;
      if (c == null || !c.value.isInitialized) return;
      try {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setDouble(
          'progress_' +
              widget.dramaId.toString() +
              '_' +
              widget.episode.toString(),
          c.value.position.inSeconds.toDouble(),
        );
        await prefs.setInt('last_drama_id', widget.dramaId);
        await prefs.setInt('last_episode', widget.episode);
      } catch (_) {}
    });
  }

  void _fallbackToWeb([String? reason]) {
    _timeout?.cancel();
    if (!mounted || _mode == PlayMode.web) return;
    setState(() {
      _mode = PlayMode.web;
      _hint = reason ?? '未取到播放地址，已切换为网页播放';
    });
  }

  void _switchToWeb() {
    _video?.pause();
    _mp?.pause();
    _fallbackToWeb('已切换为网页播放');
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _progress?.cancel();
    _video?.dispose();
    _mp?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.dramaTitle + ' · 第' + widget.episode.toString() + '集',
        ),
        actions: <Widget>[
          if (_mode == PlayMode.native)
            IconButton(
              tooltip: '改用网页播放',
              icon: const Icon(Icons.language),
              onPressed: _switchToWeb,
            ),
        ],
      ),
      body: IndexedStack(
        index: _mode == PlayMode.web ? 1 : 0,
        children: <Widget>[_buildNativeArea(), _buildWebArea()],
      ),
    );
  }

  Widget _buildNativeArea() {
    if (_vc != null) {
      return Video(controller: _vc!);
    }
    final VideoPlayerController? v = _video;
    if (_mode == PlayMode.resolving || v == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            const Text('正在解析播放源...'),
            if (_hint != null) ...<Widget>[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  _hint!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ],
            if (_diag.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  _diag,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 10, color: Colors.orange),
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => _fallbackToWeb(),
              child: const Text('直接用网页播放'),
            ),
          ],
        ),
      );
    }

    final double ratio =
        v.value.aspectRatio == 0 ? 16 / 9 : v.value.aspectRatio;

    return Column(
      children: <Widget>[
        AspectRatio(aspectRatio: ratio, child: VideoPlayer(v)),
        VideoProgressIndicator(
          v,
          allowScrubbing: true,
          padding: const EdgeInsets.symmetric(vertical: 8),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: <Widget>[
            IconButton(
              icon: const Icon(Icons.replay_10),
              onPressed: () {
                final Duration target =
                    v.value.position - const Duration(seconds: 10);
                v.seekTo(target < Duration.zero ? Duration.zero : target);
              },
            ),
            IconButton(
              iconSize: 44,
              icon: Icon(
                v.value.isPlaying ? Icons.pause_circle : Icons.play_circle,
              ),
              onPressed: () {
                setState(() {
                  if (v.value.isPlaying) {
                    v.pause();
                  } else {
                    v.play();
                  }
                });
              },
            ),
            IconButton(
              icon: const Icon(Icons.forward_10),
              onPressed: () {
                v.seekTo(v.value.position + const Duration(seconds: 10));
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildWebArea() {
    return Column(
      children: <Widget>[
        if (_hint != null)
          Container(
            width: double.infinity,
            color: Colors.amber.withOpacity(0.15),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              _hint!,
              style: const TextStyle(fontSize: 11, color: Colors.amber),
            ),
          ),
        Expanded(child: WebViewWidget(controller: _web)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 观看历史
// ---------------------------------------------------------------------------

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  int? _dramaId;
  int? _episode;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _dramaId = prefs.getInt('last_drama_id');
      _episode = prefs.getInt('last_episode');
    });
  }

  @override
  Widget build(BuildContext context) {
    final int? id = _dramaId;
    final int? ep = _episode;
    final bool empty = id == null || ep == null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('观看历史'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              final SharedPreferences prefs =
                  await SharedPreferences.getInstance();
              await prefs.remove('last_drama_id');
              await prefs.remove('last_episode');
              if (!mounted) return;
              setState(() {
                _dramaId = null;
                _episode = null;
              });
            },
          ),
        ],
      ),
      body: empty
          ? const Center(child: Text('暂无观看历史'))
          : ListView(
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.play_circle_outline),
                  title: Text('短剧 #' + id.toString()),
                  subtitle: Text('看到第 ' + ep.toString() + ' 集'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (BuildContext c) => DetailPage(dramaId: id!),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
// ---------------------------------------------------------------------------
// 设置：站点地址（换域名不用重新打包）
// ---------------------------------------------------------------------------

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _ctrl = TextEditingController(
    text: gBase == kDefaultBase ? '' : gBase,
  );
  bool _testing = false;
  String _testMsg = '';
  bool _testOk = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String get _candidate {
    final String t = _ctrl.text.trim();
    return t.isEmpty ? kDefaultBase : normalizeBase(t);
  }

  Future<void> _test() async {
    final String keep = gBase;
    final String probe = _candidate;
    setState(() {
      _testing = true;
      _testMsg = '';
    });
    // 临时借用 gBase 探测，测完立刻还原，不污染正在用的配置。
    gBase = probe;
    String msg = '';
    bool ok = false;
    try {
      final Map<String, dynamic>? data = await fetchApi(
        '/api/videos',
        <String, String>{'page': '1', 'sort': 'hot'},
      );
      if (data == null) {
        msg = '接口没有返回正常数据（地址写错，或站点已改版）';
      } else {
        final dynamic items = data['items'];
        final int n = items is List ? items.length : 0;
        ok = n > 0;
        msg = ok ? '连通正常，首页能取到 ' + n.toString() + ' 条' : '地址通了，但列表是空的';
      }
    } catch (e) {
      msg = '请求失败：' + e.toString();
    }
    gBase = keep;
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testOk = ok;
      _testMsg = msg;
    });
  }

  Future<void> _save() async {
    await saveBaseOverride(_ctrl.text);
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  Future<void> _reset() async {
    await saveBaseOverride('');
    if (!mounted) return;
    setState(() {
      _ctrl.text = '';
      _testMsg = '';
      _testOk = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          const Text(
            '站点地址',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            '当前使用：' + gBase,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: '新的站点地址',
              hintText: 'https://example.com',
              helperText: '留空表示恢复默认',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _testing ? null : _test,
                  icon: _testing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering),
                  label: Text(_testing ? '测试中...' : '测试连通性'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save),
                  label: const Text('保存'),
                ),
              ),
            ],
          ),
          if (_testMsg.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _testMsg,
                style: TextStyle(
                  fontSize: 13,
                  color: _testOk ? Colors.greenAccent : Colors.redAccent,
                ),
              ),
            ),
          const SizedBox(height: 20),
          TextButton.icon(
            onPressed: _reset,
            icon: const Icon(Icons.restore),
            label: const Text('恢复默认地址'),
          ),
          const Divider(height: 32),
          const Text(
            '说明',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            '原主域 huangguoai.com 已经停止服务，默认走备用域。\n'
            '这类站点换域名很频繁，哪天 App 打不开了，把新地址填进来保存就行，'
            '不用等重新打包。\n'
            '保存后会自动回首页刷新。',
            style: TextStyle(fontSize: 12.5, height: 1.6, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

