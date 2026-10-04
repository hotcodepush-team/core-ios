Pod::Spec.new do |s|
  s.name = 'HotCodePushProtocol'
  s.version = '0.0.0'
  s.summary = 'The HotCodePush device protocol for iOS: index, evaluation, download, verification, state and reporting.'
  s.license = { :type => 'MIT', :file => 'LICENSE' }
  s.homepage = 'https://hotcodepush.com'
  s.author = 'Genz IT Solutions GmbH'
  s.source = { :git => 'https://github.com/hotcodepush-team/protocol-ios.git', :tag => s.version.to_s }
  # One module here, where Swift Package Manager needs two targets: the Swift sees bspatch through the pod's umbrella header.
  s.source_files = 'Sources/HotCodePushProtocol/**/*.swift', 'Sources/HotCodePushBspatch/**/*.{c,h}'
  s.public_header_files = 'Sources/HotCodePushBspatch/include/*.h'
  s.libraries = 'bz2'
  s.resource_bundles = { 'HotCodePushProtocol' => ['Sources/HotCodePushProtocol/PrivacyInfo.xcprivacy'] }
  s.ios.deployment_target = '13.0'
  s.swift_version = '5.9'
end
