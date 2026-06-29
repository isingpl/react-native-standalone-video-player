require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "react-native-standalone-video-player"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "16.4" } # RN 0.85 / Expo SDK 56 minimum
  s.source       = { :git => "https://github.com/SparingSoftware/react-native-standalone-video-player.git", :tag => "#{s.version}" }

  s.source_files = "ios/**/*.{h,m,mm,swift}"

  # The Fabric component-view header imports the C++ `RCTViewComponentView`. Keep it OUT of the public
  # umbrella header — this pod has Swift, so CocoaPods builds an Objective-C umbrella module for interop,
  # and a C++ header in an Obj-C umbrella fails with "'atomic' file not found". Only this pod's own
  # RNTPlayerVideoViewComponentView.mm (Obj-C++) imports it, so making it private is safe.
  s.private_header_files = "ios/RNTPlayerVideoViewComponentView.h"

  # New architecture: wires codegen (TurboModule + Fabric component spec
  # `RNStandaloneVideoPlayerSpec`), RCT-Folly, React-RuntimeApple, Hermes, etc.
  # Replaces the old `s.dependency "React"`. RN 0.85 removed the legacy interop
  # layer, so this lib must compile as a real Fabric/TurboModule module.
  install_modules_dependencies(s)
end
