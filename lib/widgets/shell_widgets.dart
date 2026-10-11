import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

import '../screens/support_screens.dart';
import '../theme/app_theme.dart';

/// Fixed header: title (+ optional subtitle) and notifications. Never scrolls.
class ShelfSightHeader extends StatelessWidget {
  const ShelfSightHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.alertCount = 0,
  });

  static const double height = 60;

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final int alertCount;

  /// Total height including the status bar, for scroll-content top padding.
  static double totalHeight(BuildContext context) =>
      MediaQuery.paddingOf(context).top + height;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return ColoredBox(
      color: AppColors.headerSurface,
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, top, 8, 0),
        child: SizedBox(
          height: height,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: AppFontSize.xl,
                        height: 1.2,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -.2,
                        color: AppColors.ink,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: AppFontSize.md,
                          height: 1.3,
                          color: AppColors.inkMuted,
                        ),
                      ),
                  ],
                ),
              ),
              ?trailing,
              IconButton(
                tooltip: t('Notifications'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const NotificationsScreen(),
                  ),
                ),
                icon: Badge(
                  isLabelVisible: alertCount > 0,
                  label: Text('$alertCount'),
                  backgroundColor: AppColors.red,
                  child: const Icon(
                    Icons.notifications_none_rounded,
                    color: AppColors.inkMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class NavItem {
  const NavItem(this.icon, this.activeIcon, this.label);
  final IconData icon;
  final IconData activeIcon;
  final String label;
}

/// Flat bottom navigation pinned to the screen edge.
class FloatingGlassNav extends StatelessWidget {
  const FloatingGlassNav({
    super.key,
    required this.items,
    required this.index,
    required this.onChanged,
  });

  static const double height = 60;
  static double totalHeight(BuildContext context) =>
      height + MediaQuery.paddingOf(context).bottom;

  final List<NavItem> items;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
        child: SizedBox(
          height: height,
          child: Row(
            children: [
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: _NavButton(
                    item: items[i],
                    selected: i == index,
                    onTap: () => onChanged(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });
  final NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.navy : AppColors.inkMuted;
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              selected ? item.activeIcon : item.icon,
              size: 22,
              color: color,
            ),
            const SizedBox(height: 3),
            Text(
              item.label,
              maxLines: 1,
              style: TextStyle(
                fontSize: AppFontSize.xs,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Scroll page under the fixed header and the shell-provided bottom nav.
class FixedHeaderScrollView extends StatelessWidget {
  const FixedHeaderScrollView({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.alertCount = 0,
    required this.slivers,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final int alertCount;
  final List<Widget> slivers;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        CustomScrollView(
          physics: const ClampingScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: SizedBox(
                height: ShelfSightHeader.totalHeight(context) + 4,
              ),
            ),
            ...slivers,
            SliverToBoxAdapter(
              child: SizedBox(
                height: FloatingGlassNav.totalHeight(context) + 12,
              ),
            ),
          ],
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: ShelfSightHeader(
            title: title,
            subtitle: subtitle,
            trailing: trailing,
            alertCount: alertCount,
          ),
        ),
      ],
    );
  }
}

/// Standard horizontal page padding sliver.
SliverPadding pagePadding(List<Widget> children) => SliverPadding(
  padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
  sliver: SliverList.list(children: children),
);

/// Flat white surface used for every content block.
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpace.card),
    this.onTap,
    this.color = AppColors.surface,
    this.borderColor = AppColors.border,
  });
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final Color color;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    const radius = AppRadius.card;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: radius,
        border: Border.all(color: borderColor),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}
