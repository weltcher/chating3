// 验证版本显示逻辑
void main() {
  print('=== iOS 版本显示验证 ===\n');
  
  // 模拟从 PackageInfo 获取的数据（iOS 构建后）
  final version = '1.0.4';
  final buildNumber = '1765520149';
  
  print('从 PackageInfo 获取:');
  print('  version: $version');
  print('  buildNumber: $buildNumber');
  print('');
  
  // 模拟 UpdateService.getCurrentVersion() 返回
  final versionData = {
    'version': version,
    'versionCode': buildNumber,
  };
  
  print('UpdateService.getCurrentVersion() 返回:');
  print('  version: ${versionData['version']}');
  print('  versionCode: ${versionData['versionCode']}');
  print('');
  
  // 模拟 UI 层格式化（mobile_settings_page.dart 和 settings_dialog.dart）
  final displayVersion = versionData['version'];
  final displayVersionCode = versionData['versionCode'];
  
  String formattedVersion;
  if (displayVersion != displayVersionCode && displayVersionCode!.isNotEmpty) {
    formattedVersion = 'v$displayVersion-$displayVersionCode';
  } else {
    formattedVersion = 'v$displayVersion';
  }
  
  print('UI 显示格式化:');
  print('  最终显示: $formattedVersion');
  print('');
  
  // 验证结果
  final expected = 'v1.0.4-1765520149';
  final isCorrect = formattedVersion == expected;
  
  print('=== 验证结果 ===');
  print('  期望显示: $expected');
  print('  实际显示: $formattedVersion');
  print('  验证结果: ${isCorrect ? "✅ 通过" : "❌ 失败"}');
  
  if (isCorrect) {
    print('\n🎉 版本显示格式正确！');
  }
  
  // 测试旧版本格式修复逻辑
  print('\n=== 测试旧版本格式修复 ===');
  testOldVersionFix('1.0.41765520149');
  testOldVersionFix('1.0.4');
}

void testOldVersionFix(String oldVersion) {
  print('\n输入: $oldVersion');
  
  String version = oldVersion;
  String buildNumber = oldVersion;
  
  // 修复逻辑（来自 main.dart 和 update_service.dart）
  if (version.contains(RegExp(r'\d+\.\d+\.\d+\d{10}'))) {
    final match = RegExp(r'^(\d+\.\d+\.\d+)(\d{10})$').firstMatch(version);
    if (match != null) {
      version = match.group(1)!;
      buildNumber = match.group(2)!;
      print('  修复后: version=$version, buildNumber=$buildNumber');
      
      // 格式化显示
      final formatted = 'v$version-$buildNumber';
      print('  显示为: $formatted');
    } else {
      print('  无法匹配，保持原样');
    }
  } else {
    print('  格式正确，无需修复');
  }
}
