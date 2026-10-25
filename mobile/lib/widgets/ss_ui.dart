import 'package:flutter/material.dart';

import '../theme.dart';

// Building blocks matching the SecureShe Figma design: the blurred
// background, glass header, cards, gradient buttons, inputs and toggles.

/// The screen background: the purple/pink blur image with a dark (night)
/// or pink (day) wash over it, like the design's phone screen.
class SSBackground extends StatelessWidget {
  const SSBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: c.screen),
        Opacity(
          opacity: c.isDark ? 1 : 0.18,
          child: Image.asset(
            'assets/images/background.png',
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
        ColoredBox(color: c.overlay),
        child,
      ],
    );
  }
}

/// A full screen with the design background. Use instead of Scaffold.
class SSPage extends StatelessWidget {
  const SSPage({
    super.key,
    required this.body,
    this.header,
    this.bottomNavigationBar,
    this.floatingActionButton,
    this.safeBottom = true,
  });

  final Widget body;
  final Widget? header;
  final Widget? bottomNavigationBar;
  final Widget? floatingActionButton;
  final bool safeBottom;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.ss.screen,
      extendBody: true,
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: bottomNavigationBar,
      body: SSBackground(
        child: Column(
          children: [
            ?header,
            Expanded(
              child: header == null
                  ? SafeArea(bottom: safeBottom, child: body)
                  : SafeArea(top: false, bottom: safeBottom, child: body),
            ),
          ],
        ),
      ),
    );
  }
}

/// Sticky glass header: optional back button, title, subtitle, trailing.
class GlassHeader extends StatelessWidget {
  const GlassHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.subtitleColor,
    this.onBack,
    this.trailing,
    this.titleSize = 15,
    this.bottom,
    this.leading,
  });

  final String title;
  final String? subtitle;
  final Color? subtitleColor;
  final VoidCallback? onBack;
  final Widget? trailing;
  final double titleSize;
  final Widget? bottom;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return Container(
      decoration: BoxDecoration(
        color: c.glass,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Row(
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 12)],
                  if (onBack != null) ...[
                    SSIconButton(icon: Icons.arrow_back_rounded, onTap: onBack!),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: titleSize,
                            fontWeight: titleSize > 16 ? FontWeight.w700 : FontWeight.w600,
                            color: c.foreground,
                          ),
                        ),
                        if (subtitle != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              subtitle!,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: subtitleColor != null
                                    ? FontWeight.w500
                                    : FontWeight.w400,
                                color: subtitleColor ?? c.mutedForeground,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
            ?bottom,
          ],
        ),
      ),
    );
  }
}

/// Square rounded button with an icon (back, bell, share…).
class SSIconButton extends StatelessWidget {
  const SSIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.size = 40,
    this.iconColor,
    this.background,
    this.borderColor,
    this.badge = false,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final Color? iconColor;
  final Color? background;
  final Color? borderColor;
  final bool badge;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    final button = Material(
      color: background ?? c.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(size * 0.3),
        side: BorderSide(color: borderColor ?? c.border),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(size * 0.3),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(icon, size: size * 0.45, color: iconColor ?? c.foreground),
              if (badge)
                Positioned(
                  top: size * 0.2,
                  right: size * 0.2,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: AppColors.destructive,
                      shape: BoxShape.circle,
                      border: Border.all(color: c.screen, width: 1.5),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// Rounded card with the design's translucent fill and border.
class SSCard extends StatelessWidget {
  const SSCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 16,
    this.borderColor,
    this.color,
    this.gradient,
    this.onTap,
    this.leftAccent,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? borderColor;
  final Color? color;
  final Gradient? gradient;
  final VoidCallback? onTap;

  /// Coloured stripe on the left edge (alert cards).
  final Color? leftAccent;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    final shape = BorderRadius.circular(radius);

    Widget content = Padding(padding: padding, child: child);

    if (leftAccent != null) {
      content = IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 4, color: leftAccent),
            Expanded(child: content),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: gradient == null ? (color ?? c.card) : null,
        gradient: gradient,
        borderRadius: shape,
        border: Border.all(color: borderColor ?? c.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: onTap == null ? content : InkWell(onTap: onTap, child: content),
      ),
    );
  }
}

enum SSButtonVariant { primary, danger, success, outline }

/// Big rounded button with the design's gradient and glow.
class GradientButton extends StatelessWidget {
  const GradientButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.trailingIcon,
    this.variant = SSButtonVariant.primary,
    this.loading = false,
    this.height = 56,
    this.fontSize = 15,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final IconData? trailingIcon;
  final SSButtonVariant variant;
  final bool loading;
  final double height;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    final enabled = onPressed != null && !loading;

