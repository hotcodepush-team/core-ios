Pod::Spec.new do |s|
  s.name = 'HotCodePushProtocol'
  s.version = '0.0.0'
  s.summary = 'The HotCodePush device protocol for iOS: index, evaluation, download, verification, state and reporting.'
  s.license = { :type => 'MIT', :file => 'LICENSE' }
  s.homepage = 'https://hotcodepush.com'
  s.author = 'Genz IT Solutions GmbH'
  s.source = { :git => 'https://github.com/hotcodepush-team/protocol-ios.git', :tag => s.version.to_s }
  s.source_files = 'Sources/HotCodePushProtocol/**/*.swift'
  s.resource_bundles = { 'HotCodePushProtocol' => ['Sources/HotCodePushProtocol/PrivacyInfo.xcprivacy'] }
  s.ios.deployment_target = '13.0'
  s.swift_version = '5.9'
end
