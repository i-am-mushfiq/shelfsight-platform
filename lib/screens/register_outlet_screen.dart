import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

import '../models/field_models.dart';
import '../models/session.dart';
import '../services/platform_api.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/shell_widgets.dart';
import '../widgets/store_type_picker.dart';
import 'outlet_screen.dart';

/// Registers a shop that is not in the outlet list yet. It is assigned to the officer
/// straight away and marked unverified until the master data team confirms it.
class RegisterOutletScreen extends StatefulWidget {
  const RegisterOutletScreen({super.key});

  @override
  State<RegisterOutletScreen> createState() => _RegisterOutletScreenState();
}

class _RegisterOutletScreenState extends State<RegisterOutletScreen> {
  // One id per form: retries after a dropped connection cannot register the shop twice.
  final String _clientOutletId = newClientId();
  final _name = TextEditingController();
  final _owner = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  List<StoreType>? _types;
  StoreType? _type;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadTypes();
  }

  @override
  void dispose() {
    for (final controller in [_name, _owner, _phone, _address]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadTypes() async {
    try {
      final types = (await PlatformApi.instance.storeTypes()).map(StoreType.fromJson).toList();
      if (mounted) setState(() => _types = types);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  String? _text(TextEditingController controller) {
    final value = controller.text.trim();
    return value.isEmpty ? null : value;
  }

  bool get _ready => _name.text.trim().length >= 2 && _type != null && !_saving;

  Future<void> _register() async {
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final created = await PlatformApi.instance.registerOutlet(
        clientOutletId: _clientOutletId,
        name: _name.text.trim(),
        storeTypeId: _type!.id,
        ownerName: _text(_owner),
        phone: _text(_phone),
        address: _text(_address),
        lat: SimulatedGps.lat,
        lng: SimulatedGps.lng,
      );
      final duplicates = (created['possible_duplicates'] as List? ?? const []).cast<Map<String, dynamic>>();
      if (duplicates.isNotEmpty) {
        final nearest = duplicates.first;
        messenger.showSnackBar(SnackBar(
          duration: const Duration(seconds: 6),
          content: Text(
            'Registered. ${nearest['name']} (${nearest['code']}) is ${(nearest['meters'] as num).round()} m away — '
            'make sure it is not the same shop.',
          ),
        ));
      } else {
        messenger.showSnackBar(SnackBar(content: Text(t('Shop registered. Start the visit when ready.'))));
      }
      navigator.pushReplacement(
        MaterialPageRoute(
          settings: const RouteSettings(name: OutletScreen.routeName),
          builder: (_) => OutletScreen(shop: Shop.fromJson(created), atShop: true),
        ),
      );
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
      if (mounted) setState(() => _saving = false);
    }
  }

  InputDecoration _field(String label, {String? hint, IconData? icon}) => InputDecoration(
    labelText: label,
    hintText: hint,
    prefixIcon: icon == null ? null : Icon(icon),
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
  );

  @override
  Widget build(BuildContext context) {
    final types = _types;
    return Scaffold(
      backgroundColor: AppColors.canvas,
      appBar: AppBar(title: Text(t('Register a new shop'))),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: AppColors.border)),
          ),
          child: PrimaryButton(
            label: _saving ? 'Registering…' : 'Register shop',
            onPressed: _ready ? _register : null,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpace.page),
        children: [
          TextField(
            key: const Key('register-name'),
            controller: _name,
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => setState(() {}),
            decoration: _field(t('Shop name'), hint: t('As on the signboard'), icon: Icons.storefront_outlined),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _owner,
            textCapitalization: TextCapitalization.words,
            decoration: _field(t('Owner name (optional)'), icon: Icons.person_outline_rounded),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: _field(t('Phone (optional)'), icon: Icons.phone_outlined),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _address,
            decoration: _field(t('Address or landmark (optional)'), icon: Icons.place_outlined),
          ),
          const SizedBox(height: 20),
          SectionTitle(title: t('What kind of store is it?')),
          const SizedBox(height: 10),
          if (_error != null)
            SurfaceCard(color: AppColors.redSoft, borderColor: AppColors.red, onTap: _loadTypes, child: Text('$_error  Tap to retry.'))
          else if (types == null)
            const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
          else
            StoreTypeGrid(types: types, selectedId: _type?.id, onSelected: (type) => setState(() => _type = type)),
          const SizedBox(height: 16),
          StatusPill(
            label: t('Location: your current position (simulated GPS)'),
            icon: Icons.my_location_rounded,
            color: AppColors.inkMuted,
            background: AppColors.surfaceAlt,
          ),
        ],
      ),
    );
  }
}
