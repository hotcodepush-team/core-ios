Pod::Spec.new do |s|
  s.name = 'HotCodePushCore'
  s.version = '0.0.0'
  s.summary = 'The HotCodePush device protocol for iOS: index, evaluation, download, verification, state and reporting.'
  s.license = { :type => 'MIT', :file => 'LICENSE' }
  s.homepage = 'https://hotcodepush.com'
  s.author = 'Genz IT Solutions GmbH'
  s.source = { :git => 'https://github.com/hotcodepush-team/core-ios.git', :tag => s.version.to_s }
  # One module here, where Swift Package Manager needs two targets: the Swift sees bspatch through the pod's umbrella header.
  s.source_files = 'Sources/HotCodePushCore/**/*.swift', 'Sources/HotCodePushBspatch/**/*.{c,h}'
  s.public_header_files = 'Sources/HotCodePushBspatch/include/*.h'
  s.libraries = 'bz2'
  # The privacy manifest ships in a bundle directory kept in the repository and copied as it is: a generated resource
  # bundle target would carry the pod's iOS 13, below what Xcode 27 builds for the simulator.
  s.resources = ['Sources/HotCodePushCore/HotCodePushCorePrivacy.bundle']
  s.ios.deployment_target = '13.0'
  s.swift_version = '5.9'
end
