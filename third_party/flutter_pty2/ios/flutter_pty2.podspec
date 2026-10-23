#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_pty2.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_pty2'
  s.version          = '2.0.0'
  s.summary          = 'Flutter FFI pseudo-terminal plugin.'
  s.description      = <<-DESC
Flutter FFI pseudo-terminal plugin for spawning and controlling terminal processes.
                       DESC
  s.homepage         = 'https://github.com/SoFluffyOS/flutter_pty2'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'SoFluffy' => 'hi@sofluffy.io' }

  # The forwarder C file imports the clean-slate implementation from `../src/*`.
  s.source           = { :path => '.' }
  s.source_files = 'flutter_pty2/Sources/flutter_pty2/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'GCC_PREPROCESSOR_DEFINITIONS' => [
      'DART_SHARED_LIB=1'
    ],
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  s.swift_version = '5.0'
end
