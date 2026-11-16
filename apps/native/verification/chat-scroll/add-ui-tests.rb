require 'xcodeproj'
project_path = ARGV.fetch(0)
source = File.expand_path(ARGV.fetch(1))
project = Xcodeproj::Project.open(project_path)
app = project.targets.find { |target| target.name == 'SAM' }
tests = project.new_target(:ui_test_bundle, 'ChatScrollUITests', :ios, '18.0')
tests.add_dependency(app)
tests.source_build_phase.add_file_reference(project.main_group.new_file(source))
tests.build_configurations.each do |configuration|
  configuration.build_settings['TEST_TARGET_NAME'] = 'SAM'
  configuration.build_settings['PRODUCT_NAME'] = 'ChatScrollUITests'
  configuration.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'org.simpleagentmanager.validation.scroll.tests'
  configuration.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  configuration.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
  configuration.build_settings['SWIFT_VERSION'] = '5.0'
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(tests)
scheme.set_launch_target(app)
scheme.save_as(project_path, 'ChatScrollRegression', true)
