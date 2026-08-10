import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:async';

class SettingsViewModel extends ChangeNotifier {
  // Do NOT auto-init in constructor — wait for reloadForUser() after login.
  SettingsViewModel();

  // ── State ─────────────────────────────────────────────────────────────────
  String _backendUrl   = 'http://127.0.0.1:8000';
  int    _workingDays  = 6;
  int    _maxPeriods   = 6;
  int    _gaPop        = 80;
  int    _gaGen        = 300;
  int    _gaStagnation = 40;
  bool   _fridayShortDay  = false;
  int    _fridayMaxPeriod = 3;
  bool   _scheduleLocked  = false;
  bool   _allocRoomDefault = false;

  StreamSubscription? _sub;

  // ── Getters ───────────────────────────────────────────────────────────────
  String get backendUrl     => _backendUrl;
  int    get workingDays    => _workingDays;
  int    get maxPeriods     => _maxPeriods;
  int    get gaPop          => _gaPop;
  int    get gaGen          => _gaGen;
  int    get gaStagnation   => _gaStagnation;
  bool   get fridayShortDay  => _fridayShortDay;
  int    get fridayMaxPeriod => _fridayMaxPeriod;
  bool   get scheduleLocked  => _scheduleLocked;
  bool   get allocRoomDefault => _allocRoomDefault;

  /// Per-user Firestore document — scoped to the logged-in user's UID.
  DocumentReference get _doc {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? 'anonymous';
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('config')
        .doc('settings');
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Called AFTER the user has logged in.
  /// Cancels any previous subscription and starts a new one scoped
  /// to the current user's UID — ensuring settings are fully isolated.
  Future<void> reloadForUser() async {
    _sub?.cancel();
    _sub = _doc.snapshots().listen((snapshot) {
      if (snapshot.exists) {
        final d = snapshot.data() as Map<String, dynamic>;
        _backendUrl     = d['backendUrl']     as String? ?? _backendUrl;
        _workingDays    = ((d['workingDays']  as int?)  ?? _workingDays).clamp(5, 6);
        _maxPeriods     = d['maxPeriods']     as int?   ?? _maxPeriods;
        _gaPop          = d['gaPop']          as int?   ?? _gaPop;
        _gaGen          = d['gaGen']          as int?   ?? _gaGen;
        _gaStagnation   = d['gaStagnation']   as int?   ?? _gaStagnation;
        // Friday Short Day feature removed — stored values intentionally
        // ignored so a stale `true` can't silently block Friday periods.
        _scheduleLocked  = d['scheduleLocked']  as bool? ?? _scheduleLocked;
        _allocRoomDefault = d['allocRoomDefault'] as bool? ?? _allocRoomDefault;
        notifyListeners();
      } else {
        // New user — save defaults to their personal path
        _saveToCloud();
      }
    });
  }

  /// Resets all settings to defaults and cancels the Firestore subscription.
  /// Call this on sign-out so the next user never sees the previous user's settings.
  void clearData() {
    _sub?.cancel();
    _sub = null;
    _backendUrl     = 'http://127.0.0.1:8000';
    _workingDays    = 6;
    _maxPeriods     = 6;
    _gaPop          = 80;
    _gaGen          = 300;
    _gaStagnation   = 40;
    _fridayShortDay  = false;
    _fridayMaxPeriod = 3;
    _scheduleLocked  = false;
    _allocRoomDefault = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _saveToCloud() {
    _doc.set({
      'backendUrl':     _backendUrl,
      'workingDays':    _workingDays,
      'maxPeriods':     _maxPeriods,
      'gaPop':          _gaPop,
      'gaGen':          _gaGen,
      'gaStagnation':   _gaStagnation,
      'fridayShortDay':  _fridayShortDay,
      'fridayMaxPeriod': _fridayMaxPeriod,
      'scheduleLocked':  _scheduleLocked,
      'allocRoomDefault': _allocRoomDefault,
    }, SetOptions(merge: true));
  }

  Map<String, dynamic> toJson() => {
    'backendUrl':     _backendUrl,
    'workingDays':    _workingDays,
    'maxPeriods':     _maxPeriods,
    'gaPop':          _gaPop,
    'gaGen':          _gaGen,
    'gaStagnation':   _gaStagnation,
    'fridayShortDay':  _fridayShortDay,
    'fridayMaxPeriod': _fridayMaxPeriod,
    'scheduleLocked':  _scheduleLocked,
    'allocRoomDefault': _allocRoomDefault,
  };

  void importSettings(Map<String, dynamic> data) {
    if (data['backendUrl']     != null) _backendUrl     = data['backendUrl'];
    if (data['workingDays']    != null) _workingDays    = data['workingDays'];
    if (data['maxPeriods']     != null) _maxPeriods     = data['maxPeriods'];
    if (data['gaPop']          != null) _gaPop          = data['gaPop'];
    if (data['gaGen']          != null) _gaGen          = data['gaGen'];
    if (data['gaStagnation']   != null) _gaStagnation   = data['gaStagnation'];
    // fridayShortDay / fridayMaxPeriod intentionally not imported — feature removed.
    if (data['scheduleLocked'] != null) _scheduleLocked = data['scheduleLocked'];
    if (data['allocRoomDefault'] != null) _allocRoomDefault = data['allocRoomDefault'];
    notifyListeners();
    _saveToCloud();
  }

  // ── Setters ───────────────────────────────────────────────────────────────
  void setBackendUrl(String url) {
    _backendUrl = url.trim().isEmpty ? 'http://127.0.0.1:8000' : url.trim();
    _saveToCloud(); notifyListeners();
  }

  void setWorkingDays(int days) {
    _workingDays = days.clamp(5, 6);
    _saveToCloud(); notifyListeners();
  }

  void setMaxPeriods(int periods) {
    _maxPeriods = periods.clamp(1, 12);
    _saveToCloud(); notifyListeners();
  }

  void setGaPop(int pop) {
    _gaPop = pop.clamp(50, 2000);
    _saveToCloud(); notifyListeners();
  }

  void setGaGen(int gen) {
    _gaGen = gen.clamp(50, 5000);
    _saveToCloud(); notifyListeners();
  }

  void resetToDefaults() {
    _backendUrl     = 'http://127.0.0.1:8000';
    _workingDays    = 6;
    _maxPeriods     = 6;
    _gaPop          = 80;
    _gaGen          = 300;
    _gaStagnation   = 40;
    _fridayShortDay  = false;
    _fridayMaxPeriod = 3;
    _scheduleLocked  = false;
    _allocRoomDefault = false;
    _saveToCloud(); notifyListeners();
  }

  void setFridayShortDay(bool val) {
    _fridayShortDay = val;
    _saveToCloud(); notifyListeners();
  }

  void setFridayMaxPeriod(int p) {
    _fridayMaxPeriod = p.clamp(1, 8);
    _saveToCloud(); notifyListeners();
  }

  void setScheduleLocked(bool val) {
    _scheduleLocked = val;
    _saveToCloud(); notifyListeners();
  }

  void setAllocRoomDefault(bool val) {
    _allocRoomDefault = val;
    _saveToCloud(); notifyListeners();
  }
}