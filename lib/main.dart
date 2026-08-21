import 'dart:async';
import 'dart:io' show Platform, File, FileMode;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'viewmodels/data_entry_viewmodel.dart';
import 'viewmodels/allocator_viewmodel.dart';
import 'viewmodels/backend_viewmodel.dart';
import 'viewmodels/settings_viewmodel.dart';
import 'viewmodels/theme_viewmodel.dart';
import 'views/screens/dashboard_screen.dart';
import 'views/screens/login_screen.dart';
import 'app_theme.dart';
import 'viewmodels/auth_viewmodel.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'views/screens/splash_screen.dart';

// Writes crashes to a log file next to the .exe so a silent close on a
// machine we can't debug in person still leaves a trace to read back.
void _logCrash(Object error, StackTrace stack) {
  try {
    final logFile = File('${File(Platform.resolvedExecutable).parent.path}\\crash_log.txt');
    logFile.writeAsStringSync(
      '\n[${DateTime.now()}] $error\n$stack\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {
    // Logging itself must never throw and mask the original crash.
  }
}

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (details) {
      _logCrash(details.exception, details.stack ?? StackTrace.current);
      FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      _logCrash(error, stack);
      return true;
    };

    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      await windowManager.ensureInitialized();
      WindowOptions windowOptions = const WindowOptions(
        size: Size(1280, 800),
        minimumSize: Size(1024, 768),
        center: true,
        backgroundColor: Color(0xFF0B1120), // dark navy — matches app bg, keeps buttons visible
        skipTaskbar: false,
        titleBarStyle: TitleBarStyle.normal,
        title: 'Timetable Maker',
      );
      windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
        await windowManager.setMinimizable(true);
        await windowManager.setMaximizable(true);
        await windowManager.setResizable(true);
      });
    }

    // Renders the splash immediately; _AppRoot itself does the Firebase/prefs
    // boot work and drives the splash's progress bar from real step
    // completion instead of a fixed timer.
    runApp(const _AppRoot());
  }, (error, stack) => _logCrash(error, stack));
}

class _AppRoot extends StatefulWidget {
  const _AppRoot();
  @override
  State<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<_AppRoot> {
  double _progress = 0.0;
  String _status = 'Starting…';
  String? _firebaseError;
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final started = DateTime.now();

    setState(() {
      _status = 'Connecting to Firebase…';
      _progress = 0.15;
    });
    try {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    } catch (e, st) {
      _logCrash(e, st);
      _firebaseError = e.toString();
    }
    if (!mounted) return;

    setState(() {
      _status = 'Loading preferences…';
      _progress = 0.65;
    });
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    // Keep the splash up a minimum stretch so the entrance animation and the
    // 100% state are actually visible even when boot finishes instantly.
    final elapsed = DateTime.now().difference(started);
    const minDisplay = Duration(milliseconds: 900);
    if (elapsed < minDisplay) {
      await Future.delayed(minDisplay - elapsed);
    }
    if (!mounted) return;

    setState(() {
      _prefs = prefs;
      _status = 'Ready';
      _progress = 1.0;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_firebaseError != null) {
      // Without Firebase, Auth/Firestore calls later would throw again
      // anyway — show the real reason instead of letting the window vanish.
      return _StartupErrorApp(message: _firebaseError!);
    }
    if (_prefs == null) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: SplashScreen(progress: _progress, status: _status),
      );
    }
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeViewModel(_prefs!)),
        ChangeNotifierProvider(create: (_) => SettingsViewModel()),
        // DataEntryViewModel receives Friday settings automatically via applySettings
        ChangeNotifierProxyProvider<SettingsViewModel, DataEntryViewModel>(
          create: (_) => DataEntryViewModel(),
          update: (_, settings, dataVm) {
            dataVm!.applySettings(settings);
            return dataVm;
          },
        ),
        ChangeNotifierProvider(create: (_) => AllocatorViewModel()),
        ChangeNotifierProvider(create: (_) => BackendViewModel()),
        ChangeNotifierProvider(create: (_) => AuthViewModel()),
      ],
      child: const TimetableMakerApp(),
    );
  }
}

class TimetableMakerApp extends StatelessWidget {
  const TimetableMakerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeVm = context.watch<ThemeViewModel>();
    return MaterialApp(
      title: 'Timetable Maker',
      debugShowCheckedModeBanner: false,
      themeMode: themeVm.themeMode,
      theme:     AppTheme.lightTheme(context),
      darkTheme: AppTheme.darkTheme(context),
      // Zero-duration so body + cards switch simultaneously — no staggered flash
      themeAnimationDuration: Duration.zero,
      themeAnimationCurve: Curves.linear,
      home: const AuthWrapper(),
    );
  }
}

class _StartupErrorApp extends StatelessWidget {
  final String message;
  const _StartupErrorApp({required this.message});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF0B1120),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.wifi_off_rounded, color: Colors.white, size: 48),
                const SizedBox(height: 16),
                const Text('Could not connect to Firebase',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text('Check your internet connection, then restart the app.',
                    style: TextStyle(color: Colors.white70), textAlign: TextAlign.center),
                const SizedBox(height: 16),
                Text(message, style: const TextStyle(color: Colors.white38, fontSize: 12), textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});
  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final authVm = context.watch<AuthViewModel>();
    if (authVm.status == AuthStatus.authenticated && !_loaded) {
      _loaded = true;
      // reloadForUser() clears ALL in-memory data first, then subscribes
      // to the correct per-user Firestore path. This ensures no data leaks
      // between accounts even if the same ViewModel instance is reused.
      // Deferred to a post-frame callback: reloadForUser() calls
      // notifyListeners() synchronously (to clear the UI immediately), and
      // didChangeDependencies() can run during the build phase — calling it
      // inline here throws "setState() or markNeedsBuild() called during
      // build" on every login/hot-reload, which was silently aborting that
      // frame's rebuild.
      final dataVm     = context.read<DataEntryViewModel>();
      final allocVm    = context.read<AllocatorViewModel>();
      final settingsVm = context.read<SettingsViewModel>();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.wait([
          dataVm.reloadForUser(),
          allocVm.reloadForUser(),
          settingsVm.reloadForUser(),
        ]);
      });
    } else if (authVm.status != AuthStatus.authenticated) {
      if (_loaded) {
        // Immediately wipe in-memory state on sign-out so the login screen
        // never briefly shows the previous user's data.
        context.read<SettingsViewModel>().clearData();
        // DataEntryViewModel and AllocatorViewModel clear on their next
        // reloadForUser() call when the next user logs in.
      }
      _loaded = false; // reset so next login reloads
    }
  }

  @override
  Widget build(BuildContext context) {
    final authVm = context.watch<AuthViewModel>();
    if (authVm.status == AuthStatus.authenticated) {
      return const DashboardScreen();
    }
    return const LoginScreen();
  }
}