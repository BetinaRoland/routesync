import 'package:material_ui/material_ui.dart';
import 'theme.dart';
import 'theme_controller.dart';

/// Shared RouteSync building blocks. Every screen should compose these so
/// radii, spacing, shadows and colours stay identical across all four roles.

/// The RouteSync outline bus sketch (assets/brand/routesync_bus_outline.png).
/// The linework is the original brand sketch, not a redraw. It is stored as
/// white line art with transparency so it takes the colour of the current theme.
class BusOutline extends StatelessWidget {
  final double? height;
  final double? width;
  final Color? color;
  final double opacity;
  const BusOutline({
    super.key,
    this.height,
    this.width,
    this.color,
    this.opacity = 1,
  });

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: opacity,
    child: Image.asset(
      'assets/brand/routesync_bus_outline.png',
      height: height,
      width: width,
      fit: BoxFit.contain,
      color: color ?? Theme.of(context).colorScheme.primary,
      colorBlendMode: BlendMode.srcIn,
      excludeFromSemantics: true,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    ),
  );
}

/// Rounded floating card. Lifts slightly under the mouse when it can be tapped.
class RsCard extends StatefulWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;
  final bool selected;
  const RsCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.color,
    this.selected = false,
  });

  @override
  State<RsCard> createState() => _RsCardState();
}

class _RsCardState extends State<RsCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final reduce = MediaQuery.of(context).disableAnimations;
    final lift = widget.onTap != null && _hover;
    final radius = BorderRadius.circular(Rd.card);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: reduce ? Duration.zero : const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          color: widget.color ?? (dark ? const Color(0xFF171C28) : Colors.white),
          borderRadius: radius,
          border: Border.all(
            color: widget.selected ? scheme.primary : scheme.outlineVariant,
            width: widget.selected ? 2 : 1,
          ),
          boxShadow: softShadow(context, strong: lift),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: radius,
            onTap: widget.onTap,
            child: Padding(padding: widget.padding, child: widget.child),
          ),
        ),
      ),
    );
  }
}

/// Large page heading on a soft blue panel with the outline bus. The bus is
/// hidden on narrow screens so the text keeps its room.
class PageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final bool showBus;
  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.showBus = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 640;
        return Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Rd.card),
            border: Border.all(color: scheme.outlineVariant),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: dark
                  ? const [Color(0xFF1B2F78), Color(0xFF171C28)]
                  : const [Brand.powderBlue, Colors.white],
            ),
          ),
          child: Stack(
            children: [
              if (showBus && wide)
                Positioned(
                  right: 20,
                  bottom: 10,
                  child: BusOutline(height: 108, opacity: dark ? 0.9 : 0.8),
                ),
              Padding(
                padding: EdgeInsets.fromLTRB(24, 22, wide && showBus ? 300 : 24, 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          subtitle!,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    if (actions.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Wrap(spacing: 8, runSpacing: 8, children: actions),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A number with its label. Pass [onTap] to make the whole card a button.
class SummaryCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String? caption;
  final VoidCallback? onTap;
  final Tone? tone;
  const SummaryCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.caption,
    this.onTap,
    this.tone,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = tone == null ? scheme.onPrimaryContainer : toneColor(context, tone!);
    return RsCard(
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(Rd.control),
            ),
            child: Icon(icon, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: tone == null ? null : accent,
                  ),
                ),
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                if (caption != null)
                  Text(
                    caption!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          if (onTap != null)
            Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
        ],
      ),
    );
  }
}

/// A titled card with an optional action on the right ("View all").
class SectionCard extends StatelessWidget {
  final String title;
  final IconData? icon;
  final Widget? trailing;
  final Widget child;
  final EdgeInsetsGeometry bodyPadding;
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.icon,
    this.trailing,
    this.bodyPadding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RsCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 22, color: scheme.primary),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
          Padding(padding: bodyPadding, child: child),
        ],
      ),
    );
  }
}

/// A large tappable shortcut with an icon and a short label.
class ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const ActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return RsCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: scheme.primaryContainer,
            foregroundColor: scheme.onPrimaryContainer,
            child: Icon(icon),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// Light / dark switch for the top bar. The choice is saved.
class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return IconButton(
      tooltip: dark ? 'Switch to light theme' : 'Switch to dark theme',
      icon: Icon(dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
      onPressed: () => setThemeMode(dark ? ThemeMode.light : ThemeMode.dark),
    );
  }
}

/// Shown when a screen cannot load. Offers a retry when one is available.
class ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const ErrorState(this.message, {super.key, this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_off,
            size: 40,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        ],
      ),
    ),
  );
}
