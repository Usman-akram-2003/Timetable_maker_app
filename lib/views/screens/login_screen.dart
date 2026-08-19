import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../../viewmodels/auth_viewmodel.dart';
import '../../app_theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with SingleTickerProviderStateMixin {
  final _emailCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();
  bool _obscure    = true;
  late AnimationController _animCtrl;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _animCtrl.dispose();
    super.dispose();
  }

  void _login() async {
    final vm = context.read<AuthViewModel>();
    final email = _emailCtrl.text.trim();
    final pass = _passCtrl.text.trim();
    if (email.isEmpty || pass.isEmpty) return;

    final success = await vm.signIn(email, pass);
    if (!success && mounted && vm.errorMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(vm.errorMessage!),
        backgroundColor: AppTheme.error,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Widget _buildSkeleton(bool isDark) {
    final baseColor = isDark ? Colors.white.withValues(alpha: .05) : Colors.black.withValues(alpha: .05);
    final highlightColor = isDark ? Colors.white.withValues(alpha: .15) : Colors.black.withValues(alpha: .15);

    return AnimatedBuilder(
      animation: _animCtrl,
      builder: (context, child) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            return LinearGradient(
              colors: [baseColor, highlightColor, baseColor],
              stops: const [0.1, 0.5, 0.9],
              begin: const Alignment(-1.0, -0.3),
              end: const Alignment(1.0, 0.3),
              transform: SlideGradientTransform(_animCtrl.value),
            ).createShader(bounds);
          },
          child: child,
        );
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(height: 48, width: 48, decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle)),
          const SizedBox(height: 24),
          Container(height: 32, margin: const EdgeInsets.symmetric(horizontal: 40), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8))),
          const SizedBox(height: 12),
          Container(height: 16, margin: const EdgeInsets.symmetric(horizontal: 60), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(4))),
          const SizedBox(height: 40),
          Container(height: 56, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16))),
          const SizedBox(height: 20),
          Container(height: 56, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16))),
          const SizedBox(height: 40),
          Container(height: 56, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authVm = context.watch<AuthViewModel>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    final bg = isDark ? const Color(0xFF0D1117) : const Color(0xFFF3F4F6);
    final textCol = isDark ? Colors.white : const Color(0xFF1F2937);

    return Scaffold(
      backgroundColor: bg,
      body: Stack(
        children: [
          // Background Glows
          Positioned(
            top: -100, left: -100,
            child: Container(
              width: 300, height: 300,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFF4F46E5),
              ),
            ),
          ),
          Positioned(
            bottom: -150, right: -50,
            child: Container(
              width: 400, height: 400,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFF059669),
              ),
            ),
          ),
          // Blur Layer
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 100, sigmaY: 100),
              child: Container(color: Colors.transparent),
            ),
          ),
          
          // Content
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Container(
                margin: const EdgeInsets.all(24),
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 48),
                decoration: BoxDecoration(
                  color: isDark ? Colors.black.withValues(alpha: .4) : Colors.white.withValues(alpha: .7),
                  borderRadius: BorderRadius.circular(32),
                  border: Border.all(color: Colors.white.withValues(alpha: isDark ? .1 : .4)),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: .1), blurRadius: 30, offset: const Offset(0, 10)),
                  ],
                ),
                child: authVm.status == AuthStatus.initial 
                  ? _buildSkeleton(isDark)
                  : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(LucideIcons.table, size: 52, color: isDark ? Colors.white : AppTheme.accentCyan),
                    const SizedBox(height: 24),
                    Text('Welcome Back', textAlign: TextAlign.center, style: GoogleFonts.plusJakartaSans(
                      fontSize: 28, fontWeight: FontWeight.w800, color: textCol,
                    )),
                    const SizedBox(height: 8),
                    Text('Secure access to Timetable Engine', textAlign: TextAlign.center, style: GoogleFonts.plusJakartaSans(
                      fontSize: 14, color: textCol.withValues(alpha: .6),
                    )),
                    const SizedBox(height: 40),
                    
                    _buildTextField(
                      controller: _emailCtrl,
                      hint: 'Admin Email',
                      icon: Icons.email_outlined,
                      isDark: isDark,
                      textCol: textCol,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 20),

                    _buildTextField(
                      controller: _passCtrl,
                      hint: 'Password',
                      icon: Icons.lock_outline_rounded,
                      isDark: isDark,
                      textCol: textCol,
                      isPassword: true,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) { if (!authVm.isLoading) _login(); },
                    ),
                    
                    const SizedBox(height: 40),
                    
                    GestureDetector(
                      onTap: authVm.isLoading ? null : _login,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        height: 56,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(colors: [Color(0xFF4F46E5), Color(0xFF7C3AED)]),
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(color: const Color(0xFF4F46E5).withValues(alpha: .3), blurRadius: 20, offset: const Offset(0, 8)),
                          ],
                        ),
                        child: Center(
                          child: authVm.isLoading 
                            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                            : Text('Sign In', style: GoogleFonts.plusJakartaSans(
                                color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold,
                              )),
                        ),
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

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    required bool isDark,
    required Color textCol,
    bool isPassword = false,
    TextInputAction? textInputAction,
    ValueChanged<String>? onSubmitted,
  }) {
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: .05) : Colors.black.withValues(alpha: .03),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isDark ? Colors.white.withValues(alpha: .1) : Colors.black.withValues(alpha: .05)),
      ),
      child: TextField(
        controller: controller,
        obscureText: isPassword && _obscure,
        textInputAction: textInputAction,
        onSubmitted: onSubmitted,
        style: GoogleFonts.plusJakartaSans(color: textCol, fontWeight: FontWeight.w600),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: GoogleFonts.plusJakartaSans(color: textCol.withValues(alpha: .4), fontWeight: FontWeight.w500),
          prefixIcon: Icon(icon, color: textCol.withValues(alpha: .5), size: 20),
          suffixIcon: isPassword ? IconButton(
            icon: Icon(_obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined, color: textCol.withValues(alpha: .5), size: 20),
            onPressed: () => setState(() => _obscure = !_obscure),
          ) : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 18),
        ),
      ),
    );
  }
}

class SlideGradientTransform extends GradientTransform {
  final double percent;
  const SlideGradientTransform(this.percent);
  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(bounds.width * percent, 0, 0);
  }
}
