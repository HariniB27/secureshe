import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_prefs.dart';
import '../state/auth_state.dart';
import '../state/contacts_state.dart';
import '../theme.dart';
import '../widgets/ss_ui.dart';

/// Personal Information. Name and phone are saved to your account; the
/// rest (birthday, gender, city, health details) stays on this phone only.
class PersonalInfoScreen extends StatefulWidget {
  const PersonalInfoScreen({super.key});

  @override
  State<PersonalInfoScreen> createState() => _PersonalInfoScreenState();
}

class _PersonalInfoScreenState extends State<PersonalInfoScreen> {
  static const _genders = ['Female', 'Male', 'Non-binary', 'Prefer not to say'];
  static const _bloodTypes = ['A+', 'A−', 'B+', 'B−', 'AB+', 'AB−', 'O+', 'O−'];

  bool _editing = false;
  bool _saving = false;
  String? _message;
  bool _messageIsError = false;

  late final _name = TextEditingController();
  late final _phone = TextEditingController();
  late final _city = TextEditingController();
  late final _allergies = TextEditingController();
  late final _medical = TextEditingController();
  DateTime? _dob;
  String? _gender;
  String? _bloodType;

  @override
  void initState() {
    super.initState();
    _fill();
  }

  void _fill() {
    final auth = context.read<AuthState>();
    final extras = context.read<AppPrefs>().personalExtras;
    _name.text = auth.userName ?? '';
    _phone.text = auth.userPhone ?? '';
    _city.text = extras['city'] ?? '';
    _allergies.text = extras['allergies'] ?? '';
    _medical.text = extras['medical'] ?? '';
    _dob = DateTime.tryParse(extras['dob'] ?? '');
    _gender = extras['gender'];
    _bloodType = extras['blood'];
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _city, _allergies, _medical]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _message = null;
    });

    final auth = context.read<AuthState>();
    final prefs = context.read<AppPrefs>();

    String? error;
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    if (name != (auth.userName ?? '') || phone != (auth.userPhone ?? '')) {
      error = await auth.updateProfile(name: name, phone: phone);
    }

    await prefs.savePersonalExtras({
      'city': _city.text.trim(),
      'allergies': _allergies.text.trim(),
      'medical': _medical.text.trim(),
      if (_dob != null) 'dob': _dob!.toIso8601String(),
      if (_gender != null) 'gender': _gender!,
      if (_bloodType != null) 'blood': _bloodType!,
    });

    if (!mounted) return;
    setState(() {
      _saving = false;
      _editing = error != null;
      _message = error ?? 'Profile updated successfully!';
      _messageIsError = error != null;
    });
  }

  Future<void> _pickDob() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(now.year - 20),
      firstDate: DateTime(1920),
      lastDate: now,
    );
    if (picked != null) setState(() => _dob = picked);
  }

  Future<void> _pickOption(String title, List<String> options, ValueChanged<String> onPick) async {
    final picked = await showSSSheet<String>(
      context,
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitle(title: title),
          for (final o in options)
            ListTile(
              title: Text(o, style: TextStyle(color: ctx.ss.foreground)),
              onTap: () => Navigator.of(ctx).pop(o),
            ),
        ],
      ),
    );
    if (picked != null) setState(() => onPick(picked));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    final auth = context.watch<AuthState>();
    final contacts = context.watch<ContactsState>().contacts;
    final primary = contacts.isEmpty ? null : contacts.first;

    return SSPage(
      header: GlassHeader(
        title: 'Personal Information',
        titleSize: 17,
        onBack: () => Navigator.of(context).pop(),
        trailing: _editing
            ? SizedBox(
                width: 80,
                child: GradientButton(
                  label: 'Save',
                  height: 36,
                  fontSize: 13,
                  loading: _saving,
                  onPressed: _save,
                ),
              )
            : SSIconButton(
                icon: Icons.edit_outlined,
                iconColor: AppColors.primary,
                background: AppColors.primary.withValues(alpha: 0.1),
                borderColor: AppColors.primary.withValues(alpha: 0.3),
                size: 36,
                onTap: () => setState(() {
                  _editing = true;
                  _message = null;
                }),
              ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          if (_message != null) ...[
            MessageBanner(
              text: _message!,
              color: _messageIsError ? AppColors.destructive : AppColors.success,
              icon: _messageIsError ? Icons.error_outline_rounded : Icons.check_rounded,
            ),
            const SizedBox(height: 12),
          ],
          Center(
            child: Container(
              width: 96,
              height: 96,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: AppColors.primaryGradient,
                borderRadius: BorderRadius.circular(32),
                boxShadow: [
                  BoxShadow(color: AppColors.primary.withValues(alpha: 0.35), blurRadius: 40),
                ],
              ),
              child: Text(
                auth.initials,
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              auth.userName ?? '',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.foreground),
            ),
          ),
          const SizedBox(height: 20),

          const SectionLabel('Personal Details'),
          _Group(children: [
            _Field(icon: Icons.person_outline_rounded, label: 'Full Name',
                controller: _name, editing: _editing),
            _Field(icon: Icons.phone_outlined, label: 'Phone Number', color: AppColors.warning,
                controller: _phone, editing: _editing, keyboardType: TextInputType.phone),
            _ReadOnly(icon: Icons.mail_outline_rounded, label: 'Email Address',
                value: auth.userEmail ?? ''),
            _Picker(
              icon: Icons.calendar_today_outlined,
              label: 'Date of Birth',
              color: AppColors.lavender,
              value: _dob == null ? null : _date(_dob!),
              editing: _editing,
              onTap: _pickDob,
            ),
            _Picker(
              icon: Icons.person_outline_rounded,
              label: 'Gender',
              value: _gender,
              editing: _editing,
              onTap: () => _pickOption('Gender', _genders, (v) => _gender = v),
            ),
            _Field(icon: Icons.place_outlined, label: 'City / Location', color: AppColors.success,
                controller: _city, editing: _editing, hint: 'Your city'),
          ]),
          const SizedBox(height: 20),

          const SectionLabel('Health Information'),
          _Group(children: [
            _Picker(
              icon: Icons.favorite_border_rounded,
              label: 'Blood Type',
              color: AppColors.destructive,
              value: _bloodType,
              editing: _editing,
              onTap: () => _pickOption('Blood Type', _bloodTypes, (v) => _bloodType = v),
            ),
            _Field(icon: Icons.favorite_border_rounded, label: 'Known Allergies',
                color: AppColors.destructive, controller: _allergies, editing: _editing,
                hint: 'e.g. Penicillin, Peanuts'),
            _Field(icon: Icons.favorite_border_rounded, label: 'Medical Notes',
                color: AppColors.destructive, controller: _medical, editing: _editing,
                hint: 'Anything first responders should know'),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(
              '🔒 Birthday, gender, city and health details are stored on this '
              'phone only, not on our servers.',
              style: TextStyle(fontSize: 10, color: c.mutedForeground),
            ),
          ),
          const SizedBox(height: 20),

          const SectionLabel('Primary Emergency Contact'),
          _Group(children: [
            ListTile(
              leading: const IconTile(icon: Icons.phone_outlined, color: AppColors.success),
              title: Text(
                primary == null ? 'Not set' : '${primary.name} — ${primary.phone}',
                style: TextStyle(fontSize: 14, color: c.foreground),
              ),
              subtitle: Text(
                'First contact in your Trusted Circle',
                style: TextStyle(fontSize: 11, color: c.mutedForeground),
              ),
            ),
          ]),
          const SizedBox(height: 20),

          SSCard(
            color: AppColors.primary.withValues(alpha: 0.07),
            borderColor: AppColors.primary.withValues(alpha: 0.2),
            child: Row(
              children: [
                const IconTile(icon: Icons.shield_outlined, color: AppColors.primary, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        auth.joinedAt == null
                            ? 'SecureShe account'
                            : 'Account joined ${_monthYear(auth.joinedAt!)}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: c.foreground,
                        ),
                      ),
                      if (auth.userId != null)
                        Text(
                          'Member ID · SS-${auth.userId.toString().padLeft(4, '0')}',
                          style: TextStyle(fontSize: 11, color: c.mutedForeground),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => Navigator.of(context).pushNamed('/privacy-security'),
            child: Text(
              'Delete Account',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.destructive.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _date(DateTime d) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  String _monthYear(DateTime d) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return '${months[d.month - 1]} ${d.year}';
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SSCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            children[i],
            if (i < children.length - 1) Divider(height: 1, color: context.ss.border),
          ],
        ],
      ),
    );
  }
}

class _RowShell extends StatelessWidget {
  const _RowShell({required this.icon, required this.label, required this.color, required this.child});

  final IconData icon;
  final String label;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconTile(icon: icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label.toUpperCase(),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                    color: context.ss.mutedForeground,
                  ),
                ),
                const SizedBox(height: 3),
                child,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.icon,
    required this.label,
    required this.controller,
    required this.editing,
    this.color = AppColors.primary,
    this.keyboardType,
    this.hint,
  });

  final IconData icon;
  final String label;
  final TextEditingController controller;
  final bool editing;
  final Color color;
  final TextInputType? keyboardType;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return _RowShell(
      icon: icon,
      label: label,
      color: color,
      child: editing
          ? TextField(
              controller: controller,
              keyboardType: keyboardType,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c.foreground),
              decoration: InputDecoration(
                hintText: hint,
                isDense: true,
                filled: false,
                contentPadding: const EdgeInsets.only(bottom: 4),
                border: UnderlineInputBorder(
                  borderSide: BorderSide(color: AppColors.primary.withValues(alpha: 0.4)),
                ),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: AppColors.primary.withValues(alpha: 0.4)),
                ),
                focusedBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: AppColors.primary),
                ),
              ),
            )
          : _Value(controller.text),
    );
  }
}

class _ReadOnly extends StatelessWidget {
  const _ReadOnly({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return _RowShell(icon: icon, label: label, color: AppColors.primary, child: _Value(value));
  }
}

class _Picker extends StatelessWidget {
  const _Picker({
    required this.icon,
    required this.label,
    required this.value,
    required this.editing,
    required this.onTap,
    this.color = AppColors.primary,
  });

  final IconData icon;
  final String label;
  final String? value;
  final bool editing;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    return InkWell(
      onTap: editing ? onTap : null,
      child: _RowShell(
        icon: icon,
        label: label,
        color: color,
        child: Row(
          children: [
            Expanded(child: _Value(value ?? '')),
            if (editing) Icon(Icons.expand_more_rounded, size: 18, color: c.mutedForeground),
          ],
        ),
      ),
    );
  }
}

class _Value extends StatelessWidget {
  const _Value(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.ss;
    if (text.isEmpty) {
      return Text(
        'Not set',
        style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic, color: c.mutedForeground),
      );
    }
    return Text(
      text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c.foreground),
    );
  }
}
