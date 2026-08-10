import 'dart:io' show Platform;
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
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
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

  final prefs = await SharedPreferences.getInstance();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeViewModel(prefs)),
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
    ),
  );
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