    final (Gradient? gradient, Color glow) = switch (variant) {
      SSButtonVariant.primary => (AppColors.primaryGradient, AppColors.primary),
      SSButtonVariant.danger => (AppColors.dangerGradient, AppColors.destructive),
      SSButtonVariant.success => (AppColors.successGradient, AppColors.success),
      SSButtonVariant.outline => (null, Colors.transparent),
    };

    final foreground = variant == SSButtonVariant.outline ? c.foreground : Colors.white;

    return Opacity(
      opacity: enabled || loading ? 1 : 0.4,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          gradient: gradient,
          color: gradient == null ? c.card : null,
          borderRadius: BorderRadius.circular(16),
          border: gradient == null ? Border.all(color: c.border) : null,
          boxShadow: gradient == null
              ? null
              : [
                  BoxShadow(
                    color: glow.withValues(alpha: 0.35),
                    blurRadius: 24,
                    offset: const Offset(0, 4),
                  ),
                ],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: enabled ? onPressed : null,
            child: Center(
              child: loading
                  ? SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: foreground,
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (icon != null) ...[
                          Icon(icon, color: foreground, size: 20),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          label,
                          style: TextStyle(
                            color: foreground,
                            fontSize: fontSize,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (trailingIcon != null) ...[
                          const SizedBox(width: 8),
                          Icon(trailingIcon, color: foreground, size: 18),
                        ],
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Text input with a leading icon, as on Login / Register / Report.
class SSTextField extends StatefulWidget {
  const SSTextField({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.icon,
    this.iconColor,
    this.obscure = false,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.onChanged,
    this.maxLines = 1,
    this.borderColor,
    this.trailing,
    this.helper,
    this.helperColor,
    this.autofillHints,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String? label;
  final String? hint;
  final IconData? icon;
  final Color? iconColor;
  final bool obscure;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final int maxLines;
  final Color? borderColor;
  final Widget? trailing;
  final String? helper;
  final Color? helperColor;
  final Iterable<String>? autofillHints;
  final bool enabled;

  @override
  State<SSTextField> createState() => _SSTextFieldState();
}

class _SSTextFieldState extends State<SSTextField> {
  late bool _hidden = widget.obscure;
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    final focused = _focus.hasFocus;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.label != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              widget.label!,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: c.foreground,
              ),
            ),
          ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: EdgeInsets.symmetric(
            horizontal: 16,
            vertical: widget.maxLines > 1 ? 12 : 4,
          ),
          decoration: BoxDecoration(
            color: c.input,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: widget.borderColor ?? (focused ? AppColors.primary : c.border),
            ),
            boxShadow: focused
                ? [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.18),
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: Row(
            crossAxisAlignment: widget.maxLines > 1
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.center,
            children: [
              if (widget.icon != null) ...[
                Padding(
                  padding: EdgeInsets.only(top: widget.maxLines > 1 ? 2 : 0),
                  child: Icon(
                    widget.icon,
                    size: 18,
                    color: widget.iconColor ?? c.mutedForeground,
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focus,
                  enabled: widget.enabled,
                  obscureText: _hidden,
                  keyboardType: widget.keyboardType,
                  textInputAction: widget.textInputAction,
                  onSubmitted: widget.onSubmitted,
                  onChanged: widget.onChanged,
                  maxLines: widget.obscure ? 1 : widget.maxLines,
                  minLines: widget.maxLines > 1 ? widget.maxLines : null,
                  autofillHints: widget.autofillHints,
                  style: TextStyle(fontSize: 14, color: c.foreground),
                  cursorColor: AppColors.primary,
                  decoration: InputDecoration(
                    hintText: widget.hint,
                    hintStyle: TextStyle(color: c.mutedForeground, fontSize: 14),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    filled: false,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      vertical: widget.maxLines > 1 ? 0 : 12,
                    ),
                  ),
                ),
              ),
              if (widget.obscure)
                GestureDetector(
                  onTap: () => setState(() => _hidden = !_hidden),
                  child: Icon(
                    _hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                    size: 18,
                    color: c.mutedForeground,
                  ),
                ),
              if (widget.trailing != null) widget.trailing!,
            ],
          ),
        ),
        if (widget.helper != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              widget.helper!,
              style: TextStyle(
                fontSize: 11,
                color: widget.helperColor ?? c.mutedForeground,
              ),
            ),
          ),
      ],
    );
  }
}

/// Small uppercase section label ("QUICK ACTIONS", "ACCOUNT").
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.padding = const EdgeInsets.fromLTRB(4, 0, 4, 8)});

  final String text;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
          color: context.ss.mutedForeground,
        ),
      ),
    );
  }
}

