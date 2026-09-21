import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mobile/services/haptic_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HapticService Configuration & Persistence Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('Loads default haptic styles when preferences are empty', () async {
      await HapticService.initialize();
      expect(HapticService.activeArmStyle, equals(ArmHapticStyle.dualClack180));
      expect(HapticService.activeDisarmStyle, equals(DisarmHapticStyle.doubleSoftTap150));
      expect(HapticService.activeScrollStyle, equals(ScrollHapticStyle.softCrownHalved));
      expect(HapticService.activePresetStyle, equals(PresetHapticStyle.magneticSnap));
    });

    test('Persists and updates active arming haptic style', () async {
      await HapticService.setArmStyle(ArmHapticStyle.dualClackFast110);
      expect(HapticService.activeArmStyle, equals(ArmHapticStyle.dualClackFast110));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('haptic_arm_style'), equals(ArmHapticStyle.dualClackFast110.index));
    });

    test('Persists and updates active disarming haptic style', () async {
      await HapticService.setDisarmStyle(DisarmHapticStyle.gentleDoubleTap100);
      expect(HapticService.activeDisarmStyle, equals(DisarmHapticStyle.gentleDoubleTap100));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('haptic_disarm_style'), equals(DisarmHapticStyle.gentleDoubleTap100.index));
    });

    test('Persists and updates active scroll haptic style', () async {
      await HapticService.setScrollStyle(ScrollHapticStyle.fiveMinuteMilestones);
      expect(HapticService.activeScrollStyle, equals(ScrollHapticStyle.fiveMinuteMilestones));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('haptic_scroll_style'), equals(ScrollHapticStyle.fiveMinuteMilestones.index));
    });

    test('Provides valid descriptive titles and metadata for all arming styles', () {
      for (final style in ArmHapticStyle.values) {
        final title = HapticService.armStyleTitle(style);
        final desc = HapticService.armStyleDesc(style);
        expect(title.isNotEmpty, isTrue);
        expect(desc.isNotEmpty, isTrue);
      }
    });

    test('Provides valid descriptive titles and metadata for all disarming styles', () {
      for (final style in DisarmHapticStyle.values) {
        final title = HapticService.disarmStyleTitle(style);
        final desc = HapticService.disarmStyleDesc(style);
        expect(title.isNotEmpty, isTrue);
        expect(desc.isNotEmpty, isTrue);
      }
    });

    test('Provides valid descriptive titles and metadata for all scroll styles', () {
      for (final style in ScrollHapticStyle.values) {
        final title = HapticService.scrollStyleTitle(style);
        final desc = HapticService.scrollStyleDesc(style);
        expect(title.isNotEmpty, isTrue);
        expect(desc.isNotEmpty, isTrue);
      }
    });
  });
}
