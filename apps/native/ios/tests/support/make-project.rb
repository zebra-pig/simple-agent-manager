# Generate test-only projects in scratch space; never mutate the shipping project.
require 'xcodeproj'
require 'fileutils'
mode, ios, output, *sources = ARGV
abort 'Usage: make-project.rb host|ui IOS_DIR OUTPUT SOURCES...' unless %w[host ui].include?(mode) && sources.any?
ios = File.expand_path(ios)
output = File.expand_path(output)
FileUtils.mkdir_p(output)
if mode == 'host'
  path = File.join(output, 'Behavior.xcodeproj')
  project = Xcodeproj::Project.new(path)
  target = project.new_target(:unit_test_bundle, 'NativeBehaviorTests', :osx, '14.0')
  sources.each { |source| target.source_build_phase.add_file_reference(project.main_group.new_file(File.expand_path(source))) }
  target.build_configurations.each do |config|
    config.build_settings.merge!('GENERATE_INFOPLIST_FILE' => 'YES', 'CODE_SIGNING_ALLOWED' => 'NO',
      'PRODUCT_BUNDLE_IDENTIFIER' => 'org.simpleagentmanager.tests.behavior', 'SWIFT_VERSION' => '5.0',
      'SWIFT_OPTIMIZATION_LEVEL' => '-Onone')
  end
else
  path = File.join(output, 'ios/SAM.xcodeproj')
  FileUtils.cp_r(ios, File.join(output, 'ios'))
  FileUtils.cp(sources.shift, File.join(output, 'ios/SAM/SAMApp.swift'))
  project = Xcodeproj::Project.open(path)
  app = project.targets.find { |t| t.name == 'SAM' }
  target = project.new_target(:ui_test_bundle, 'NativeUITests', :ios, '17.0')
  target.add_dependency(app)
  sources.each { |source| target.source_build_phase.add_file_reference(project.main_group.new_file(File.expand_path(source))) }
  target.build_configurations.each do |config|
    config.build_settings.merge!('TEST_TARGET_NAME' => 'SAM', 'PRODUCT_NAME' => 'NativeUITests', 'GENERATE_INFOPLIST_FILE' => 'YES',
      'CODE_SIGNING_ALLOWED' => 'NO', 'PRODUCT_BUNDLE_IDENTIFIER' => 'org.simpleagentmanager.tests.ui',
      'SWIFT_VERSION' => '5.0', 'SWIFT_OPTIMIZATION_LEVEL' => '-Onone')
  end
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app) if app
scheme.add_test_target(target)
scheme.set_launch_target(app) if app
scheme.save_as(path, 'NativeTests', true)
