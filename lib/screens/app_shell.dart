import 'package:flutter/material.dart';

import '../models/session.dart';
import '../theme/app_theme.dart';
import '../widgets/shell_widgets.dart';
import 'audits_screen.dart';
import 'learn_screen.dart';
import 'profile_screen.dart';
import 'sales_home_screen.dart';
import 'territory_screens.dart';

/// Role-based shell: same glass chrome, different destinations.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.session});
  final UserSession session;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tab = 0;

  bool get _isSales => widget.session.role == UserRole.salesOfficer;

  static const _salesNav = [
    NavItem(Icons.home_outlined, Icons.home_rounded, 'Home'),
    NavItem(Icons.assignment_outlined, Icons.assignment_rounded, 'Visits'),
    NavItem(Icons.headphones_outlined, Icons.headphones_rounded, 'Learn'),
    NavItem(Icons.person_outline_rounded, Icons.person_rounded, 'Profile'),
  ];
  static const _territoryNav = [
    NavItem(Icons.dashboard_outlined, Icons.dashboard_rounded, 'Dashboard'),
    NavItem(
      Icons.notifications_none_rounded,
      Icons.notifications_rounded,
      'Exceptions',
    ),
    NavItem(Icons.groups_outlined, Icons.groups_rounded, 'Team'),
    NavItem(Icons.person_outline_rounded, Icons.person_rounded, 'Profile'),
  ];

  @override
  Widget build(BuildContext context) {
    final pages = _isSales
        ? <Widget>[
            SalesHomeScreen(session: widget.session),
            const AuditsScreen(),
            const LearnScreen(),
            const ProfileScreen(),
          ]
        : <Widget>[
            TerritoryDashboardScreen(session: widget.session),
            const TerritoryAlertsScreen(),
            const TerritoryTeamScreen(),
            const ProfileScreen(),
          ];
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: Stack(
        children: [
          Positioned.fill(child: IndexedStack(index: _tab, children: pages)),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: FloatingGlassNav(
              items: _isSales ? _salesNav : _territoryNav,
              index: _tab,
              onChanged: (i) => setState(() => _tab = i),
            ),
          ),
        ],
      ),
    );
  }
}