/// Pill switch from the design (44 × 24).
class SSToggle extends StatelessWidget {
  const SSToggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor = AppColors.primary,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final Color activeColor;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return Semantics(
      toggled: value,
      button: true,
      child: GestureDetector(
        onTap: () => onChanged(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 44,
          height: 24,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: value ? activeColor : (c.isDark ? const Color(0x26FFFFFF) : c.muted),
            borderRadius: BorderRadius.circular(12),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutBack,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 16,
              height: 16,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 3)],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Rounded tinted icon square (menu rows, stat cards).
class IconTile extends StatelessWidget {
  const IconTile({
    super.key,
    required this.icon,
    required this.color,
    this.size = 36,
    this.radius = 12,
    this.iconSize,
    this.filled = false,
  });

  final IconData icon;
  final Color color;
  final double size;
  final double radius;
  final double? iconSize;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: filled ? color : color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(
        icon,
        size: iconSize ?? size * 0.48,
        color: filled ? Colors.white : color,
      ),
    );
  }
}

/// Small coloured pill ("Live", "Safest", "In Progress").
class TagPill extends StatelessWidget {
  const TagPill({
    super.key,
    required this.text,
    required this.color,
    this.icon,
    this.fontSize = 11,
  });

  final String text;
  final Color color;
  final IconData? icon;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: fontSize + 1, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Red / green / pink message box.
class MessageBanner extends StatelessWidget {
  const MessageBanner({
    super.key,
    required this.text,
    this.color = AppColors.destructive,
    this.icon,
    this.onClose,
  });

  final String text;
  final Color color;
  final IconData? icon;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12, color: color)),
          ),
          if (onClose != null)
            GestureDetector(
              onTap: onClose,
              child: Icon(Icons.close_rounded, size: 16, color: color),
            ),
        ],
      ),
    );
  }
}

/// Step dots in headers ("Step 2 of 3"): current one is a wide pill.
class StepDots extends StatelessWidget {
  const StepDots({super.key, required this.step, required this.count});

  final int step;
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            margin: const EdgeInsets.only(left: 6),
            width: i == step ? 20 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: i <= step ? AppColors.primary : c.muted,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }
}

/// Thin progress line under a header.
class ThinProgress extends StatelessWidget {
  const ThinProgress({super.key, required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 2,
      child: Stack(
        children: [
          Container(color: context.ss.border),
          AnimatedFractionallySizedBox(
            duration: const Duration(milliseconds: 300),
            widthFactor: value.clamp(0.0, 1.0),
            child: Container(color: AppColors.primary),
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet with the design's drag handle and rounded top.
Future<T?> showSSSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool scrollable = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: scrollable,
    useSafeArea: true,
    backgroundColor: context.ss.sheet,
    barrierColor: Colors.black.withValues(alpha: 0.7),
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: sheetContext.ss.muted,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              builder(sheetContext),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Title row used at the top of sheets: title, subtitle and a close button.
class SheetTitle extends StatelessWidget {
  const SheetTitle({super.key, required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: c.foreground,
                  ),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: TextStyle(fontSize: 12, color: c.mutedForeground),
                    ),
                  ),
              ],
            ),
          ),
          SSIconButton(
            icon: Icons.close_rounded,
            size: 36,
            iconColor: c.mutedForeground,
            onTap: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

/// Short "15 mins ago" style text.
String timeAgo(DateTime? time) {
  if (time == null) return 'recently';
  final diff = DateTime.now().difference(time.toLocal());
  if (diff.inSeconds < 60) return 'Just now';
  if (diff.inMinutes < 60) {
    return '${diff.inMinutes} min${diff.inMinutes == 1 ? '' : 's'} ago';
  }
  if (diff.inHours < 24) {
    return '${diff.inHours} hour${diff.inHours == 1 ? '' : 's'} ago';
  }
  if (diff.inDays == 1) return 'Yesterday';
  return '${diff.inDays} days ago';
}

/// "Mar 28, 2026 · 10:30 AM"
String formatDateTime(DateTime? time) {
  if (time == null) return '—';
  final t = time.toLocal();
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final minute = t.minute.toString().padLeft(2, '0');
  final ampm = t.hour < 12 ? 'AM' : 'PM';
  return '${months[t.month - 1]} ${t.day}, ${t.year} · $hour:$minute $ampm';
}

/// "1.2 km" / "350 m"
String formatDistance(double metres) {
  if (metres < 1000) return '${metres.round()} m';
  return '${(metres / 1000).toStringAsFixed(metres < 10000 ? 1 : 0)} km';
}

/// "18 min" / "1 h 05 min"
String formatDuration(Duration d) {
  if (d.inMinutes < 60) return '${d.inMinutes.clamp(0, 59)} min';
  return '${d.inHours} h ${(d.inMinutes % 60).toString().padLeft(2, '0')} min';
}
